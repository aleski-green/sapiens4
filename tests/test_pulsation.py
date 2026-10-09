"""Pulse clocks and real concurrent chat slots, using gated model doubles."""
import json
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from pathlib import Path

from sapiens.corpora.host.service import Service
from sapiens.corpora.host.pulsation import AgencyBatch, BatchPolicy, CallDecision


class ControlledFactory:
    def __init__(self):
        self.calls = []

    def spawn(self, spec):
        factory = self
        class Model:
            id = 'controlled'
            def complete(self, prompt):
                entry = dict(prompt=prompt, gate=threading.Event(), model=self)
                factory.calls.append(entry)
                if not entry['gate'].wait(10):
                    raise TimeoutError('Test did not release model')
                return json.dumps(dict(event='FitsSpecialization', mode='Repl',
                    reply='Reply ' + str(factory.calls.index(entry) + 1), reason='Chat', evidence=[]))
        return Model()


class PulsationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.factory = ControlledFactory()
        self.service = Service(self.temp.name, factory_builder=lambda _: self.factory, start_worker=False)
        self.agent = self.service.registry.main
        self.at = 0
        self.service.pulse.clock = lambda: self.at
        self.service.pulse.start()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for call in self.factory.calls:
            call['gate'].set()
        self.service.close()
        self.temp.cleanup()

    def until(self, check):
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if check():
                return
            time.sleep(.005)
        self.fail('Expected state did not arrive')

    def tick(self, seconds=2):
        self.at += seconds
        with self.service._lock:
            self.service.pulse.step(self.at)

    def submit(self, text):
        return self.service.submit(self.agent, dict(text=text))['id']

    def release(self, index):
        self.factory.calls[index]['gate'].set()

    def test_all_three_clocks_advance_and_restart_without_idle_calls(self):
        self.tick(.5)
        self.assertEqual(self.service.pulse.numbers, dict(bpm120=1, bpm60=0, bph60=0))
        self.tick(.5)
        self.assertEqual(self.service.pulse.numbers, dict(bpm120=2, bpm60=1, bph60=0))
        self.tick(59)
        self.assertEqual(self.service.pulse.numbers, dict(bpm120=120, bpm60=60, bph60=1))
        self.assertEqual(self.factory.calls, [])
        self.assertEqual(self.service.store.pulse_calls(), [])

    def test_empty_ticks_advance_without_calls_and_policy_is_callable(self):
        decisions = []
        policy = BatchPolicy(decide=lambda batch: decisions.append(batch) or CallDecision.NoCall)
        self.service.agencies.policies['chatInput'] = policy
        self.submit('Buffered')
        self.tick()
        self.assertEqual(self.service.pulse.numbers['bpm60'], 2)
        self.assertEqual(len(decisions), 1)
        self.assertIsInstance(decisions[0], AgencyBatch)
        self.assertEqual(self.factory.calls, [])
        self.assertEqual(self.service.store.pulse_calls(), [])
        self.service.agencies.policies['chatInput'] = BatchPolicy()
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        self.assertEqual(self.service.store.pulse_calls()[0]['num'], 4)
        # Even a custom Call cannot create a run for an empty batch.
        policy = BatchPolicy(decide=lambda _: CallDecision.Call)
        self.assertFalse(policy.admits(dict(frequency='bpm60', num=2), AgencyBatch(())))

    def test_batch_context_and_second_slot_with_accumulation(self):
        a, b = self.submit('First'), self.submit('Second')
        self.assertEqual(self.factory.calls, [])
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        self.assertIn('First', self.factory.calls[0]['prompt'])
        self.assertIn('Second', self.factory.calls[0]['prompt'])
        c = self.submit('Third')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 2)
        self.assertEqual({key[2] for key in self.service.agencies.slots}, {1, 2})
        self.assertIn('underPrevAgencyReview', self.factory.calls[1]['prompt'])
        d, e = self.submit('Fourth'), self.submit('Fifth')
        self.tick()
        self.assertEqual(len(self.factory.calls), 2)
        queued = [t for t in self.service._agent(self.agent).state['turns'] if t['status'] == 'queued']
        self.assertEqual([t['id'] for t in queued], [d, e])
        self.release(0)
        self.until(lambda: len(self.service.agencies.slots) == 1)
        self.assertEqual(self.service._agent(self.agent).state['turns'][0]['status'], 'output_pending')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 3)
        self.assertIn('Fourth', self.factory.calls[2]['prompt'])
        self.assertIn('Fifth', self.factory.calls[2]['prompt'])
        turns = {t['id']: t for t in self.service.snapshot()['turns']}
        self.assertEqual(turns[a]['output'], 'Reply 1')
        self.assertIsNone(turns[b]['output'])
        self.assertEqual(turns[b]['status'], 'done')
        self.assertEqual(turns[d]['batch_members'], [d, e])
        self.assertEqual(turns[d]['slot'], 1)

    def test_output_fifo_and_two_bubbles_in_same_pulse(self):
        self.submit('First')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        self.submit('Second')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 2)
        self.release(1)
        self.until(lambda: len(self.service._agent(self.agent).state.get('output_buffer', [])) == 1)
        self.release(0)
        self.until(lambda: not self.service.agencies.slots)
        self.assertFalse(any(m['role'] == 'agent' for m in self.service._agent(self.agent).state['chat']))
        self.tick()
        messages = [m['content'] for m in self.service._agent(self.agent).state['chat'] if m['role'] == 'agent']
        self.assertEqual(messages, ['Reply 2', 'Reply 1'])
        outputs = [p for p in self.service.store.pulse_calls() if p['agencyKind'] == 'chatOutput']
        self.assertEqual(len(outputs), 2)
        self.assertEqual({p['slot'] for p in outputs}, {1, 2})
        self.assertEqual(len({p['pulseId'] for p in outputs}), 1)
        self.tick()
        self.assertEqual(len(self.service.store.pulse_calls()), 4)

    def test_large_batch_is_projected_before_retention_trims_turns(self):
        ids = [self.submit('Message ' + str(n)) for n in range(105)]
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        self.release(0)
        self.until(lambda: not self.service.agencies.slots)
        self.tick()
        turns = self.service.snapshot()['turns']
        self.assertEqual(len(turns), 105)
        self.assertTrue(all(t['status'] == 'done' for t in turns))
        self.assertEqual([t['id'] for t in turns if t['output'] is not None], [ids[0]])

    def test_full_memo_last_20_no_exclusions_and_static_is_persisted(self):
        agent = self.service._agent(self.agent)
        Path(agent.workspace, 'Notes.html').write_text('COMPLETE MEMO ' + 'x' * 65000)
        agent.set_manifest('corpora-state', 'Previously persisted Corpora state')
        for number in range(25):
            self.submit('message-' + str(number))
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        snapshot = agent.state
        snapshot['current_turn'] = snapshot['turns'][0]['id']
        snapshot['agency_batch'] = [{'content': t['input']} for t in snapshot['turns']]
        context = json.loads(agent.context(snapshot, '', agent.runner.config)['context'])
        self.assertEqual(len(context['instantContext']['chat']), 20)
        self.assertEqual(context['instantContext']['chat'][-1]['content'], 'message-24')
        self.assertEqual(len(context['inputs']), 25)
        self.assertEqual(context['instantContext']['memo'], 'COMPLETE MEMO ' + 'x' * 65000)
        self.assertEqual(context['staticContext'], 'Previously persisted Corpora state')
        self.assertIn('COMPLETE MEMO ' + 'x' * 65000, self.factory.calls[0]['prompt'])

    def test_restart_preserves_output_and_queued_input_without_replaying(self):
        self.submit('Finished input')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        self.release(0)
        self.until(lambda: not self.service.agencies.slots)
        queued = self.submit('Still queued')
        identity = self.service.pulse.identity
        self.service.close()
        self.service = Service(self.temp.name, factory_builder=lambda _: self.factory, start_worker=False)
        self.service.pulse.clock = lambda: self.at
        self.service.pulse.start()
        self.assertEqual(self.service.pulse.identity, identity)
        self.assertEqual(self.service.pulse.numbers['bpm60'], 2)
        self.tick()
        self.until(lambda: len(self.factory.calls) == 2)
        self.assertEqual(self.service._agent(self.agent).state['chat'][-1]['content'], 'Reply 1')
        self.assertEqual(self.service.store.projected_turn(queued)['status'], 'running')

    def test_stop_before_reserved_legacy_worker_starts_keeps_input_queued(self):
        agent = self.service._agent(self.agent)
        turn = agent.runner.submit('chat', 'Legacy queued input')
        entered, release = threading.Event(), threading.Event()
        original = self.service._run_queued
        def delayed(*args, **kwargs):
            entered.set()
            release.wait(3)
            return original(*args, **kwargs)
        with patch.object(self.service, '_run_queued', side_effect=delayed):
            self.tick()
            self.assertTrue(entered.wait(1))
            self.service.stop_pulse()
            release.set()
            self.until(lambda: not self.service._runners)
        self.assertEqual(self.factory.calls, [])
        self.assertEqual(self.service.store.projected_turn(turn)['status'], 'queued')

    def test_stop_cancels_active_and_keeps_pending_without_new_dispatch(self):
        self.submit('Running')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        pending = self.submit('Pending')
        self.service.stop_pulse()
        self.assertTrue(self.factory.calls[0]['model'].cancel_event.is_set())
        self.tick(60)
        self.assertEqual(self.service.pulse.numbers['bpm60'], 2)
        self.assertEqual(len(self.factory.calls), 1)
        self.release(0)
        self.until(lambda: not self.service.agencies.slots)
        self.assertEqual(self.service.store.projected_turn(pending)['status'], 'queued')
        self.service.pulse.start()
        self.tick()
        self.until(lambda: len(self.factory.calls) == 2)
        self.assertEqual(self.service.store.projected_turn(pending)['status'], 'running')

    def test_computer_lease_and_cancel_are_per_run(self):
        first = self.submit('First')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 1)
        second = self.submit('Second')
        self.tick()
        self.until(lambda: len(self.factory.calls) == 2)
        self.service.orchestration.control(self.agent, dict(op='computer_acquire', agencyRun=first))
        with self.assertRaisesRegex(Exception, 'another AgencyRun'):
            self.service.orchestration.control(self.agent, dict(op='computer_acquire', agencyRun=second))
        self.service.turn_action(self.agent, second, 'cancel')
        self.assertTrue(self.factory.calls[1]['model'].cancel_event.is_set())
        self.assertFalse(self.factory.calls[0]['model'].cancel_event.is_set())
        self.release(1)
        self.until(lambda: len(self.service.agencies.slots) == 1)
        self.assertEqual(self.service.snapshot()['computer']['owner'], self.agent)
        self.release(0)
        self.until(lambda: not self.service.agencies.slots)
        self.assertIsNone(self.service.snapshot()['computer']['owner'])
