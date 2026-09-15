import json
from pathlib import Path
from unittest.mock import patch
from test_integration import IntegrationFixture
from sapiens.service import APIError
from sapiens.runtime import LocalFactory, CodexLLM
from sapiens.recent import RecentContext
from agentpy.interfaces import LLMSpec


class RecentTasksTest(IntegrationFixture):
    def test_delegation_notices_names_links_and_restart(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        nova=service.create_agent({'name':'Nova','role':'Research'})['id']
        result=service.orchestration.control(main,{'op':'task','target':'Nova','title':'Find a funny AI joke'})
        name=result['task_name']
        self.assertRegex(name,r'^[a-z][A-Za-z0-9_.:#+|()&$^\-]*$')
        state=service.snapshot()
        self.assertEqual(state['orchestration'][main]['tasks'],[])
        task=state['orchestration'][nova]['tasks'][0]
        self.assertEqual(task['id'],result['task_id'])
        self.assertEqual(state['task_assignments'][0]['assigned_by'],main)
        self.assertEqual(state['task_assignments'][0]['agent'],nova)
        again=service.orchestration.control(main,{'op':'task','target':nova,'title':'Find a funny AI joke'})
        self.assertNotEqual(name,again['task_name'])
        refs=service.tasks.references('Show @'+name)
        self.assertIn(result['task_id'],refs)
        service.orchestration.control(nova,{'op':'finish_task','id':task['id']})
        service=self.restart(service,start_worker=False)
        self.assertEqual(len(service.snapshot()['task_assignments']),2)
        self.assertIn(result['task_id'],service.tasks.references('Show @'+name))
        self.assertEqual(service.snapshot()['orchestration'][nova]['past_tasks'][0]['name'],name)

    def test_invalid_names_or_targets_never_create_task_or_notice(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        for name in ['Upper','two words','bad/name','x'*25,'1task']:
            with self.assertRaises(APIError):
                service.orchestration.control(main,{'op':'task','title':'Example','name':name})
        with self.assertRaises(APIError):
            service.orchestration.control(main,{'op':'task','title':'Example','target':'Unknown'})
        self.assertEqual(service.snapshot()['task_assignments'],[])
        valid='a-Z_1.:#+|()&$^'
        service.orchestration.control(main,{'op':'task','title':'Example','name':valid})
        with self.assertRaises(APIError):
            service.orchestration.control(main,{'op':'task','title':'Other','name':valid})
        self.assertEqual(len(service.snapshot()['task_assignments']),1)

    def test_existing_tasks_get_stable_names_without_duplicate_notices(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        service._agent(main).add_task('Legacy task')
        service=self.restart(service,start_worker=False)
        first=service.snapshot()['task_assignments']
        service=self.restart(service,start_worker=False)
        self.assertEqual(first,service.snapshot()['task_assignments'])

    def test_recent_tools_survive_fresh_sessions_and_stay_isolated_bounded(self):
        path=Path(self.directory.name)
        factory=LocalFactory(workdir=path,event_sink=lambda e:None)
        prompts=[]
        def complete(llm,prompt):
            prompts.append(prompt)
            llm._consume_event({'type':'item.completed','item':{'type':'command_execution',
                'command':'blindly4 apps','aggregated_output':'Finder, Notes, Safari','exit_code':0}})
            llm._consume_event({'type':'item.completed','item':{'type':'command_execution',
                'command':'large','aggregated_output':'x'*50000,'exit_code':1}})
            return '3 apps'
        with patch.object(CodexLLM,'complete',complete):
            for i in range(7):
                factory.spawn(LLMSpec(role='conversation')).complete('List apps' if i == 0 else 'Show names')
        self.assertIn('Finder, Notes, Safari',prompts[1])
        rows=RecentContext(path).read()
        self.assertEqual(len(rows),5)
        self.assertTrue(rows[0]['observations'][-1]['truncated'])
        self.assertLess(len(json.dumps(rows)),40000)
        self.assertEqual(RecentContext(path/'other-sapi').read(),[])
        with patch.object(CodexLLM,'complete',return_value='memory'):
            factory.spawn(LLMSpec(role='memory_arbiter')).complete('Consolidate')
        self.assertEqual(rows,RecentContext(path).read())

    def test_failed_tool_results_are_marked_not_fabricated_as_success(self):
        path=Path(self.directory.name)
        factory=LocalFactory(workdir=path,event_sink=lambda e:None)
        def fail(llm,prompt):
            llm._consume_event({'type':'item.completed','item':{'type':'command_execution',
                'command':'blindly4 apps','aggregated_output':'Permission denied','exit_code':77}})
            raise TimeoutError('stopped')
        with patch.object(CodexLLM,'complete',fail), self.assertRaises(TimeoutError):
            factory.spawn(LLMSpec(role='conversation')).complete('List')
        row=RecentContext(path).read()[0]
        self.assertEqual(row['error'],'TimeoutError')
        self.assertEqual(row['answer'],'')
        self.assertIn('77',row['observations'][0]['data'])
