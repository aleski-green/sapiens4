"""Autonomy regressions: count due occurrences, not just admitted model calls."""
import asyncio
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
import time

from test_integration import IntegrationFixture, ScriptedFactory, ScriptedLLM
from test_orchestration import MemoryFactory
from sapiens import strategy
from sapiens.memory import current_fingerprint, last_fingerprint
from sapiens.service import APIError


class VerifiedLLM(ScriptedLLM):
    tool_count = 20
    repeated_tools = 3  # Deliberate before/paste/after verification reads.


class VerifiedFactory(ScriptedFactory):
    def spawn(self, spec):
        return VerifiedLLM(self)


class AutonomyTest(IntegrationFixture):
    def setup_delivery(self, ready=True):
        self.factory = VerifiedFactory()
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid, dict(op='schedule', enabled=False))
        row = service.work.upsert(agent, dict(title='Fixture delivery', prompt='Deliver one item to the local test sink',
                                              minutes=360, watch={'mode': 'always'}))
        if ready:
            self.ready_strategy(service, agent, row)
        self.deliveries = []
        def deliver(prompt):
            occurrence = prompt.split('Occurrence: ')[1].split('\n')[0]
            self.assertNotIn(occurrence, self.deliveries, 'Duplicate delivery')
            self.deliveries.append(occurrence)
            service = self.services[-1]
            service.orchestration.control(agent.agid, dict(op='checkpoint', id=row['id'], status='ok',
                outcome='useful', summary='Independent fixture sink received one item', value={'occurrence': occurrence}))
        self.factory.on_complete = deliver
        return service, agent, row, datetime.fromisoformat(row['next_run'])

    def test_300_unattended_occurrences_survive_warnings_and_restarts(self):
        service, agent, row, due = self.setup_delivery()
        rows = service.work.read(agent)
        rows[0]['strategy']['expected_units'] = 1
        service.work.save(agent, rows)
        for i in range(300):
            now = due + timedelta(hours=6*i)
            service.scheduled(now)
            service.scheduled(now+timedelta(seconds=1))
            saved = service.work.read(agent)[0]
            self.assertEqual(strategy.state(saved), 'ready')
            self.assertEqual(len(self.deliveries), i+1)
            self.assertEqual(datetime.fromisoformat(saved['next_run']), now+timedelta(hours=6))
            self.assertEqual(len(saved['feedback'][-1]['efficiency_warnings']), 2)
            if i % 30 == 29:
                service = self.restart(service, start_worker=False)
                agent = service._agent(agent.agid)
        self.assertEqual(len(set(self.deliveries)), 300)
        self.assertFalse(any(j['flow'] == 'strategy' for j in agent.state['jobs']))

    def test_planning_preserves_due_occurrence_and_runs_after_restart(self):
        service, agent, row, due = self.setup_delivery(ready=False)
        deliver = self.factory.on_complete
        self.factory.on_complete = lambda _: self.ready_strategy(service, agent, row)
        service.scheduled(due)
        self.assertEqual(service.work.read(agent)[0]['next_run'], row['next_run'])
        self.assertEqual(self.deliveries, [])
        service = self.restart(service, start_worker=False)
        agent = service._agent(agent.agid)
        self.factory.on_complete = deliver
        service.scheduled(due+timedelta(minutes=1))
        service.scheduled(due+timedelta(minutes=2))
        self.assertEqual(self.deliveries, [row['next_run']])
        self.assertEqual(datetime.fromisoformat(service.work.read(agent)[0]['next_run']), due+timedelta(hours=6))

    def test_review_cap_retains_occurrence_until_ready(self):
        service, agent, row, due = self.setup_delivery()
        rows = service.work.read(agent)
        rows[0]['strategy'].update(status='review_needed', reason='Outcome needs reconciliation')
        rows[0]['planning_attempts'] = [dict(time=due.isoformat(), kind='review_needed', signature=strategy.signature(rows[0]))]
        service.work.save(agent, rows)
        service.scheduled(due)
        service.scheduled(due+timedelta(minutes=10))
        self.assertEqual(service.work.read(agent)[0]['next_run'], row['next_run'])
        self.assertEqual(self.deliveries, [])
        self.ready_strategy(service, agent, row)
        service.scheduled(due+timedelta(minutes=11))
        self.assertEqual(self.deliveries, [row['next_run']])

    def test_planner_changes_wake_limits_without_using_delivery_cooldown(self):
        service, agent, row, due = self.setup_delivery(ready=False)
        deliver = self.factory.on_complete
        self.factory.on_complete = lambda _: service.orchestration.control(agent.agid, dict(
            op='strategy', id=row['id'], status='ready', approach='Verified local procedure',
            success='One verified local delivery', scope='Local fixture only', expected_units=100,
            generation_reason='Generate each interval', watch={'mode':'always', 'max_per_hour':1, 'max_per_day':4}))
        service.scheduled(due)
        self.factory.on_complete = deliver
        service.scheduled(due+timedelta(seconds=1))
        self.assertEqual(self.deliveries, [row['next_run']])
        self.assertEqual(len(service.work.read(agent)[0]['detector']['wakes']), 1)

    def test_blocked_occurrence_does_not_starve_other_ready_jobs(self):
        service, agent, row, due = self.setup_delivery()
        rows = service.work.read(agent)
        blocked = deepcopy(rows[0])
        blocked.update(id='blocked-earlier-goal', next_run=(due-timedelta(hours=6)).isoformat())
        blocked['strategy'].update(status='blocked', reason='Missing capability')
        service.work.save(agent, [blocked, rows[0]])
        service.scheduled(due)
        self.assertEqual(self.deliveries, [row['next_run']])
        self.assertEqual(service.work.read(agent)[0]['next_run'], blocked['next_run'])

    def test_later_review_of_same_occurrence_gets_a_new_run(self):
        service, agent, row, due = self.setup_delivery()
        self.factory.on_complete = lambda _: self.ready_strategy(service, agent, row)
        planned = []
        for instant in (due, due+timedelta(days=2)):
            rows = service.work.read(agent)
            rows[0]['strategy'].update(status='review_needed', reason='Reconcile current evidence')
            service.work.save(agent, rows)
            service.scheduled(instant)
            saved = service.work.read(agent)[0]
            planned.append(saved['runs'][-1]['id'])
            self.assertEqual(strategy.state(saved), 'ready')
            self.assertEqual(saved['next_run'], row['next_run'])
        self.assertEqual(len(set(planned)), 2)

    def test_downtime_coalesces_with_explicit_receipt_and_anchored_cadence(self):
        service, agent, row, due = self.setup_delivery()
        service.scheduled(due+timedelta(hours=13))
        saved = service.work.read(agent)[0]
        self.assertEqual(self.deliveries, [row['next_run']])
        self.assertEqual(saved['missed_occurrences'][-1]['count'], 2)
        self.assertEqual(datetime.fromisoformat(saved['next_run']), due+timedelta(hours=18))

    def test_failed_or_unverified_actions_never_replay_automatically(self):
        service, agent, row, due = self.setup_delivery()
        self.factory.fail = True
        service.scheduled(due)
        self.factory.fail = False
        for i in range(1, 5):
            service.scheduled(due+timedelta(hours=6*i))
        self.assertEqual(self.deliveries, [])
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(strategy.state(service.work.read(agent)[0]), 'review_needed')

    def test_legacy_advisory_only_review_is_recovered_but_real_blocker_is_not(self):
        service, agent, row, due = self.setup_delivery()
        service.scheduled(due)
        rows = service.work.read(agent)
        rows[0]['strategy'].update(status='review_needed', reason='Last run repeated tool calls')
        service.work.save(agent, rows)
        service = self.restart(service, start_worker=False)
        agent = service._agent(agent.agid)
        self.assertEqual(strategy.state(service.work.read(agent)[0]), 'ready')
        blocked = deepcopy(rows[0])
        blocked['strategy']['reason'] = 'Execution stopped; diagnose recorded evidence before any explicit retry'
        self.assertFalse(strategy.restore_verified_plan(blocked))


