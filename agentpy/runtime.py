"""Persistent chat turns. No timers, tasks, autonomous jobs or learning flows."""
import asyncio
from copy import deepcopy
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
from threading import Event
from uuid import uuid4
from zoneinfo import ZoneInfo

from .corpora import Corpora
from .lifecycle import Limits
from .storage import StateStore, atomic_bytes, file_lock, safe_child


def utcnow():
    return datetime.now(timezone.utc)


class PersistentAgent:
    def __init__(self, *, config, factory, agid, root, limits=None):
        self.agid = agid
        self.root = safe_child(Path(root).resolve() / 'agents', agid)
        self.config, self.factory = config, factory
        self.cancel_event, self.active_llm = Event(), None
        self.limits = limits or Limits()
        self.store = StateStore(self.root, self.limits)
        self.corpora = Corpora(Path(root).resolve() / 'corpora')
        with file_lock(self.root / '.state.lock'):
            if not self.store.path.exists():
                self.store.write(dict(schema_version=2, agid=agid, revision=0,
                    limits=asdict(self.limits), budget_calendar=dict(sprint_days=7,
                        timezone='Asia/Dubai', sprint_anchor='2026-01-05'),
                    turns=[], chat=[], events=[], event_sequence=0, budgets={}, last_output=None))
            saved = self.store.read()
            if saved['agid'] != agid:
                raise ValueError('Agent ID does not match saved state')
            if saved['schema_version'] == 1:
                # Preserve the complete old state once. No removed flow is resumed
                # or included in the next prompt; old runtime files stay on disk.
                backup = self.root / 'legacy-state-v1.json'
                if not backup.exists():
                    atomic_bytes(backup, self.store.path.read_bytes())
                turns = []
                for old in saved['jobs']:
                    if old['flow'] in {'chat', 'computer'}:
                        turn = {k: v for k, v in old.items() if k in {
                            'id','flow','status','created','tokens','error','warning','reserved','sprint','budget_units'}}
                        turn['input'] = old['task']
                        turns.append(turn)
                    elif old['status'] == 'running' and old.get('sprint') in saved['budgets']:
                        ledger = saved['budgets'][old['sprint']]
                        reserved = old.get('reserved', 0)
                        ledger['reserved'] = max(0, ledger['reserved'] - reserved)
                        ledger['spent'] += reserved  # Unknown in-flight usage remains charged.
                saved = {k: saved[k] for k in ('agid','revision','limits','budget_calendar',
                    'chat','events','event_sequence','budgets','last_output')}
                saved.update(schema_version=2, turns=turns, budget_policy='cache-10-percent-v1')
                for field in ('chat', 'events'):
                    for row in saved[field]:
                        if 'job' in row:
                            row['turn'] = row.pop('job')
                self.store.write(saved)
        self.budget_calendar = {k: v for k, v in saved['budget_calendar'].items()
                                if k in {'sprint_days', 'timezone', 'sprint_anchor'}}
        if agid not in self.corpora.directory():
            self.corpora.register(agid)

    @property
    def state(self):
        return self.store.read()

    @property
    def manifests(self):
        # Explicit allowlist keeps legacy scheduling/learning instructions inert.
        return {name: (self.root / 'manifests' / (name + '.md')).read_text()
                for name in ('identity','computer-use','computer-tools','host-control','host-facts')
                if (self.root / 'manifests' / (name + '.md')).is_file()}

    def set_manifest(self, name, text):
        if not name or '/' in name or '\\' in name:
            raise ValueError('Use a simple manifest name')
        atomic_bytes(safe_child(self.root / 'manifests', name + '.md'), text.encode())

    def transcript(self, turn_id):
        path = safe_child(self.corpora.root / 'archive', f'{self.agid}/runs/{turn_id}.json')
        return json.loads(path.read_bytes())['logs'] if path.exists() else []

    def result(self, turn_id):
        for message in self.state['chat']:
            if message.get('turn') == turn_id and message['role'] == 'agent':
                return message['content']
        path = safe_child(self.corpora.root / 'archive', f'{self.agid}/runs/{turn_id}.json')
        return json.loads(path.read_bytes())['output']

    def _event(self, state, kind, **details):
        state['event_sequence'] += 1
        state['events'].append(dict(sequence=state['event_sequence'], time=utcnow().isoformat(), kind=kind, **details))

    def _trim(self, state):
        for sprint in sorted(state['budgets'])[:-2]:
            if state['budgets'][sprint]['reserved'] == 0:
                self.corpora.archive(self.agid, 'budgets/' + sprint, state['budgets'].pop(sprint))
        for field in ('chat', 'events', 'turns'):
            rows = state[field]
            # A bounded chat window; full transcripts and UI history stay durable.
            settled = [r for r in rows if r.get('status') not in {'queued','running','budget_blocked'}]
            removed = settled[:-min(self.limits.max_records, 100)]
            if removed:
                self.corpora.archive(self.agid, f'{field}/{uuid4().hex}', removed)
                state[field] = [r for r in rows if r not in removed]

        for field in ('chat', 'events', 'turns'):
            removed = []
            for row in list(state[field]):
                if len(json.dumps(state, ensure_ascii=False).encode()) <= self.limits.state_bytes * .8:
                    break
                if row.get('status') not in {'queued','running','budget_blocked'} and not (field == 'turns' and row == state[field][-1]):
                    state[field].remove(row)
                    removed.append(row)
            if removed:
                self.corpora.archive(self.agid, f'{field}/{uuid4().hex}', removed)

    def submit(self, flow, text):
        if flow not in {'chat', 'computer'}:
            raise ValueError('Only chat turns are supported')
        with self.store.transaction() as state:
            if any(t['status'] in {'queued','running','budget_blocked'} for t in state['turns']):
                raise ValueError('A conversation turn is already pending')
            turn = dict(id=uuid4().hex, flow=flow, input=text, status='queued', tokens=0, created=utcnow().isoformat())
            state['turns'].append(turn)
            state['chat'].append(dict(role='user', content=text, turn=turn['id'], time=turn['created']))
            self._event(state, 'queued', turn=turn['id'], flow=flow)
            self._trim(state)
        return turn['id']

    def tell(self, text):
        return self.submit('chat', text)

    def _sprint(self, now):
        calendar = self.budget_calendar
        day = now.astimezone(ZoneInfo(calendar['timezone'])).date()
        anchor = date.fromisoformat(calendar['sprint_anchor'])
        days = calendar['sprint_days']
        return (anchor + timedelta(days=((day - anchor).days // days) * days)).isoformat()

    def _reserve(self, state, turn, loop_remaining, now):
        reserved = self.limits.tokens_per_call
        sprint = self._sprint(now)
        ledger = state['budgets'].setdefault(sprint, dict(spent=0, reserved=0))
        if reserved > loop_remaining or ledger['spent'] + ledger['reserved'] + reserved > self.limits.tokens_per_sprint:
            turn.update(status='budget_blocked', error='Budget allowance unavailable. Review limits in Sapi settings.')
            self._event(state, 'budget_blocked', turn=turn['id'])
            return None
        turn.update(status='running', reserved=reserved, sprint=sprint)
        turn.pop('error', None)
        ledger['reserved'] += reserved
        self._event(state, 'started', turn=turn['id'], flow=turn['flow'])
        return reserved

    @staticmethod
    def _settle(state, turn, tokens):
        ledger = state['budgets'][turn['sprint']]
        ledger['reserved'] -= turn['reserved']
        ledger['spent'] += tokens
        turn['tokens'] = tokens

    def _recover(self, state):
        for turn in state['turns']:
            if turn['status'] == 'running':
                self._settle(state, turn, turn['reserved'])
                turn.update(status='interrupted', error='Runner stopped before saving a reply; inspect effects before retrying')
                self._event(state, 'interrupted', turn=turn['id'])

    def _context(self, snapshot, text):
        chat = [m for m in snapshot['chat'][-10:] if m.get('turn') != snapshot.get('current_turn')]
        blocks = dict(manifests=self.manifests, chat=chat)
        # Keep the current request and fresh notes ahead of older conversation.
        allowance = self.limits.context_chars - len(text) - len(self.config.roles['conversation'].prompt) - 100
        while len(json.dumps(blocks, ensure_ascii=False)) > allowance and chat:
            chat.pop(0)
            blocks['history_truncated'] = True
        return dict(context=json.dumps(blocks, ensure_ascii=False), task=text, last='', proposal='', critique='')

    def _finish(self, turn_id, outcome):
        with self.store.transaction() as state:
            if self.cancel_event.is_set():
                outcome.error = 'Stopped by Admin. Saved work is preserved; review external effects before retrying.'
            self.corpora.archive(self.agid, f'runs/{turn_id}', asdict(outcome))
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            self._settle(state, turn, outcome.tokens)
            if outcome.error:
                turn.update(status='interrupted' if self.cancel_event.is_set() else 'failed', error=outcome.error)
            else:
                turn['status'] = 'done'
                state['chat'].append(dict(role='agent', content=outcome.output, turn=turn_id, time=utcnow().isoformat()))
                state['last_output'] = outcome.output
            self._event(state, turn['status'], turn=turn_id)
            self._trim(state)

    async def run(self):
        try:
            lock = file_lock(self.root / '.runner.lock', blocking=False)
            lock.__enter__()
        except BlockingIOError:
            return
        try:
            with self.store.transaction() as state:
                self.cancel_event.clear()
                self._recover(state)
                turn = next((t for t in state['turns'] if t['status'] == 'queued'), None)
                if turn is None or self._reserve(state, turn, self.limits.tokens_per_loop, utcnow()) is None:
                    return
                snapshot = deepcopy(state)
                snapshot['current_turn'] = turn['id']
                turn = deepcopy(turn)
            outcome = await asyncio.to_thread(self._work, turn, snapshot, self.config)
            self._finish(turn['id'], outcome)
        finally:
            lock.__exit__(None, None, None)

    def retry(self, turn_id):
        with self.store.transaction() as state:
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            if turn['status'] not in {'failed','interrupted','budget_blocked'}:
                raise ValueError('Only stopped conversation turns can be retried')
            if any(t['status'] in {'queued','running'} for t in state['turns']):
                raise ValueError('A conversation turn is already pending')
            turn['status'] = 'queued'
            turn.pop('error', None)

    def cancel(self, turn_id):
        with self.store.transaction() as state:
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            if turn['status'] == 'running':
                self.cancel_event.set()
                return  # The runner alone settles usage and releases the desktop.
            if turn['status'] == 'done':
                raise ValueError('Completed turns cannot be dismissed')
            turn['status'] = 'cancelled'
