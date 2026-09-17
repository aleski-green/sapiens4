from datetime import datetime, timedelta, timezone
import asyncio
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.service import APIError
from sapiens import watch


PLAN = dict(bundle_id='example.chat', container_id='ChatList', names=[])


def observation(value='first', name='Nova'):
    return watch.extract(dict(tree=dict(identifier='ChatList', children=[
        dict(role='AXButton', description=name, value=value),
        dict(role='AXGroup', description='Filters', children=[dict(role='AXButton', description='Unread')])
    ]), truncated=False), PLAN)


class WatchTest(IntegrationFixture):
    def setup_watch(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        service.orchestration.control(agent.agid,dict(op='schedule',enabled=False))
        row = service.work.upsert(agent,dict(title='Watch',prompt='Observe changes',minutes=1,
            watch=dict(mode='changes',probe=PLAN,cooldown_minutes=1,max_per_hour=2,max_per_day=3)))
        with patch('sapiens.watch.observe', return_value=observation()):
            self.ready_strategy(service, agent, row)
        self.factory.on_complete = lambda _: self.services[-1].orchestration.control(agent.agid, dict(
            op='checkpoint', id=row['id'], status='ok', outcome='useful', summary='Verified change', value={}))
        return service, agent, row, datetime.fromisoformat(row['next_run'])

    def test_unchanged_checks_cost_zero_and_survive_restart(self):
        service, agent, row, now = self.setup_watch()
        with patch('sapiens.watch.observe',return_value=observation()):
            for i in range(5):service.scheduled(now+timedelta(minutes=i))
            service=self.restart(service,start_worker=False)
            service.scheduled(now+timedelta(minutes=5))
        row=service.work.read(service._agent(agent.agid))[0]
        self.assertEqual(self.factory.prompts,[])
        self.assertEqual(row['detector']['checks'],6)
        self.assertEqual(row['detector']['skipped'],6)
        self.assertEqual(row['runs'],[])

    def test_change_runs_once_commits_baseline_and_enforces_caps(self):
        service, agent, row, now = self.setup_watch()
        with patch('sapiens.watch.observe',return_value=observation()):service.scheduled(now)
        with patch('sapiens.watch.observe',return_value=observation('new')):
            service.scheduled(now+timedelta(minutes=1))
            service.scheduled(now+timedelta(minutes=2))
        self.assertEqual(len(self.factory.prompts),1)
        with patch('sapiens.watch.observe',return_value=observation('newer')):service.scheduled(now+timedelta(minutes=3))
        with patch('sapiens.watch.observe',return_value=observation('latest')):service.scheduled(now+timedelta(minutes=4))
        self.assertEqual(len(self.factory.prompts),2)
        row=service.work.read(agent)[0]
        self.assertEqual(row['detector']['status'],'throttled')
        self.assertTrue(row['detector']['pending'])
        service=self.restart(service,start_worker=False)
        with patch('sapiens.watch.observe',return_value=observation('latest')):service.scheduled(now+timedelta(hours=2))
        self.assertEqual(len(self.factory.prompts),3)
        with patch('sapiens.watch.observe',return_value=observation('one more')):service.scheduled(now+timedelta(hours=4))
        self.assertEqual(len(self.factory.prompts),3) # rolling daily cap

    def test_budget_does_not_stop_scripts_or_forget_changes(self):
        service, agent, row, now = self.setup_watch()
        with patch('sapiens.watch.observe',return_value=observation()):service.scheduled(now)
        with agent.store.transaction() as state:
            state['budgets'][agent._sprint(now)]=dict(spent=1000000,reserved=0)
        with patch('sapiens.watch.observe',return_value=observation('new')):service.scheduled(now+timedelta(minutes=1))
        self.assertEqual(self.factory.prompts,[])
        self.assertEqual(service.work.read(agent)[0]['detector']['status'],'budget_blocked')
        with agent.store.transaction() as state:
            state['budgets'][agent._sprint(now)]['spent']=0
        with patch('sapiens.watch.observe',return_value=observation('new')):service.scheduled(now+timedelta(minutes=2))
        self.assertEqual(len(self.factory.prompts),1)

    def test_errors_back_off_without_llm_and_preserve_baseline(self):
        service, agent, row, now = self.setup_watch()
        with patch('sapiens.watch.observe',return_value=observation()):service.scheduled(now)
        with patch('sapiens.watch.observe',side_effect=ValueError('List unavailable')) as probe:
            service.scheduled(now+timedelta(minutes=1))
            service.scheduled(now+timedelta(minutes=2))
            self.assertEqual(probe.call_count,1)
        self.assertEqual(self.factory.prompts,[])
        self.assertTrue(service.work.read(agent)[0]['detector']['baseline'])
        with patch('sapiens.watch.observe',return_value=observation()):service.scheduled(now+timedelta(minutes=3))
        self.assertEqual(service.work.read(agent)[0]['detector']['status'],'unchanged')

    def test_unplanned_legacy_job_gets_one_bounded_setup(self):
        service, agent, row, now = self.setup_watch()
        rows=service.work.read(agent);rows[0].pop('watch');service.work.save(agent,rows)
        with patch('sapiens.watch.observe') as probe:service.scheduled(now)
        probe.assert_not_called()
        self.assertEqual(len(self.factory.prompts),1)
        self.assertEqual(service.work.read(agent)[0]['strategy']['status'],'blocked')
        service.scheduled(now+timedelta(days=2))
        self.assertEqual(len(self.factory.prompts),1)
        for bad in [dict(probe={'command':'bash'}),dict(max_per_hour=0),dict(mode='script'),dict(probe={**PLAN,'names':'Nova'})]:
            with self.assertRaises(APIError):service.work.upsert(agent,dict(id=row['id'],watch=bad))

    def test_plan_change_resets_baseline_but_not_rate_limit(self):
        service, agent, row, now = self.setup_watch()
        rows=service.work.read(agent);rows[0]['detector']={'baseline':{},'wakes':[now.isoformat()]};service.work.save(agent,rows)
        new=service.work.upsert(agent,dict(id=row['id'],watch=dict(probe={**PLAN,'names':['Nova']})))
        self.assertNotIn('baseline',new['detector'])
        self.assertEqual(new['detector']['wakes'],[now.isoformat()])

    def test_extraction_is_scoped_and_fails_closed(self):
        doc=dict(tree=dict(identifier='root',children=[dict(identifier='ChatList',children=[
            dict(role='AXButton',description='Nova, 2 unread messages',value='Hi, 2 minutes ago',selected=True),
            dict(role='AXButton',description='Sage',value='Other'),
            dict(role='AXGroup',description='Unread filter'),
        ]),dict(role='AXStaticText',value='Private opened chat contents')]),truncated=False)
        plan={**PLAN,'names':['Nova']}
        first=watch.extract(doc,plan)
        self.assertEqual(len(first['rows']),1)
        self.assertNotIn('Private',str(first))
        doc['tree']['children'][0]['children'][0].update(value='Hi, 3 minutes ago',selected=False)
        self.assertEqual(first,watch.extract(doc,plan))
        for bad in [{**doc,'truncated':True}, {'tree':{}}, {'tree':{'identifier':'ChatList','children':[]}}]:
            with self.assertRaises(ValueError):watch.extract(bad,plan)
        with self.assertRaises(ValueError):watch.extract(doc,{**PLAN,'names':['Missing']})

    def test_watcher_cannot_request_consolidation(self):
        service, agent, row, now = self.setup_watch()
        run=agent.submit('scheduled','Observe')
        with agent.store.transaction() as state:state['jobs'][-1]['status']='running'
        with self.assertRaises(APIError):service.orchestration.control(agent.agid,dict(op='consolidate'))
        with agent.store.transaction() as state:state['jobs'][-1]['status']='cancelled'
        service.orchestration.control(agent.agid,dict(op='consolidate'))
        self.assertTrue(service.orchestration.settings(agent)['consolidate_requested'])

    def test_failed_review_does_not_acknowledge_or_retry_changes(self):
        service, agent, row, now = self.setup_watch()
        with patch('sapiens.watch.observe',return_value=observation()):service.scheduled(now)
        baseline=service.work.read(agent)[0]['detector']['baseline']
        self.factory.fail=True
        with patch('sapiens.watch.observe',return_value=observation('new')):
            service.scheduled(now+timedelta(minutes=1))
            service.scheduled(now+timedelta(minutes=2))
        saved=service.work.read(agent)[0]
        self.assertEqual(saved['detector']['baseline'],baseline)
        self.assertEqual(len(self.factory.prompts),1)
        self.assertEqual(service.work.health(agent,saved)['status'],'blocked')

    def test_legacy_runs_count_toward_new_limits_and_are_not_model_context(self):
        service, agent, row, now = self.setup_watch()
        rows=service.work.read(agent)
        rows[0].pop('watch')
        rows[0]['runs']=[dict(id='old',started=now.isoformat())]
        service.work.save(agent,rows)
        row=service.work.upsert(agent,dict(id=row['id'],watch=dict(probe=PLAN)))
        self.assertEqual(row['detector']['wakes'],[now.isoformat()])
        row['detector']['baseline']=observation()['rows']
        service.work.save(agent,[row])
        public=service.orchestration.status(agent)['recurring_jobs'][0]
        self.assertNotIn('baseline',public['detector'])
        self.assertNotIn('wakes',public['detector'])
        self.assertNotIn('runs',public)
