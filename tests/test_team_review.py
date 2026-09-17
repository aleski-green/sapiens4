import asyncio
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from test_integration import IntegrationFixture


class TeamReviewTest(IntegrationFixture):
    def setup_team(self):
        service = self.service(start_worker=False)
        director = service._agent(service.hierarchy.main)
        child = service._agent(service.create_agent({'name':'Nova','role':'Research'})['id'])
        service.orchestration.control(director.agid, dict(op='schedule', monitor_team=True))
        service.orchestration.control(child.agid, dict(op='schedule', enabled=False))
        now = datetime.fromisoformat(service.orchestration.settings(director)['next_check'])
        # Avoid unrelated daily consolidation in these scheduling checks.
        with director.store.transaction() as state:
            state['last_circa'] = (now+timedelta(days=10)).isoformat()
        return service, director, child, now

    def fail_job(self, agent, text='Source unavailable'):
        run = agent.submit('task', 'Read source')
        with agent.store.transaction() as state:
            job = next(j for j in state['jobs'] if j['id']==run)
            job.update(status='failed', error=text)
        return run

    def test_new_problem_gets_one_briefing_and_survives_restart(self):
        service, director, child, now = self.setup_team()
        run = self.fail_job(child)
        service.scheduled(now)
        reviews = [j for j in director.state['jobs'] if j['flow']=='team_review']
        self.assertEqual(len(reviews), 1)
        self.assertEqual(reviews[0]['status'], 'done')
        self.assertIn('Source unavailable', self.factory.prompts[0])
        self.assertEqual(director.state['chat'][-1]['role'], 'agent')
        service = self.restart(service, start_worker=False)
        director, child = service._agent(director.agid), service._agent(child.agid)
        service.scheduled(now+timedelta(minutes=10))
        self.assertEqual(len(self.factory.prompts), 1)
        child.cancel(run)
        service.scheduled(now+timedelta(minutes=20))
        self.assertEqual(len(self.factory.prompts), 1)
        self.fail_job(child)
        service.scheduled(now+timedelta(minutes=30))
        self.assertEqual(len(self.factory.prompts), 2)

    def test_budget_and_daily_cap_defer_problems_without_losing_them(self):
        service, director, child, now = self.setup_team()
        self.fail_job(child)
        with patch.object(director, 'can_admit', return_value=False):
            service.scheduled(now)
        self.assertFalse(self.factory.prompts)
        service.scheduled(now+timedelta(minutes=10))
        self.fail_job(child, 'Second problem')
        service.scheduled(now+timedelta(minutes=20))
        self.fail_job(child, 'Third problem')
        service.scheduled(now+timedelta(minutes=30))
        self.assertEqual(len(self.factory.prompts), 2)
        service = self.restart(service, start_worker=False)
        service.scheduled(now+timedelta(days=1, minutes=11))
        self.assertEqual(len(self.factory.prompts), 3)
        self.assertIn('Third problem', self.factory.prompts[-1])
        self.assertNotIn('Second problem', self.factory.prompts[-1])

    def test_enqueue_and_issue_receipt_are_atomic(self):
        service, director, child, now = self.setup_team()
        self.fail_job(child)
        original = director._enqueue
        def crash(*args, **kwargs):
            original(*args, **kwargs)
            raise OSError('Interrupted transaction')
        with patch.object(director, '_enqueue', side_effect=crash):
            service.scheduled(now)
        self.assertFalse(director.state['jobs'])
        service = self.restart(service, start_worker=False)
        service.scheduled(now+timedelta(minutes=10))
        self.assertEqual(len(self.factory.prompts), 1)

    def test_disabled_monitoring_and_unrelated_sapis_do_not_trigger_reviews(self):
        service, director, child, now = self.setup_team()
        peer = service._agent(service.create_agent({'name':'Sage','role':'Research'})['id'])
        service.orchestration.control(peer.agid, dict(op='schedule', enabled=False))
        self.fail_job(peer)
        service.orchestration.control(director.agid, dict(op='schedule', monitor_team=False))
        service.scheduled(now+timedelta(minutes=10))
        self.assertFalse(self.factory.prompts)
        service.orchestration.control(child.agid, dict(op='schedule', enabled=True, monitor_team=True))
        service.scheduled(now+timedelta(minutes=20))
        self.assertFalse(self.factory.prompts)

    def test_failed_briefing_does_not_replay_or_block_human_chat(self):
        service, director, child, now = self.setup_team()
        self.fail_job(child)
        self.factory.fail = True
        service.scheduled(now)
        service.scheduled(now+timedelta(minutes=10))
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(service.work.blocking(director), [])
        self.factory.fail = False
        service.submit(director.agid, {'text':'Let me explain the source'})
        asyncio.run(director.run())
        self.assertEqual(director.state['chat'][-1]['role'], 'agent')
