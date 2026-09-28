import json
from pathlib import Path
from unittest.mock import patch
from test_integration import IntegrationFixture
from sapiens.service import APIError
from sapiens.runtime import LocalFactory, CodexLLM
from sapiens.recent import RecentContext
from agentpy.interfaces import LLMSpec


class RecentTasksTest(IntegrationFixture):


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
