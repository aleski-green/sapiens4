"""Chat batches, per-kind slots, and FIFO output publication through Pulse."""
from copy import deepcopy
import json
import logging
import threading

from sapiens.clock import utcnow
from sapiens.corpora.host.pulsation import AgencyBatch, BatchPolicy
from sapiens.runtime.turns import TurnRunner


class ChatAgencies:
    def __init__(self, service):
        self.service = service
        self.policies = {'chatInput': BatchPolicy(), 'chatOutput': BatchPolicy()}
        self.slots = {}  # (Sapi, AgencyKind, slot) -> (runner, thread, batch ID)

    def recover(self, agent):
        with agent.transaction() as state:
            # Never replay started effects after a process crash. Queued input
            # and completed-but-unpublished output remain in their buffers.
            agent.runner._recover(state)

    def context(self, agent):
        if 'corpora-state' not in agent.manifests:
            facts = self.service.orchestration.status(agent)
            agent.set_manifest('corpora-state', json.dumps(dict(
                currentSapi=agent.agid, chief=facts['main_agent_id'],
                groups=facts['groups'], team=facts['team'],
                workspace=dict(path=str(agent.workspace))), ensure_ascii=False))

    def dispatch(self, tick):
        service = self.service
        # Host lock serializes submissions, slot reservations, and stop with
        # dispatch; model execution happens outside it.
        with service._lock:
            if not service.pulse.running or service._stopping.is_set():
                return
            for agent in list(service._agents.values()):
                if service.lifecycle.retired(agent):
                    continue
                self.output(agent, tick)
                self.input(agent, tick)

    def input(self, agent, tick):
        service = self.service
        queued = tuple(t for t in agent.state['turns']
                       if t['status'] == 'queued' and t.get('batchable'))
        batch = AgencyBatch(queued)
        if not self.policies['chatInput'].admits(tick, batch):
            return
        if agent.agid in service._runners:
            return  # An older Group/delegation run retains its exclusive lease.
        slot = next((n for n in (1, 2) if (agent.agid, 'chatInput', n) not in self.slots), None)
        owners = {key[0] for key in self.slots} | set(service._runners)
        if slot is None or (agent.agid not in owners and len(owners) >= service.max_parallel_agents):
            return  # Keep accumulating; do not seal another pending batch.
        self.context(agent)
        runner = TurnRunner(store=agent, context=agent.context, config=agent.runner.config,
                            factory=agent.runner.factory, complete=agent.runner.complete,
                            execute=agent.runner.execute)
        with agent.transaction() as state:
            members = [t for t in state['turns'] if t['status'] == 'queued' and t.get('batchable')]
            if not members:
                return
            first = members[0]
            member_ids = [t['id'] for t in members]
            for turn in members:
                turn.update(status='running', batch_id=first['id'], agency_kind='chatInput',
                            slot=slot, pulseId=tick['pulseId'])
                turn.pop('error', None)
            first['batch_members'] = member_ids
            snapshot = deepcopy(state)
            snapshot['current_turn'] = first['id']
            snapshot['agency_batch'] = [dict(id=t['id'], content=t['input']) for t in members]
            execution = deepcopy(first)
            execution['input'] = '\n\n'.join(t['input'] for t in members)
        key = (agent.agid, 'chatInput', slot)

        def run():
            service._execution.turn = execution['id']
            try:
                runner.run_claimed(execution, snapshot)
            except Exception:
                logging.exception('AgencyRun failed: %s', execution['id'])
                with agent.transaction() as state:
                    for turn in state['turns']:
                        if turn.get('batch_id') == execution['id'] and turn['status'] == 'running':
                            turn.update(status='interrupted', error='AgencyRun stopped; inspect effects before retrying')
            finally:
                # The computer lease is owned by the run, not merely its Sapi.
                service.release_computer(agent.agid, turn_id=execution['id'])
                with service._lock:
                    self.slots.pop(key, None)
                    service._sync(agent)
                    with agent.transaction() as state:
                        agent.trim(state)
                    service.delegation.reconcile(agent.agid)
                service._execution.turn = None

        thread = threading.Thread(target=run, name=f'{agent.agid}-chatInput-{slot}', daemon=True)
        self.slots[key] = (runner, thread, execution['id'])
        service.store.record_pulse_call(tick, agent.agid, 'chatInput', slot)
        service._sync(agent)
        thread.start()

    def output(self, agent, tick):
        batch = AgencyBatch(tuple(agent.state.get('output_buffer', [])))
        if not self.policies['chatOutput'].admits(tick, batch):
            return
        # Each rendering slot takes one FIFO result. Publication is an atomic,
        # deterministic AgencyRun; two outputs become two separate bubbles.
        for slot in (1, 2):
            with agent.transaction() as state:
                buffer = state.get('output_buffer', [])
                if not buffer:
                    break
                item = buffer.pop(0)
                timestamp = utcnow().isoformat()
                state['output_sequence'] = state.get('output_sequence', 0) + 1
                if not any(m.get('turn') == item['turn'] and m['role'] == 'agent' for m in state['chat']):
                    state['chat'].append(dict(role='agent', content=item['content'],
                        turn=item['turn'], time=timestamp, origin=item.get('origin')))
                for turn in state['turns']:
                    if turn['id'] in item['members']:
                        turn.update(status='done', output_at=timestamp, output_order=state['output_sequence'])
                state['last_output'] = item['content']
            self.service.store.record_pulse_call(tick, agent.agid, 'chatOutput', slot)
        self.service._sync(agent)
        with agent.transaction() as state:
            agent.trim(state)

    def active_runner(self, agid, turn_id):
        return next((entry[0] for key, entry in self.slots.items()
                     if key[0] == agid and entry[2] == turn_id), None)

    def cancel_all(self):
        for runner, _, _ in self.slots.values():
            runner.cancel_event.set()
