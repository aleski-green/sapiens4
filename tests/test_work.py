from datetime import datetime, timedelta, timezone
from unittest.mock import patch
import asyncio

from test_integration import IntegrationFixture
from sapiens.service import APIError


class WorkTest(IntegrationFixture):
    def test_reviewed_strategy_supersedes_old_blocker_without_erasing_checkpoint(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        row = service.work.upsert(agent, dict(title='Generation', prompt='Generate report', minutes=360,
                                             watch={'mode':'always'}))
        self.ready_strategy(service, agent, row)
        service.work.checkpoint(agent, dict(id=row['id'], status='blocked', outcome='blocked',
                                           summary='Old instruction conflict'))
        row = service.work.read(agent)[0]
        self.assertEqual(service.work.health(agent, row)['status'], 'blocked')
        self.ready_strategy(service, agent, row)
        row = service.work.read(agent)[0]
        self.assertEqual(service.work.health(agent, row)['status'], 'scheduled')
        self.assertEqual(row['checkpoint']['status'], 'blocked')
        service.work.checkpoint(agent, dict(id=row['id'], status='blocked', outcome='blocked',
                                           summary='New access blocker'))
        self.assertEqual(service.work.health(agent, service.work.read(agent)[0])['reason'], 'New access blocker')

    def test_recurring_prompt_respects_mode_and_scoped_authorization(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        for mode, goal in [('always', 'Send one joke to the Admin-authorized Telegram recipient every six hours.'),
                           ('changes', 'Observe changed messages and report; do not send replies.')]:
            with self.subTest(mode=mode):
                definition = service.work.upsert(agent, dict(title='Mode test', prompt=goal,
                    minutes=360, watch={'mode': mode}))
                with patch.object(agent, 'submit', return_value='test-'+mode) as submit:
                    service.work.admit(agent, definition, datetime.now(timezone.utc), manual=True)
                prompt = submit.call_args.args[1]
                self.assertTrue(prompt.startswith(goal))
                self.assertIn('only when explicitly authorized by Admin in the saved job goal', prompt)
                self.assertIn('Observation-only goals remain observation-only', prompt)
                self.assertNotIn('Observe only; this job does not grant permission', prompt)
                if mode == 'always':
                    self.assertIn('even when detector output is empty', prompt)
                    self.assertNotIn('Investigate only changed items', prompt)
                else:
                    self.assertIn('Investigate only changed items', prompt)
                    self.assertNotIn('even when detector output is empty', prompt)

    def test_main_and_default_parent_are_enforced_after_restart(self):
        service = self.service(start_worker=False)
        main = service.hierarchy.main
        child = service.create_agent({'name':'Nova','role':'Research'})['id']
        grandchild = service.create_agent({'name':'Sage','role':'Assistant','manager':child})['id']
        self.assertEqual(service.snapshot()['orchestration'][child]['manager'], main)
        self.assertEqual(service.snapshot()['orchestration'][grandchild]['manager'], child)
        for target, manager in [(main,child),(main,grandchild),(child,grandchild),(child,child)]:
            with self.assertRaises(APIError):
                service.orchestration.control(target, {'op':'manager','manager':manager})
        with self.assertRaises(APIError):
            service.update_agent(main, {'name':'Sapi','role':'Main','manager':child})
        # Emulate old disconnected roots and an old manager above main.
        agent = service._agent(main)
        agent.corpora.register(child,parent=None)
        agent.corpora.register(main,parent=child)
        service = self.restart(service,start_worker=False)
        info = service.snapshot()['orchestration']
        self.assertIsNone(info[main]['manager'])
        self.assertEqual(info[child]['manager'],main)
        self.assertEqual(info[grandchild]['manager'],child)
        service.orchestration.control(grandchild,{'op':'manager','manager':None})
        self.assertEqual(service.snapshot()['orchestration'][grandchild]['manager'],main)

    def test_recurring_timer_deduplication_pause_and_restart(self):
        service = self.service(start_worker=False)
        agid = service.hierarchy.main
        agent = service._agent(agid)
        service.orchestration.control(agid, {'op':'schedule','enabled':False})
        definition = service.orchestration.control(agid, {'op':'recurring_job','title':'Progress report',
                    'prompt':'Summarize current progress','minutes':5,'watch':{'mode':'always','cooldown_minutes':1}})['recurring_job']
        self.ready_strategy(service, agent, definition)
        deadline = datetime.fromisoformat(definition['next_run'])
        service.scheduled(deadline-timedelta(seconds=1))
        self.assertEqual(self.factory.prompts, [])
        service.scheduled(deadline)
        first = service.snapshot()['orchestration'][agid]['recurring'][0]
        self.assertEqual(first['runs'][0]['status'],'done')
        self.assertEqual(first['runs'][0]['output'],'Connected through AgentPy.')
        self.assertEqual(first['next_run'],(deadline+timedelta(minutes=5)).isoformat())
        self.assertEqual(service._agent(agid).state['tasks'],[])
        service.scheduled(deadline)
        self.assertEqual(len(self.factory.prompts),1)
        service = self.restart(service,start_worker=False)
        service.scheduled(deadline+timedelta(hours=2))
        self.assertEqual(len(self.factory.prompts),2)  # A single catch-up run.
        service.orchestration.control(agid,{'op':'recurring_job','id':definition['id'],'enabled':False})
        service.scheduled(deadline+timedelta(days=2))
        self.assertEqual(len(self.factory.prompts),2)
        service.orchestration.control(agid,{'op':'recurring_job','id':definition['id'],'enabled':True})
        row = service.work.read(service._agent(agid))[0]
        self.assertIsNotNone(row['next_run'])
        self.assertEqual(len(row['runs']),2)

    def test_run_now_keeps_timer_and_failed_runs_require_review(self):
        self.factory.fail=True
        service = self.service()
        agid = service.hierarchy.main
        control = service.orchestration.control
        definition = control(agid,{'op':'recurring_job','title':'Check','prompt':'Inspect','minutes':60})['recurring_job']
        run = control(agid,{'op':'run_job','id':definition['id']})['run_id']
        self.wait_job(service,run,'failed')
        self.assertEqual(service.work.read(service._agent(agid))[0]['next_run'],definition['next_run'])
        service.scheduled(datetime.now(timezone.utc)+timedelta(days=1))
        self.assertEqual(len(self.factory.prompts),1)
        self.factory.fail=False
        service.job_action(agid,run,'retry')
        self.wait_job(service,run)
        self.assertEqual(len(service.snapshot()['orchestration'][agid]['recurring'][0]['runs']),1)

    def test_tasks_run_once_and_move_to_past(self):
        service = self.service()
        agid = service.hierarchy.main
        control = service.orchestration.control
        task = control(agid,{'op':'task','title':'Investigate a one-off issue'})['task_id']
        run = control(agid,{'op':'run_task','id':task})['run_id']
        self.wait_job(service,run)
        with self.assertRaises(APIError):
            control(agid,{'op':'run_task','id':task})
        control(agid,{'op':'finish_task','id':task})
        service = self.restart(service,start_worker=False)
        info = service.snapshot()['orchestration'][agid]
        self.assertEqual(info['tasks'],[])
        self.assertEqual(info['past_tasks'][0]['id'],task)
        self.assertEqual(info['past_tasks'][0]['job'],run)
        self.assertEqual(info['recurring'],[])

    def test_schedule_validation_cannot_overwrite_history(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        for bad in [dict(minutes=0),dict(minutes=True),dict(enabled='yes'),dict(runs=[]),dict(id='missing')]:
            with self.assertRaises(APIError):
                service.work.upsert(agent, {'title':'Check','prompt':'Inspect','minutes':10,**bad})
        self.assertEqual(service.work.read(agent),[])

    def test_enqueue_recovery_uses_the_same_scheduled_run(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        definition = service.work.upsert(agent,{'title':'Check','prompt':'Inspect','minutes':5})
        deadline = datetime.fromisoformat(definition['next_run'])
        with patch.object(service.work,'save',side_effect=OSError('Simulated write failure')):
            with self.assertRaises(OSError):
                service.work.admit(agent,definition,deadline)
        self.assertEqual(len(agent.state['jobs']),1)
        service.work.admit(agent,definition,deadline)
        self.assertEqual(len(agent.state['jobs']),1)
        asyncio.run(agent.run())
        self.assertEqual(len(self.factory.prompts),1)
        self.assertEqual(len(service.work.read(agent)[0]['runs']),1)
