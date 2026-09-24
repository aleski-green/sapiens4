from datetime import datetime, timedelta, timezone
import asyncio
from unittest.mock import patch

from test_integration import IntegrationFixture
from test_watch import PLAN, observation
from sapiens.service import APIError
from sapiens import strategy


class StrategyTest(IntegrationFixture):
    def setup_job(self, **extra):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid, dict(op='schedule', enabled=False))
        row = service.work.upsert(agent, dict(title='Observe', prompt='Report relevant changes',
                                              minutes=1, **extra))
        return service, agent, row, datetime.fromisoformat(row['next_run']) if row['next_run'] else datetime.now(timezone.utc)

    def plan(self, service, agent, row, **extra):
        return service.orchestration.control(agent.agid, dict(op='strategy', id=row['id'],
            status='ready', approach='Observe the relevant list once, compare previews',
            success='Verify and report a relevant change', scope='Visible rows only',
            expected_units=100, watch=dict(probe=PLAN, cooldown_minutes=1), **extra))

    def test_agent_setup_persists_verified_plan_then_unchanged_costs_zero(self):
        service, agent, row, now = self.setup_job()
        def choose(prompt):
            self.assertIn('You own the approach', prompt)
            self.plan(service, agent, row)
        self.factory.on_complete = choose
        with patch('sapiens.watch.observe', return_value=observation()) as probe:
            service.scheduled(now)
            self.assertEqual(probe.call_count, 1)  # host tests the agent's chosen plan
            saved = service.work.read(agent)[0]
            self.assertEqual(strategy.state(saved), 'ready')
            self.assertEqual(saved['runs'][0]['kind'], 'strategy')
            self.assertEqual(saved['strategy']['test']['rows'], 1)
            service = self.restart(service, start_worker=False)
            service.scheduled(now+timedelta(minutes=1))
            service.scheduled(now+timedelta(minutes=2))
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(service.work.read(service._agent(agent.agid))[0]['detector']['skipped'], 2)

    def test_prose_only_setup_stops_without_timer_retries_even_after_restart(self):
        service, agent, row, now = self.setup_job()
        service.scheduled(now)
        saved = service.work.read(agent)[0]
        self.assertEqual(strategy.state(saved), 'blocked')
        service = self.restart(service, start_worker=False)
        for days in (1, 2, 7):
            service.scheduled(now+timedelta(days=days))
        self.assertEqual(len(self.factory.prompts), 1)

    def test_unsupported_capability_is_saved_without_polling_or_repeated_setup(self):
        service, agent, row, now = self.setup_job()
        self.factory.on_complete = lambda _: service.orchestration.control(agent.agid, dict(
            op='strategy', id=row['id'], status='blocked', approach='Need an event API for archived items',
            success='Cover archived changes', scope='Archived items unavailable', expected_units=100))
        with patch('sapiens.watch.observe') as probe:
            service.scheduled(now)
            service.scheduled(now+timedelta(days=1))
        probe.assert_not_called()
        saved = service.work.read(agent)[0]
        self.assertIn('event API', service.work.health(agent, saved)['reason'])
        self.assertEqual(len(self.factory.prompts), 1)

    def test_invalid_probe_and_unjustified_generation_cannot_activate(self):
        service, agent, row, now = self.setup_job()
        with patch('sapiens.watch.observe', side_effect=ValueError('Missing list')):
            with self.assertRaises(APIError): self.plan(service, agent, row)
        self.assertEqual(strategy.state(service.work.read(agent)[0]), 'needs_strategy')
        with self.assertRaises(APIError):
            service.orchestration.control(agent.agid, dict(op='strategy', id=row['id'], status='ready',
                approach='Generate', success='New report', scope='Self', expected_units=10, watch={'mode':'always'}))

    def test_paused_and_exhausted_jobs_do_not_start_planning(self):
        service, agent, row, now = self.setup_job(enabled=False)
        service.scheduled(datetime.now(timezone.utc)+timedelta(days=1))
        self.assertEqual(self.factory.prompts, [])
        row = service.work.upsert(agent, dict(id=row['id'], enabled=True))
        now = datetime.fromisoformat(row['next_run'])
        with agent.store.transaction() as state:
            state['budgets'][agent._sprint(now)] = dict(spent=agent.limits.tokens_per_sprint, reserved=0)
        service.scheduled(now)
        self.assertEqual(self.factory.prompts, [])
        with agent.store.transaction() as state:
            state['budgets'][agent._sprint(now)]['spent'] = 0
        service.scheduled(now+timedelta(minutes=1))
        self.assertEqual(len(self.factory.prompts), 1)

    def test_setup_enqueue_is_idempotent_after_partial_save(self):
        service, agent, row, now = self.setup_job()
        definition = service.work.check_due(agent, now)
        with patch.object(service.work, 'save', side_effect=OSError('disk')):
            with self.assertRaises(OSError): service.work.admit(agent, definition, now)
        service.work.admit(agent, definition, now)
        self.assertEqual(len(agent.state['jobs']), 1)
        self.assertEqual(len(service.work.read(agent)[0]['planning_attempts']), 1)

    def test_restart_recovers_orphan_planning_without_another_call(self):
        service, agent, row, now = self.setup_job()
        definition = service.work.check_due(agent, now)
        with patch.object(service.work, 'save', side_effect=OSError('disk')):
            with self.assertRaises(OSError): service.work.admit(agent, definition, now)
        service = self.restart(service, start_worker=False)
        agent = service._agent(agent.agid)
        self.assertEqual(len(service.work.read(agent)[0]['planning_attempts']), 1)
        asyncio.run(agent.run())
        service._sync(agent)
        service.scheduled(now+timedelta(days=1))
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(strategy.state(service.work.read(agent)[0]), 'blocked')

    def test_global_planning_cap_survives_goal_edits_and_restart(self):
        service, agent, row, now = self.setup_job()
        for i in range(3):
            service.work.upsert(agent, dict(id=row['id'], prompt=f'Goal revision {i}'))
            service.scheduled(now+timedelta(minutes=i))
        self.assertEqual(len(self.factory.prompts), 2)
        service = self.restart(service, start_worker=False)
        service.scheduled(now+timedelta(minutes=4))
        self.assertEqual(len(self.factory.prompts), 2)

    def test_cost_feedback_triggers_one_review_instead_of_more_routine_work(self):
        service, agent, row, now = self.setup_job()
        with patch('sapiens.watch.observe', return_value=observation()): self.plan(service, agent, row)
        # Deliberately low estimate to trigger measured-cost review (fixture costs 7).
        rows = service.work.read(agent); rows[0]['strategy']['expected_units'] = 1
        service.work.save(agent, rows)
        with patch('sapiens.watch.observe', return_value=observation('changed')):
            service.scheduled(now)
        saved = service.work.read(agent)[0]
        self.assertEqual(strategy.state(saved), 'review_needed')
        self.assertEqual(saved['feedback'][0]['units'], 7)
        def review(prompt):
            self.assertIn('cost estimate', prompt)
            self.assertIn('"units": 7', prompt)
            self.plan(service, agent, row)
        self.factory.on_complete = review
        with patch('sapiens.watch.observe', return_value=observation('changed')):
            service.scheduled(now+timedelta(minutes=1))
        saved = service.work.read(agent)[0]
        self.assertEqual(strategy.state(saved), 'ready')
        saved['strategy'].update(status='review_needed', reason='Another costly run')
        service.work.save(agent, [saved])
        self.factory.on_complete = None
        service.scheduled(now+timedelta(minutes=2))
        self.assertEqual(len(self.factory.prompts), 2)

    def test_verified_inaction_is_valid_but_missing_evidence_requires_review(self):
        service, agent, row, now = self.setup_job()
        with patch('sapiens.watch.observe', return_value=observation()): self.plan(service, agent, row)
        row = service.work.read(agent)[0]
        for i in range(2):
            run = dict(id=str(i), budget_units=7)
            row['checkpoint'] = dict(run=str(i), status='ok', outcome='no_change')
            strategy.feedback(row, run, [{'tools':2, 'usage':{'input_tokens':4}}])
        self.assertEqual(strategy.state(row), 'ready')
        for i in range(2, 4):
            row['checkpoint'] = dict(run=str(i), status='partial', outcome='no_change')
            strategy.feedback(row, dict(id=str(i), budget_units=7), [{'tools':1, 'usage':{'input_tokens':4}}])
        self.assertEqual(strategy.state(row), 'review_needed')
        row['strategy']['status'] = 'ready'; row['feedback'] = []
        strategy.feedback(row, dict(id='x', budget_units=7), [{'repeated_tools':2}])
        self.assertEqual(strategy.state(row), 'review_needed')

    def test_failed_execution_retains_feedback_without_automatic_replay(self):
        service, agent, row, now = self.setup_job(watch={'mode':'always'})
        self.ready_strategy(service, agent, row)
        self.factory.fail = True
        run = service.work.admit(agent, service.work.read(agent)[0], now, manual=True)
        asyncio.run(agent.run())
        # Simulate observations retained before a provider failure.
        import json
        path = next((agent.root / 'usage').glob('*.json'))
        attempt = json.loads(path.read_text())
        attempt['observations'] = [{'excerpt':'Source unavailable', 'time':now.isoformat()}]
        path.write_text(json.dumps(attempt))
        service._sync(agent)
        row = service.work.read(agent)[0]
        item = row['feedback'][0]
        self.assertEqual(item['status'], 'failed')
        self.assertEqual(item['units'], 7)
        self.assertIn('Scripted provider failure', item['error'])
        self.assertEqual(item['observations'][0]['excerpt'], 'Source unavailable')
        self.assertEqual(strategy.state(row), 'review_needed')
        service = self.restart(service, start_worker=False)
        service.scheduled(now+timedelta(days=1))
        agent = service._agent(agent.agid)
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(len(service.work.read(agent)[0]['feedback']), 1)
        self.assertEqual(next(j['status'] for j in agent.state['jobs'] if j['id']==run), 'failed')
        service.job_action(agent.agid, run, 'retry')
        asyncio.run(agent.run())
        service._sync(agent)
        feedback = service.work.read(agent)[0]['feedback']
        self.assertEqual(len(feedback), 2)
        self.assertEqual(feedback[-1]['status'], 'failed')
        self.assertEqual(feedback[-1]['observations'], [])

    def test_interruption_overrides_an_earlier_success_checkpoint(self):
        service, agent, row, now = self.setup_job()
        with patch('sapiens.watch.observe', return_value=observation()): self.plan(service, agent, row)
        row = service.work.read(agent)[0]
        row['checkpoint'] = dict(run='interrupted-run', status='ok', outcome='useful')
        strategy.feedback(row, dict(id='interrupted-run', status='interrupted',
                          error='Runner stopped', budget_units=100), [])
        self.assertEqual(row['feedback'][0]['outcome'], 'unknown')
        self.assertEqual(strategy.state(row), 'review_needed')

    def test_saved_checkpoint_belongs_to_its_run_and_policy_is_supplied(self):
        service, agent, row, now = self.setup_job()
        with patch('sapiens.watch.observe', return_value=observation()): self.plan(service, agent, row)
        self.factory.on_complete = lambda _: service.orchestration.control(agent.agid, dict(
            op='checkpoint', id=row['id'], status='ok', outcome='useful', summary='Verified change', value={}))
        with patch('sapiens.watch.observe', return_value=observation('changed')): service.scheduled(now)
        saved = service.work.read(agent)[0]
        self.assertEqual(saved['feedback'][0]['outcome'], 'useful')
        self.assertEqual(saved['checkpoint']['run'], saved['runs'][0]['id'])
        self.assertIn('Own the method as well as the goal', self.factory.prompts[-1])
        self.assertNotIn('phone-number-labelled candidates', self.factory.prompts[-1])
