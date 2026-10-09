"""Scheduled prompts use durable chat, Automated tasks and real Agency slots."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from sapiens.corpora.host.service import Service
from sapiens.validation import APIError
from test_delegation import Provider


class RoutinesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.provider = Provider()
        self.at = 0
        self.epoch = datetime(2026, 10, 9, tzinfo=timezone.utc)
        self.clock = patch('sapiens.corpora.host.routines.utcnow', side_effect=lambda: self.epoch + timedelta(seconds=self.at))
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False,
                               pulse_clock=lambda: self.at)
        self.addCleanup(lambda: self.service.close())
        self.chief = self.service.registry.main
        self.other = self.service.create_agent(dict(name='Worker', role='Research'))['id']
        self.service.pulse.start()

    def create(self, owner=None, minutes=1, execution='Return a sourced comparison.'):
        owner = owner or self.chief
        text = f'Add New Scheduled Routine:\nFrequency: every {minutes} minutes\nExecute: {execution}'
        submit = self.service.groups.chat.submit if owner.startswith('group_') else self.service.submit
        submit(owner, dict(text=text))
        return self.service.store.routines()[-1]

    def tick(self, seconds):
        self.at += seconds
        with self.service._lock:
            self.service.pulse.step(self.at)
        deadline = time.monotonic() + 4
        while self.service.agencies.slots or self.service._runners:
            if time.monotonic() > deadline:
                self.fail('Agency did not finish')
            time.sleep(.005)
        self.service.snapshot()

    def occurrences(self):
        return [t for t in self.service.snapshot()['turns'] if (t.get('origin') or {}).get('routine')]

    def test_one_and_two_minutes_use_bph60_and_separate_automated_tasks(self):
        memo = Path(self.service._agent(self.chief).workspace, 'Notes.html')
        before = memo.read_bytes()
        one, two = self.create(), self.create(minutes=2)
        self.assertEqual(self.provider.calls, [])
        self.assertEqual(len(self.service.store.workloads()), 0)
        self.tick(59)
        self.assertEqual(self.occurrences(), [])
        self.tick(1)
        events = self.service.store.events.snapshot(self.chief)[self.chief]
        running = [e for e in events if e['event'] == 'task.running']
        self.assertTrue(running)
        self.assertTrue(all(e['agency'] == 'chatInput' for e in running))
        runs = self.occurrences()
        self.assertEqual([t['origin']['routine'] for t in runs], [one['id']])
        self.assertEqual(runs[0]['status'], 'output_pending')
        self.tick(2)
        self.assertEqual(self.occurrences()[0]['status'], 'output_pending')
        self.tick(58)
        runs = self.occurrences()
        self.assertEqual(len(runs), 3)
        self.assertEqual(sum(t['origin']['routine'] == two['id'] for t in runs), 1)
        self.assertEqual(sum(t['status'] == 'done' for t in runs), 1)
        self.assertTrue(all(len(t['batch_members']) == 1 for t in runs))
        self.assertTrue(all(p['frequency'] == 'bph60' for p in self.service.store.pulse_calls()))
        self.assertEqual({w['task']['taskType'] for w in self.service.store.workloads()}, {'automated'})
        self.assertEqual(len(self.service.delegation.task_list(self.chief)['tasks']), 3)
        self.assertTrue(all('Memo is read-only by default' in p for _, _, p in self.provider.calls))
        self.assertEqual(memo.read_bytes(), before)

    def test_edit_keeps_id_resets_interval_and_preserves_previous_run_prompt(self):
        routine = self.create()
        self.tick(60)
        text = f"Edit @{routine['id']} ( {routine['title']} )\nEdit Frequency (prev every 1 minutes): new every 2 minutes\nEdit Execution Prompt as: Update Memo with the comparison.\nKeep existing facts."
        self.service.submit(self.chief, dict(text=text))
        updated = self.service.store.routines()[0]
        self.assertEqual(updated['id'], routine['id'])
        self.assertEqual(updated['minutes'], 2)
        self.assertLessEqual(len(updated['title'].split()), 7)
        self.tick(60)
        self.assertEqual(len(self.occurrences()), 1)
        self.tick(60)
        runs = self.occurrences()
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[0]['input'], routine['prompt'])
        self.assertEqual(runs[1]['input'], updated['prompt'])
        self.assertIn('explicitly asks for a Memo update', self.provider.calls[-1][2])
        with self.assertRaisesRegex(APIError, 'Frequency changed'):
            self.service.submit(self.chief, dict(text=text))
        with self.assertRaisesRegex(APIError, 'Unknown Scheduled Routine'):
            self.service.submit(self.other, dict(text=text))

    def test_invalid_templates_do_not_create_or_execute_work(self):
        for frequency, execution in [('XXX','PROMPT'), ('0','Hello'), ('1.5','Hello'), ('1','PROMPT')]:
            with self.assertRaises(APIError):
                self.service.submit(self.chief, dict(text=f'Add New Scheduled Routine:\nFrequency: every {frequency} minutes\nExecute: {execution}'))
        self.assertEqual(self.service.store.routines(), [])
        self.assertEqual(self.provider.calls, [])
        self.create(self.other)
        self.tick(60)
        self.assertEqual(self.occurrences()[0]['agent'], self.other)

    def test_restart_no_backfill_and_duplicate_tick_is_idempotent(self):
        routine = self.create()
        self.service.close()
        self.at = 600
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False,
                               pulse_clock=lambda: self.at)
        self.service.pulse.start()
        self.tick(60)
        self.assertEqual(len(self.occurrences()), 1)
        self.assertEqual(self.service.store.routines()[0]['id'], routine['id'])
        tick = dict(frequency='bph60', num=11, pulseId='duplicate')
        with self.service._lock:
            self.service.routines.dispatch(tick)
        self.assertEqual(len(self.occurrences()), 1)

    def test_tick_jitter_does_not_skip_the_next_minute(self):
        self.create()
        self.tick(60.04)
        self.tick(59.97)
        self.assertEqual(len(self.occurrences()), 2)

    def test_pause_edit_and_explicit_resume_for_sapi_and_group(self):
        group = self.service.groups.create(dict(name='Research', description='Research',
            lead=self.chief, members=[self.chief, self.other]))
        for owner in (self.other, group['id']):
            routine = self.create(owner)
            submit = self.service.groups.chat.submit if owner.startswith('group_') else self.service.submit
            submit(owner, dict(text=f"Pause Schedule Riutine\n@{routine['id']}"))
            edited = self.service.routines.save(owner, 2, 'Updated instructions.', routine_id=routine['id'])
            self.assertTrue(edited['paused'])
            self.assertEqual(edited['runCount'], 0)
            self.tick(180)
            self.assertFalse(any(t['origin']['routine'] == routine['id'] for t in self.occurrences()))
            with self.assertRaisesRegex(APIError, 'Unknown Scheduled Routine'):
                self.service.routines.set_paused(self.chief, routine['id'], False)
            submit(owner, dict(text=f"Resume Scheduled Routine\n@{routine['id']}"))
            resumed = next(r for r in self.service.store.routines() if r['id'] == routine['id'])
            self.assertFalse(resumed['paused'])
            self.assertEqual(resumed['nextDue'], (self.epoch + timedelta(seconds=self.at + 120)).isoformat())
            self.tick(120)
            paused = self.service.routines.set_paused(owner, routine['id'], True)
            self.assertEqual(paused['runCount'], 1)
            resumed = self.service.routines.set_paused(owner, routine['id'], False)
            self.assertEqual(resumed['runCount'], 1)
            self.service.routines.set_paused(owner, routine['id'], True)

    def test_limit_pauses_at_1000_and_only_resume_resets_allowance(self):
        routine = self.create()
        routine['runCount'] = 999
        self.service.store.save_routine(routine)
        self.tick(60)
        current = self.service.store.routines()[0]
        self.assertEqual(current['runCount'], 1000)
        self.assertTrue(current['paused'])
        self.tick(180)
        self.assertEqual(len(self.occurrences()), 1)
        edited = self.service.routines.save(self.chief, 2, 'New execution.', routine_id=routine['id'])
        self.assertTrue(edited['paused'])
        self.assertEqual(edited['runCount'], 1000)
        self.service.close()
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False,
                               pulse_clock=lambda: self.at)
        self.assertTrue(self.service.store.routines()[0]['paused'])
        resumed = self.service.orchestration.control(self.chief, dict(op='routine_resume', id=routine['id']))['routine']
        self.assertEqual(resumed['runCount'], 0)
        self.assertFalse(resumed['paused'])
        self.service.pulse.start()
        self.tick(120)
        self.assertEqual(self.service.store.routines()[0]['runCount'], 1)
        self.assertEqual(len(self.occurrences()), 2)

    def test_existing_routine_count_migrates_from_occurrences(self):
        routine = self.create()
        self.tick(60)
        self.tick(60)
        legacy = self.service.store.routines()[0]
        legacy.pop('runCount')
        legacy.pop('paused')
        self.service.store.save_routine(legacy)
        self.service.close()
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False)
        migrated = self.service.store.routines()[0]
        self.assertEqual(migrated['id'], routine['id'])
        self.assertEqual(migrated['runCount'], 2)
        self.assertFalse(migrated['paused'])

    def test_enqueue_crash_recovers_same_occurrence(self):
        self.create()
        self.at = 60
        tick = dict(frequency='bph60', num=1, pulseId='test')
        with patch.object(self.service, '_sync', side_effect=RuntimeError('projection crash')):
            with self.assertRaises(RuntimeError):
                self.service.routines.dispatch(tick)
        self.service.routines.dispatch(tick)
        self.assertEqual(len(self.occurrences()), 1)
        self.assertEqual(len(self.service.store.workloads()), 1)
        self.assertEqual(self.service.store.routines()[0]['runCount'], 1)

    def test_stopped_pulse_and_retired_sapi_do_not_fire(self):
        self.create(self.other)
        self.service.lifecycle.change(self.other, True)
        self.tick(60)
        self.assertEqual(self.occurrences(), [])
        self.service.lifecycle.change(self.other, False)
        self.service.stop_pulse()
        self.tick(60)
        self.assertEqual(self.occurrences(), [])
        self.service.pulse.start()
        self.tick(60)
        self.assertEqual(len(self.occurrences()), 1)

    def test_group_lead_handoff_preserves_routine_and_memo_rule(self):
        group = self.service.groups.create(dict(name='Research', description='Research',
            lead=self.chief, members=[self.chief, self.other]))
        self.provider.responses[self.chief, 'group'] = '@Worker Return a sourced comparison.'
        self.provider.responses[self.other, 'group'] = 'Comparison complete.'
        routine = self.create(group['id'], minutes=10)
        self.tick(600)
        self.tick(60)
        self.tick(2)  # Existing Group reconciliation delivers the Lead's handoff.
        current = self.service.groups.get(group['id'])
        task = current['tasks'][0]
        self.assertEqual(task['taskType'], 'automated')
        self.assertEqual(task['assignee'], self.other)
        self.assertEqual(task['state'], 'in_progress')
        self.assertTrue(any(r.get('origin', {}).get('routine') == routine['id'] and r['target'] == self.other for r in current['requests']))
        self.tick(58)
        self.assertTrue(any(a == self.other and node == 'group' for a, node, _ in self.provider.calls))
        self.assertTrue(all('Memo is read-only by default' in p for _, _, p in self.provider.calls))
        self.assertTrue(all(p['frequency'] == 'bph60' for p in self.service.store.pulse_calls()))

        self.tick(60)
        current = self.service.groups.get(group['id'])
        self.assertEqual(current['tasks'][0]['state'], 'done')
        self.assertEqual(len(current['tasks'][0]['results']), 1)
        self.assertEqual(current['tasks'][0]['results'][0]['author'], self.other)
        self.assertEqual(len(current['requests']), 2)
        self.assertFalse(any(r.get('memo') for r in current['requests']))
        for agid in (self.chief, self.other):
            self.assertFalse(any((m.get('origin') or {}).get('group') for m in self.service._agent(agid).state['chat']))
        self.assertEqual(self.service.store.routines()[0]['runCount'], 1)

    def test_group_limit_counts_one_occurrence_and_preserves_migration(self):
        group = self.service.groups.create(dict(name='Research', description='Research',
            lead=self.chief, members=[self.chief, self.other]))
        routine = self.create(group['id'])
        self.tick(60)
        legacy = self.service.store.routines()[0]
        legacy.pop('runCount')
        legacy.pop('paused')
        self.service.store.save_routine(legacy)
        self.service.close()
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False,
                               pulse_clock=lambda: self.at)
        current = self.service.store.routines()[0]
        self.assertEqual(current['runCount'], 1)
        current['runCount'] = 999
        self.service.store.save_routine(current)
        self.service.pulse.start()
        self.tick(60)
        self.tick(120)
        current = self.service.store.routines()[0]
        self.assertTrue(current['paused'])
        self.assertEqual(current['runCount'], 1000)
        self.assertEqual(len(self.service.groups.get(group['id'])['tasks']), 2)

    def test_group_handoff_does_not_overwrite_a_newer_task_revision(self):
        group = self.service.groups.create(dict(name='Research', description='Research',
            lead=self.chief, members=[self.chief, self.other]))
        self.provider.responses[self.chief, 'group'] = '@Worker Execute this.'
        self.create(group['id'], minutes=10)
        self.tick(600)
        task = self.service.groups.get(group['id'])['tasks'][0]
        self.service.groups.work.update(group['id'], task['id'], dict(revision=task['revision'], title='Changed by Admin'))
        self.tick(60)
        current = self.service.groups.get(group['id'])
        self.assertEqual(len(current['requests']), 1)
        self.assertEqual(current['tasks'][0]['title'], 'Changed by Admin')
        self.assertEqual(current['tasks'][0]['assignee'], self.chief)
        self.assertTrue(current['tasks'][0]['results'][0]['stale'])

    def test_sapi_host_control_uses_same_owner_and_persistence_as_chat(self):
        control = self.service.orchestration.control
        run = self.service.submit(self.other, dict(text='Set up a recurring comparison'))['id']
        with self.service._agent(self.other).transaction() as state:
            state['turns'][-1]['status'] = 'running'
        data = dict(op='routine_create', minutes=2, prompt='Compare the products.', agencyRun=run)
        routine = control(self.other, data)['routine']
        self.assertEqual(control(self.other, data)['routine'], routine)
        self.assertEqual(len(self.service.store.routines()), 1)
        self.assertEqual(routine['sourceCall'], run)
        self.assertEqual(routine['owner'], self.other)
        updated = control(self.other, dict(op='routine_update', id=routine['id'], minutes=1, prompt='Compare again.'))['routine']
        self.assertEqual(updated['id'], routine['id'])
        self.assertEqual(control(self.other, dict(op='routines'))['routines'], [updated])
        self.assertEqual(control(self.chief, dict(op='routines'))['routines'], [])
        with self.assertRaisesRegex(APIError, 'Unknown Scheduled Routine'):
            control(self.chief, dict(op='routine_update', id=routine['id'], minutes=1, prompt='Hijack'))
        for data in [dict(op='routine_create',minutes=True,prompt='No'),
                     dict(op='routine_update',id='',minutes=1,prompt='No'),
                     dict(op='routine_create',target=self.other,minutes=1,prompt='No')]:
            with self.assertRaises(APIError):control(self.chief,data)

    def test_chief_creation_hands_routine_setup_to_new_sapi(self):
        from test_delegation import answer
        self.provider.responses[self.chief, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('NewSpecialistNeeded')
        self.provider.responses['CreatingSapi'] = answer('SapiSpecified', name='JokeScout', role='Joke research')
        self.provider.responses['Delegation'] = answer('HandoffPrepared', request='Create your own Scheduled Routine every two minutes to collect jokes.')
        def execute(agid, node, rendered):
            if node == 'Execution':
                self.service.orchestration.control(agid, dict(op='routine_create', minutes=2, prompt='Find a short AGI joke and append it to agi-si-jokes.txt.'))
        self.provider.observe = execute
        self.service.submit(self.chief, dict(text='Create JokeScout to collect jokes every two minutes.'))
        for _ in range(5):self.tick(2)
        routine = self.service.store.routines()[0]
        child = next(a['id'] for a in self.service.store.agents() if a['name'] == 'JokeScout')
        self.assertEqual(routine['owner'], child)
        self.assertEqual(routine['minutes'], 2)
        self.assertEqual([c['addressedTo'] for c in self.service.store.workloads()[0]['calls']], [self.chief, child])
        self.assertFalse(any(a == self.chief and node == 'Execution' for a,node,_ in self.provider.calls))
