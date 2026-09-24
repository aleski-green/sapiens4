from datetime import datetime, timedelta, timezone
from pathlib import Path
import json
from test_integration import IntegrationFixture
from sapiens.recent import RecentContext
from sapiens.service import APIError


class TaskDeadlineTest(IntegrationFixture):
    def test_due_tasks_run_independently_of_paused_checks_and_only_once(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        agent=service._agent(main)
        service.orchestration.control(main,{'op':'schedule','enabled':False})
        due=datetime.now(timezone.utc)+timedelta(seconds=30)
        task=service.orchestration.control(main,{'op':'task','title':'Return a joke','due':due.isoformat()})['task_id']
        service.scheduled(due-timedelta(seconds=1))
        self.assertEqual(service.snapshot()['jobs'],[])
        service.scheduled(due)
        detail=service.tasks.detail(main,task)
        self.assertEqual(detail['run']['status'],'done')
        self.assertEqual(len(self.factory.prompts),1)
        self.assertEqual([r['kind'] for r in detail['activity']],['running','done'])
        self.assertIn('Connected through AgentPy.',detail['activity'][-1]['text'])
        updates=service.snapshot()['task_updates']
        self.assertEqual(len(updates),2)
        service=self.restart(service,start_worker=False)
        service.scheduled(due+timedelta(hours=1))
        self.assertEqual(len(self.factory.prompts),1)
        self.assertEqual(service.snapshot()['task_updates'],updates)

    def test_due_task_waits_for_busy_or_failed_work_without_duplicate_retry(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        due=datetime.now(timezone.utc)
        tid=service.orchestration.control(main,{'op':'task','title':'Inspect','due':due.isoformat()})['task_id']
        queued=service.submit(main,{'text':'Another request'})
        service.scheduled(due)
        self.assertNotIn('job',service._agent(main).state['tasks'][0])
        service.job_action(main,queued['id'],'cancel')
        self.factory.fail=True
        service.scheduled(due)
        self.assertEqual(service.tasks.detail(main,tid)['run']['status'],'failed')
        service.scheduled(due+timedelta(days=1))
        self.assertEqual(len(self.factory.prompts),1)

    def test_task_comments_results_and_logs_survive_completion(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        task=service.orchestration.control(main,{'op':'task','title':'One-off'})['task_id']
        service.tasks.comment(service._agent(main),task,'Please keep it short.')
        service.orchestration.control(main,{'op':'task_comment','id':task,'text':'Working on it.'})
        service.work.admit_task(service._agent(main),task)
        import asyncio
        asyncio.run(service._agent(main).run())
        service.work.finish_task(service._agent(main),task)
        service=self.restart(service,start_worker=False)
        detail=service.tasks.detail(main,task)
        self.assertTrue(detail['task']['past'])
        self.assertEqual(detail['run']['status'],'done')
        self.assertEqual([r['author'] for r in detail['activity'] if r['kind']=='comment'],['Human',main])
        self.assertTrue(any(r['kind']=='done' for r in detail['activity']))
        self.assertTrue(any(r['kind']=='completed' for r in detail['activity']))
        self.assertTrue(detail['events'])
        with self.assertRaises(APIError):
            service.tasks.comment(service._agent(main),'missing','Comment')

    def test_memory_freshness_boundary_explicit_refresh_and_settings(self):
        memory=RecentContext(Path(self.directory.name))
        now=datetime.now(timezone.utc)
        record=dict(session='one',time=now.isoformat(),observations=[dict(time=now.isoformat(),data='UNIQUE-APP-LIST',truncated=False)],answer='3 apps',error=None)
        memory.path.write_text(json.dumps([record]))
        self.assertIn('UNIQUE-APP-LIST',memory.context('show the list',now+timedelta(seconds=90)))
        self.assertNotIn('UNIQUE-APP-LIST',memory.context('show the list',now+timedelta(seconds=91)))
        for request in ['do it again','check current state','refresh the list','run that again']:
            self.assertNotIn('UNIQUE-APP-LIST',memory.context(request,now+timedelta(seconds=1)))
        self.assertIn('UNIQUE-APP-LIST',memory.context('Show those entries; do not check again.',now))
        memory.configure({'enabled':True,'seconds':30})
        self.assertNotIn('UNIQUE-APP-LIST',memory.context('show the list',now+timedelta(seconds=31)))
        memory.configure({'enabled':False,'seconds':90})
        self.assertNotIn('UNIQUE-APP-LIST',memory.context('show the list',now))

    def test_per_sapi_memory_settings_persist_and_validate_before_other_changes(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        nova=service.create_agent({'name':'Nova','role':'Research'})['id']
        self.assertEqual(service.snapshot()['orchestration'][main]['recent'],{'enabled':True,'seconds':90})
        for bad in [dict(enabled=True,seconds=0),dict(enabled='yes',seconds=90),dict(enabled=True,seconds=True)]:
            with self.assertRaises(APIError):
                service.update_agent(main,{'name':'Changed','role':'Main','recent':bad})
        self.assertEqual(service.store.agents()[0]['name'],'SapiTheMain')
        service.update_agent(main,{'name':'Sapi','role':'Main','recent':{'enabled':True,'seconds':45}})
        service=self.restart(service,start_worker=False)
        info=service.snapshot()['orchestration']
        self.assertEqual(info[main]['recent']['seconds'],45)
        self.assertEqual(info[nova]['recent']['seconds'],90)
