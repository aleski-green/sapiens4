"""Event retention, scope, attribution and actual (not empty) Pulse admission."""
import json
from test_integration import IntegrationFixture


class EventsTest(IntegrationFixture):
    def test_scoped_retention_and_persistence(self):
        s = self.service(start_worker=False)
        chief = s.registry.main
        other = s.create_agent(dict(name='Other', role='Research'))['id']
        with s.store.events.context(chief, 'chatInput'):
            s.store.events.record(other, other, 'sapi.updated', dict(role='Updated'))
        event = s.store.events.snapshot(other)[other][0]
        self.assertEqual((event['actor'], event['agency']), (chief, 'chatInput'))
        self.assertRegex(event['timestamp'], r'\.\d{3}\+00:00$')
        for n in range(110):
            s.store.events.record(chief, 'corpora', 'test', dict(n=n), actor='system')
        self.assertEqual(len(s.store.events.snapshot(chief)[chief]), 100)
        self.assertEqual(s.store.events.snapshot(other)[other][0], event)
        s = self.restart(s, start_worker=False)
        self.assertEqual(s.store.events.snapshot(other)[other][0], event)
        self.assertEqual(len(s.store.events.snapshot(chief)[chief]), 100)

    def test_routine_and_lifecycle_changes_are_attributed_without_poll_duplicates(self):
        s = self.service(start_worker=False)
        chief = s.registry.main
        child = s.orchestration.control(chief, dict(op='create_agent', name='Scout', role='Research'))['agent']['id']
        created = s.store.events.snapshot(child)[child][0]
        self.assertEqual((created['actor'], created['event']), (chief, 'sapi.created'))
        routine = s.orchestration.control(child, dict(op='routine_create', minutes=2, prompt='Find one example.'))['routine']
        s.submit(child, dict(text='Pause Schedule Riutine\n@'+routine['id']))
        before = s.store.events.snapshot(child)[child]
        s.snapshot(); s.snapshot()
        self.assertEqual(s.store.events.snapshot(child)[child], before)
        pause = next(e for e in before if e['event'] == 'routine.paused')
        self.assertEqual(pause['actor'], 'admin')
        create = next(e for e in before if e['event'] == 'routine.created')
        self.assertEqual(create['actor'], child)
        s.orchestration.control(chief, dict(op='retire_agent', target=child, reason='Finished'))
        self.assertEqual(s.store.events.snapshot(child)[child][0]['event'], 'sapi.retired')
        s.orchestration.control(chief, dict(op='rehire_agent', target=child))
        self.assertEqual(s.store.events.snapshot(child)[child][0]['event'], 'sapi.restored')

    def test_group_scope_and_unrelated_sapi(self):
        s = self.service(start_worker=False)
        chief = s.registry.main
        member = s.create_agent(dict(name='Member', role='Research'))['id']
        outsider = s.create_agent(dict(name='Outside', role='Research'))['id']
        g = s.groups.create(dict(name='Team', lead=chief, members=[chief, member]), chief)
        for owner in (g['id'], chief, member):
            self.assertTrue(any(e['event'] == 'group.created' for e in s.store.events.snapshot(owner)[owner]))
        self.assertFalse(any(e['entity'] == g['id'] for e in s.store.events.snapshot(outsider)[outsider]))
        before = s.store.events.snapshot(g['id'])
        s.snapshot(); s.snapshot()
        self.assertEqual(s.store.events.snapshot(g['id']), before)

    def test_only_nonempty_pulses_and_real_execution_are_logged(self):
        s = self.service(start_worker=False)
        chief = s.registry.main
        s.pulse.clock = lambda: 0
        s.pulse.start()
        with s._lock:
            s.pulse.step(2)
        self.assertFalse(any(e['event'] == 'pulse.dispatched' for e in s.store.events.snapshot(chief)[chief]))
        turn = s.submit(chief, dict(text='Hello'))['id']
        with s._lock:
            s.pulse.step(4)
        import time
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if s.store.projected_turn(turn)['status'] == 'output_pending':
                break
            time.sleep(.01)
        with s._lock:
            s.pulse.step(6)
        rows = s.snapshot()['events'][chief]
        pulses = [e for e in rows if e['event'] == 'pulse.dispatched']
        self.assertEqual({e['agency'] for e in pulses}, {'chatInput', 'chatOutput'})
        self.assertEqual(len(pulses), 2)
        self.assertTrue(any(e['event'] == 'call.done' and e['agency'] == 'chatOutput' for e in rows))
        s.snapshot()
        self.assertEqual(s.store.events.snapshot(chief)[chief], rows)