class MemoryAutonomyTest(IntegrationFixture):
    def test_1000_records_learn_in_bounded_batches_across_restart(self):
        self.factory = MemoryFactory()
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid, dict(op='schedule', enabled=False))
        with agent.store.transaction() as state:
            state['notes'] = [dict(flow='task', content=f'UNIQUE_EXPERIENCE_{i:04d}: '+('verified procedure ' * 8)) for i in range(1000)]
            state['chat_revision'] += 1
        service.orchestration.control(agent.agid, dict(op='consolidate'))
        service.scheduled()
        self.assertTrue(agent.state['memory_pending'])
        self.assertLess(agent.state['learned_revision'], agent.state['chat_revision'])
        service = self.restart(service, start_worker=False)
        agent = service._agent(agent.agid)
        for _ in range(60):
            if not agent.state.get('memory_pending'):
                break
            service.scheduled()
        self.assertFalse(agent.state['memory_pending'])
        self.assertEqual(agent.state['learned_revision'], agent.state['chat_revision'])
        self.assertEqual(current_fingerprint(service, agent), last_fingerprint(agent))
        self.assertTrue(all(len(p) <= agent.limits.context_chars for p in self.factory.prompts))
        all_prompts = '\n'.join(self.factory.prompts)
        for i in range(1000):
            self.assertIn(f'UNIQUE_EXPERIENCE_{i:04d}', all_prompts)
        self.assertNotIn('Internal Sapiens4 operations', all_prompts)
        self.assertEqual(len(agent.state['notes']), 1000)
        count = len(self.factory.prompts)
        service.orchestration.control(agent.agid, dict(op='consolidate'))
        service.scheduled()
        self.assertEqual(len(self.factory.prompts), count)

    def test_legacy_context_preflight_failure_recovers_without_human_retry(self):
        self.factory = MemoryFactory()
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid, dict(op='schedule', enabled=False))
        run = agent.submit('learning')
        with agent.store.transaction() as state:
            state['jobs'][-1].update(status='failed', tokens=0, error='ValueError: Prompt exceeds context limit; consolidate memory')
        service.scheduled()
        jobs = agent.state['jobs']
        self.assertEqual(next(j['status'] for j in jobs if j['id'] == run), 'cancelled')
        self.assertEqual(jobs[-1]['status'], 'done')
        self.assertEqual(jobs[-1]['flow'], 'learning')

    def test_finished_task_is_excluded_and_self_completion_is_deferred(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        task = service.orchestration.control(agent.agid, dict(op='task', title='OBSOLETE_REPAIR_DO_NOT_SEND'))['task_id']
        run = service.work.admit_task(agent, task)
        def finish(_):
            receipt = service.orchestration.control(agent.agid, dict(op='finish_task', id=task))
            self.assertEqual(receipt['completion_requested'], task)
            self.assertTrue(agent.state['tasks'])
        self.factory.on_complete = finish
        asyncio.run(agent.run())
        service._sync(agent)
        self.assertEqual(agent.state['tasks'], [])
        self.assertEqual(next(j['status'] for j in agent.state['jobs'] if j['id'] == run), 'done')
        self.factory.on_complete = None
        service.submit(agent.agid, dict(text='What is your name?'))
        asyncio.run(agent.run())
        self.assertNotIn('OBSOLETE_REPAIR_DO_NOT_SEND', self.factory.prompts[-1])

    def test_finished_unclosed_repair_does_not_enter_scheduled_context(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        task = service.orchestration.control(agent.agid, dict(op='task', title='OBSOLETE_PERMISSION_REPAIR'))['task_id']
        service.work.admit_task(agent, task)
        asyncio.run(agent.run())
        service._sync(agent)
        row = service.work.upsert(agent, dict(title='Current goal', prompt='Current goal only', minutes=360, watch={'mode':'always'}))
        self.ready_strategy(service, agent, row)
        service.scheduled(datetime.fromisoformat(row['next_run']))
        self.assertNotIn('OBSOLETE_PERMISSION_REPAIR', self.factory.prompts[-1])
        self.assertEqual(agent.state['tasks'][0]['status'], 'open')  # Review is still possible.


class ChiefAutonomyTest(IntegrationFixture):
    def test_worker_detects_delegates_repairs_and_closes_without_polling_tasks(self):
        service = self.service(start_worker=False)
        chief = service._agent(service.hierarchy.main)
        child = service._agent(service.create_agent({'name':'Worker','role':'Local benchmark worker'})['id'])
        service.orchestration.control(child.agid, dict(op='schedule', enabled=False))
        row = service.work.upsert(child, dict(title='Local routine', prompt='Write a local report', minutes=360, watch={'mode':'always'}))
        self.ready_strategy(service, child, row)
        rows = service.work.read(child)
        rows[0]['strategy'].update(status='review_needed', reason='Procedure requires a corrected observation plan')
        service.work.save(child, rows)
        config = service.orchestration.settings(chief)
        self.assertTrue(config['monitor_team'])
        config['next_check'] = datetime.now(timezone.utc).isoformat()
        service.orchestration.save(chief, config)
        with chief.store.transaction() as state:
            state['last_circa'] = (datetime.now(timezone.utc)+timedelta(days=1)).isoformat()
        assigned = []
        def respond(prompt):
            if 'Team evidence:' in prompt:
                diagnostic = service.orchestration.control(chief.agid, dict(op='job_diagnostics', target=child.agid))
                self.assertEqual(diagnostic['jobs'][0]['strategy_state'], 'review_needed')
                assigned.append(service.orchestration.control(chief.agid, dict(op='task', target=child.agid,
                    title='REPAIR_LOCAL_PROCEDURE and request completion', start=True)))
            elif 'REPAIR_LOCAL_PROCEDURE' in prompt:
                self.ready_strategy(service, child, row)
                service.orchestration.control(child.agid, dict(op='finish_task', id=assigned[0]['task_id']))
        self.factory.on_complete = respond
        service.start()
        deadline = time.monotonic()+5
        while time.monotonic() < deadline and (not assigned or child.state['tasks']):
            time.sleep(.02)
        self.assertEqual(len(assigned), 1)
        self.assertEqual(child.state['tasks'], [])
        self.assertEqual(strategy.state(service.work.read(child)[0]), 'ready')
        self.assertEqual(len(self.factory.prompts), 2)

    def test_only_manager_can_finish_another_sapis_task(self):
        service = self.service(start_worker=False)
        chief = service.hierarchy.main
        child = service.create_agent({'name':'Child','role':'Worker'})['id']
        peer = service.create_agent({'name':'Peer','role':'Worker'})['id']
        task = service.orchestration.control(child, dict(op='task', title='Verified work'))['task_id']
        with self.assertRaises(APIError):
            service.orchestration.control(peer, dict(op='finish_task', target=child, id=task))
        service.orchestration.control(chief, dict(op='finish_task', target=child, id=task))
        self.assertEqual(service._agent(child).state['tasks'], [])
