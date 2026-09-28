"""Execute prepared conversation turns against a supplied state store."""
import asyncio
from copy import deepcopy
from dataclasses import asdict
from threading import Event
from uuid import uuid4

from sapiens.clock import utcnow
from sapiens.files import file_lock
from sapiens.runtime.contracts import LLMSpec, Outcome


class TurnRunner:
    def __init__(self, *, store, context, config, factory, complete=None):
        self.store, self.context = store, context
        self.config, self.factory = config, factory
        self.complete = complete or (lambda llm, text: llm.complete(text))
        self.cancel_event, self.active_llm = Event(), None

    def _event(self, state, kind, **details):
        state['event_sequence'] += 1
        state['events'].append(dict(sequence=state['event_sequence'], time=utcnow().isoformat(), kind=kind, **details))

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
            self.store.trim(state)
        return turn['id']

    def tell(self, text):
        return self.submit('chat', text)

    def _recover(self, state):
        for turn in state['turns']:
            if turn['status'] == 'running':
                turn.update(status='interrupted', error='Runner stopped before saving a reply; inspect effects before retrying')
                self._event(state, 'interrupted', turn=turn['id'])

    def _work(self, turn, snapshot, config):
        result = Outcome()
        try:
            context = self.context(snapshot, turn['input'], config)
            for step in config.flows[turn['flow']].steps:
                role = config.roles[step]
                prompt = role.prompt.format_map(context).strip()
                llm = self.factory.spawn(LLMSpec(role=step, model=role.model))
                llm.cancel_event = self.cancel_event
                self.active_llm = llm
                log = dict(role=step, prompt=prompt, session=llm.id)
                result.logs.append(log)
                try:
                    answer = self.complete(llm, prompt)
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
        finally:
            self.active_llm = None
        return result

    def _finish(self, turn_id, outcome):
        with self.store.transaction() as state:
            if self.cancel_event.is_set():
                outcome.error = 'Stopped by Admin. Saved work is preserved; review external effects before retrying.'
            self.store.archive(f'runs/{turn_id}', asdict(outcome))
            turn = next(t for t in state['turns'] if t['id'] == turn_id)
            warnings = [log['warning'] for log in outcome.logs if log.get('warning')]
            if warnings:
                turn['warning'] = ' '.join(warnings)
            else:
                turn.pop('warning', None)
            if outcome.error:
                turn.update(status='interrupted' if self.cancel_event.is_set() else 'failed', error=outcome.error)
            else:
                turn['status'] = 'done'
                state['chat'].append(dict(role='agent', content=outcome.output, turn=turn_id, time=utcnow().isoformat()))
                state['last_output'] = outcome.output
            self._event(state, turn['status'], turn=turn_id)
            self.store.trim(state)

    async def run(self):
        await asyncio.to_thread(self.run_sync)

    def run_sync(self):
        """Own the runner lock and finish the turn on the caller's worker thread."""
        try:
            lock = file_lock(self.store.root / '.runner.lock', blocking=False)
            lock.__enter__()
        except BlockingIOError:
            return
        try:
            with self.store.transaction() as state:
                self.cancel_event.clear()
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
            outcome = self._work(turn, snapshot, self.config)
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
            if turn['status'] == 'running':
                self.cancel_event.set()
                return  # The runner alone finishes the turn and releases the desktop.
            if turn['status'] == 'done':
                raise ValueError('Completed turns cannot be dismissed')
            turn['status'] = 'cancelled'
