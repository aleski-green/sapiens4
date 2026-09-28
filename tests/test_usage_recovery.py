import asyncio
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
from unittest.mock import patch

from test_integration import IntegrationFixture, ScriptedLLM
from sapiens.usage import counters, save_record, settings
from sapiens.runtime import LocalLLM, Config, computer_manifest
from sapiens.computer import bounded_output, main as computer_main
from agentpy.interfaces import LLMSpec


class UsageRecoveryTest(IntegrationFixture):
    def test_rolling_windows_unknown_and_agent_isolation(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        b = service._agent(service.create_agent({'name':'Nova','role':'Assistant'})['id'])
        now = datetime.now(timezone.utc)
        for name, age, owner in [('hour',10,a), ('hour-boundary',3600,a), ('day',3601,a),
                                 ('week',86401,a), ('expired',604801,a), ('other',0,b)]:
            save_record(owner, dict(id=name, time=(now-timedelta(seconds=age)).isoformat(),
                usage={'input_tokens':100, 'cached_input_tokens':80, 'output_tokens':10}))
        save_record(a, dict(id='unknown',time=now.isoformat(),usage=None))
        report = service.usage.report(a,now)
        self.assertEqual(report['windows']['hour']['total'],220)
        self.assertEqual(report['windows']['day']['total'],330)
        self.assertEqual(report['windows']['week']['total'],440)
        self.assertEqual(report['windows']['week']['units'],152)
        self.assertEqual(report['windows']['hour']['unknown'],1)
        self.assertEqual(report['windows']['week']['cached'],320)
        service = self.restart(service,start_worker=False)
        self.assertEqual(service.usage.report(service._agent(a.agid),now)['windows'],report['windows'])

    def test_raw_usage_and_weighted_budget_and_retry_attempts(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        usage = dict(input_tokens=100000,cached_input_tokens=90000,output_tokens=1000,reasoning_output_tokens=100)
        with patch.object(ScriptedLLM,'usage',usage):
            self.factory.fail=True
            turn=service.submit(a.agid,{'text':'Attempt'})['id']
            asyncio.run(a.run())
            self.factory.fail=False
            service.turn_action(a.agid,turn,'retry')
            asyncio.run(a.run())
        report=service.usage.report(a)
        self.assertEqual(report['windows']['hour']['total'],202000)
        self.assertEqual(report['windows']['hour']['units'],40000)
        self.assertEqual(report['budget']['spent'],40000)
        self.assertEqual(a.state['turns'][0]['tokens'],101000)
        self.assertEqual(len(report['recent']),2)
        self.assertEqual(counters(usage)['output'],1000) # reasoning is not added again

    def test_legacy_budget_discount_is_idempotent(self):
        service=self.service(start_worker=False)
        a=service._agent(service.hierarchy.main)
        turn=service.submit(a.agid,{'text':'Before upgrade'})['id']
        asyncio.run(a.run())
        with a.store.transaction() as state:
            state.pop('budget_policy')
            state['turns'][0]['tokens']=1047343
            state['budgets'][a._sprint(datetime.now(timezone.utc))]['spent']=1047343
        archive=a.corpora.root/'archive'/a.agid/'runs'/f'{turn}.json'
        data=json.loads(archive.read_text())
        data['logs'][0]['usage']=dict(input_tokens=1044280,cached_input_tokens=978560,output_tokens=3063)
        archive.write_text(json.dumps(data))
        for _ in range(2):
            service=self.restart(service,start_worker=False)
            self.assertEqual(service._agent(a.agid).budget_status()['spent'],166639)


    def test_output_bound_and_tool_step_stop(self):
        output=bounded_output('x'*20000,800)
        self.assertTrue(json.loads(output)['truncated'])
        self.assertLess(len(output),1100)
        tree=json.dumps({'tree':{'pid':7,'role':'AXApplication','children':[
            {'role':'AXGroup','position':'0,0','children':[{'role':'AXButton','title':'Open'}]},
            {'role':'AXText','value':'Sync paused'}]},'truncated':False},indent=2)
        compact=json.loads(bounded_output(tree,800))
        self.assertEqual(compact['nodes'][2]['path'],'0.0')
        self.assertEqual(compact['nodes'][3]['path'],'1')
        self.assertEqual(compact['nodes'][3]['value'],'Sync paused')
        self.assertFalse(compact['truncated'])
        self.assertNotIn('position',compact['nodes'][1])
        llm=LocalLLM(spec=LLMSpec(role='conversation'),workdir=Path(self.directory.name),event_sink=lambda _:None)
        llm.max_tools=2
        events=[{'type':'item.completed','item':{'id':str(i),'type':'command_execution','command':'apps','aggregated_output':'[]'}} for i in range(3)]
        def fake_complete(instance,prompt):
            for event in events:instance._consume_event(event)
            return 'Should not finish'
        with patch('sapiens.runtime.CodexLLM.complete',fake_complete):
            with self.assertRaisesRegex(RuntimeError,'Tool-step limit'):
                llm.complete('Inspect apps')
        self.assertEqual(llm.tool_count,2)
        self.assertEqual(llm.repeated_tools,1)
        self.assertIn('computer.py',computer_manifest(Path('/fake/blindly4')))

    def test_settings_validation_does_not_mutate_identity(self):
        service=self.service(start_worker=False)
        a=service._agent(service.hierarchy.main)
        from sapiens.service import APIError
        with self.assertRaises(APIError):
            service.update_agent(a.agid,dict(name='Changed',role='Role',execution={**settings(a),'max_tools':0}))
        self.assertEqual(service.store.agents()[0]['name'],'SapiTheMain')
        service.update_agent(a.agid,dict(name='Sapi',role='Role',execution={**settings(a),'max_tools':8}))
        service=self.restart(service,start_worker=False)
        self.assertEqual(settings(service._agent(a.agid))['max_tools'],8)
