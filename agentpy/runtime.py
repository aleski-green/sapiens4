"""Persistent chat turns. No timers, tasks, autonomous jobs or learning flows."""
import asyncio
from copy import deepcopy
from dataclasses import asdict
from datetime import datetime, timezone
import json
from pathlib import Path
from uuid import uuid4

from .corpora import Corpora
from .lifecycle import Outcome
from .interfaces import LLMSpec
from .storage import StateStore, atomic_bytes, file_lock, safe_child


def utcnow():
    return datetime.now(timezone.utc)


class PersistentAgent:
    def __init__(self, *, config, factory, agid, root):
        self.agid = agid
        self.root = safe_child(Path(root).resolve() / 'agents', agid)
        self.config, self.factory = config, factory
        self.store = StateStore(self.root)
        self.corpora = Corpora(Path(root).resolve() / 'corpora')
        with file_lock(self.root / '.state.lock'):
            if not self.store.path.exists():
                self.store.write(dict(schema_version=3, agid=agid, revision=0,
                    turns=[], chat=[], events=[], event_sequence=0, last_output=None))
            saved = self.store.read()
            if saved['agid'] != agid:
                raise ValueError('Agent ID does not match saved state')
            if saved['schema_version'] < 3:
                version = saved['schema_version']
                backup = self.root / f'legacy-state-v{version}.json'
                if not backup.exists():
                    atomic_bytes(backup, self.store.path.read_bytes())
                turns = []
                for old in saved['jobs' if version == 1 else 'turns']:
                    if old['flow'] not in {'chat', 'computer'}:
                        continue
                    turn = {k: v for k, v in old.items() if k in {
                        'id','flow','status','created','error','warning'}}
                    turn['input'] = old['task' if version == 1 else 'input']
                    if turn['status'] == 'budget_blocked':
                        turn.update(status='interrupted', error='Former budget block removed; retry to continue')
                    turns.append(turn)
                saved = {k: saved[k] for k in ('agid','revision','chat','events','event_sequence','last_output')}
                saved.update(schema_version=3, turns=turns)
                for field in ('chat', 'events'):
                    for row in saved[field]:
                        if 'job' in row:
                            row['turn'] = row.pop('job')
                self.store.write(saved)
        if agid not in self.corpora.directory():
            self.corpora.register(agid)

    @property
    def state(self):
        return self.store.read()

    @property
    def manifests(self):
        # Explicit allowlist keeps legacy scheduling/learning instructions inert.
        return {name: (self.root / 'manifests' / (name + '.md')).read_text()
                for name in ('identity','computer-use','host-control','host-facts')
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
        for field in ('chat', 'events', 'turns'):
            rows = state[field]
            # A bounded chat window; full transcripts and UI history stay durable.
            settled = [r for r in rows if r.get('status') not in {'queued','running'}]
            removed = settled[:-100]
            if removed:
                self.corpora.archive(self.agid, f'{field}/{uuid4().hex}', removed)
                state[field] = [r for r in rows if r not in removed]

        for field in ('chat', 'events', 'turns'):
            removed = []
            for row in list(state[field]):
                if len(json.dumps(state, ensure_ascii=False).encode()) <= 800_000:
                    break
                if row.get('status') not in {'queued','running'} and not (field == 'turns' and row == state[field][-1]):
                    state[field].remove(row)
                    removed.append(row)
            if removed:
                self.corpora.archive(self.agid, f'{field}/{uuid4().hex}', removed)

    def submit(self, flow, text):
        if flow not in {'chat', 'computer'}:
            raise ValueError('Only chat turns are supported')
        with self.store.transaction() as state:
            if any(t['status'] in {'queued','running'} for t in state['turns']):
                raise ValueError('A conversation turn is already pending')
            turn = dict(id=uuid4().hex, flow=flow, input=text, status='queued', created=utcnow().isoformat())
            state['turns'].append(turn)
            state['chat'].append(dict(role='user', content=text, turn=turn['id'], time=turn['created']))
            self._event(state, 'queued', turn=turn['id'], flow=flow)
            self._trim(state)
        return turn['id']

    def tell(self, text):
        return self.submit('chat', text)

    def _recover(self, state):
        for turn in state['turns']:
            if turn['status'] == 'running':
                turn.update(status='interrupted', error='Runner stopped before saving a reply; inspect effects before retrying')
                self._event(state, 'interrupted', turn=turn['id'])

    def _context(self, snapshot, text):
        chat = [m for m in snapshot['chat'][-10:] if m.get('turn') != snapshot.get('current_turn')]
        blocks = dict(manifests=self.manifests, chat=chat)
        # Keep the current request and fresh notes ahead of older conversation.
        allowance = 60_000 - len(text) - len(self.config.roles['conversation'].prompt) - 100
        while len(json.dumps(blocks, ensure_ascii=False)) > allowance and chat:
            chat.pop(0)
            blocks['history_truncated'] = True
        return dict(context=json.dumps(blocks, ensure_ascii=False), task=text, last='', proposal='', critique='')

    def _work(self, turn, snapshot, config):
        result = Outcome()
        try:
            context = self._context(snapshot, turn['input'])
            for step in config.flows[turn['flow']].steps:
                role = config.roles[step]
                prompt = role.prompt.format_map(context).strip()
                llm = self.factory.spawn(LLMSpec(role=step, model=role.model))
                log = dict(role=step, prompt=prompt, session=llm.id)
                result.logs.append(log)
                try:
                    answer = llm.complete(prompt)
                    if not isinstance(answer, str):
                        raise ValueError('LLM output must be text')
                    log['answer'] = answer
                    if getattr(llm, 'warning', None):
                        log['warning'] = llm.warning
                    context['last'] = answer
                finally:
                    log['session'] = llm.id
            result.output = context['last']
        except Exception as error:
            result.error = f'{type(error).__name__}: {error}'
        return result

    def _finish(self, turn_id, outcome):
        self.corpora.archive(self.agid, f'runs/{turn_id}', asdict(outcome))
        with self.store.transaction() as state:
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            warnings = [log['warning'] for log in outcome.logs if log.get('warning')]
            if warnings:
                turn['warning'] = ' '.join(warnings)
            else:
                turn.pop('warning', None)
            if outcome.error:
                turn.update(status='failed', error=outcome.error)
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
                self._recover(state)
                turn = next((t for t in state['turns'] if t['status'] == 'queued'), None)
                if turn is None:
                    return
                turn['status'] = 'running'
                turn.pop('error', None)
                self._event(state, 'started', turn=turn['id'], flow=turn['flow'])
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
            if turn['status'] not in {'failed','interrupted'}:
                raise ValueError('Only stopped conversation turns can be retried')
            if any(t['status'] in {'queued','running'} for t in state['turns']):
                raise ValueError('A conversation turn is already pending')
            turn['status'] = 'queued'
            turn.pop('error', None)

    def cancel(self, turn_id):
        with self.store.transaction() as state:
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            if turn['status'] in {'running','done'}:
                raise ValueError('Only queued or stopped turns can be dismissed')
            turn['status'] = 'cancelled'
