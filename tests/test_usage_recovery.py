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
            job=service.submit(a.agid,{'text':'Attempt'})['id']
            asyncio.run(a.run())
            self.factory.fail=False
            service.job_action(a.agid,job,'retry')
            asyncio.run(a.run())
        report=service.usage.report(a)
        self.assertEqual(report['windows']['hour']['total'],202000)
        self.assertEqual(report['windows']['hour']['units'],40000)
        self.assertEqual(report['budget']['spent'],40000)
        self.assertEqual(a.state['jobs'][0]['tokens'],101000)
        self.assertEqual(len(report['recent']),2)
        self.assertEqual(counters(usage)['output'],1000) # reasoning is not added again

    def test_legacy_budget_discount_is_idempotent(self):
        service=self.service(start_worker=False)
        a=service._agent(service.hierarchy.main)
        job=service.submit(a.agid,{'text':'Before upgrade'})['id']
        asyncio.run(a.run())
        with a.store.transaction() as state:
            state.pop('budget_policy')
            state['jobs'][0]['tokens']=1047343
            state['budgets'][a._sprint(datetime.now(timezone.utc))]['spent']=1047343
        archive=a.corpora.root/'archive'/a.agid/'runs'/f'{job}.json'
        data=json.loads(archive.read_text())
        data['logs'][0]['usage']=dict(input_tokens=1044280,cached_input_tokens=978560,output_tokens=3063)
        archive.write_text(json.dumps(data))
        for _ in range(2):
            service=self.restart(service,start_worker=False)
            self.assertEqual(service._agent(a.agid).budget_status()['spent'],166639)

    def test_failed_learning_does_not_block_chat_or_watcher(self):
        service=self.service(start_worker=False)
        a=service._agent(service.hierarchy.main)
        service.orchestration.control(a.agid,{'op':'schedule','enabled':False})
        self.factory.fail=True
        learning=a.submit('learning')
        asyncio.run(a.run())
        self.factory.fail=False
        chat=service.submit(a.agid,{'text':'Still here?'})['id']
        asyncio.run(a.run())
        self.assertEqual(next(j['status'] for j in a.state['jobs'] if j['id']==chat),'done')
        watcher=service.work.upsert(a,dict(title='Watch',prompt='Observe',minutes=1,watch={'mode':'always','cooldown_minutes':1}))
        self.ready_strategy(service, a, watcher)
        service.scheduled(datetime.fromisoformat(watcher['next_run']))
        self.assertEqual(service.work.read(a)[0]['last_observation']['status'],'done')
        self.assertEqual(next(j['status'] for j in a.state['jobs'] if j['id']==learning),'failed')

    def test_budget_resets_resume_never_started_work_only(self):
        service=self.service(start_worker=False)
        a=service._agent(service.hierarchy.main)
        job=a.submit('chat','Not yet run')
        with a.store.transaction() as state:
            state['budgets'][a._sprint(datetime.now(timezone.utc))]=dict(spent=1000000,reserved=0)
        asyncio.run(a.run())
        self.assertEqual(a.state['jobs'][0]['status'],'budget_blocked')
        self.assertEqual(len(self.factory.prompts),0)
        service.scheduled()
        self.assertEqual(a.state['jobs'][0]['status'],'budget_blocked')
        future=datetime.now(timezone.utc)+timedelta(days=8)
        service.scheduled(future)
        self.assertEqual(a.state['jobs'][0]['status'],'queued')
        with patch('agentpy.runtime.utcnow',return_value=future):
            asyncio.run(a.run())
        self.assertEqual(a.state['jobs'][0]['status'],'done')
        self.assertEqual(len(self.factory.prompts),1)

    def test_team_visibility_alert_dedup_recovery_and_checkpoint(self):
        service=self.service(start_worker=False)
        main=service.hierarchy.main
        a=service._agent(service.create_agent({'name':'Nova','role':'Watcher'})['id'])
        row=service.work.upsert(a,dict(title='DM watcher',prompt='Inspect DMs',minutes=10,watch={'mode':'always'}))
        self.ready_strategy(service, a, row)
        service.orchestration.control(a.agid,dict(op='checkpoint',id=row['id'],status='blocked',summary='Sync paused',value={'coverage':'none'}))
        for _ in range(2):service.work.monitor(a,datetime.now(timezone.utc))
        self.assertEqual(len(service.work.notifications()),1)
        self.assertIn(main,service.work.notifications()[0]['owners'])
        team=service.orchestration.status(service._agent(main))
        self.assertEqual(team['recurring_jobs'],[])
        member=next(r for r in team['team'] if r['id']==a.agid)
        self.assertEqual(member['recurring_jobs'][0]['health']['reason'],'Sync paused')
        targeted=service.orchestration.control(main,dict(op='status',target='Nova'))
        self.assertEqual(targeted['self_id'],a.agid)
        self.assertEqual(targeted['recurring_jobs'][0]['id'],row['id'])
        receipt=service.orchestration.control(a.agid,dict(op='schedule',enabled=False))
        self.assertTrue(receipt['saved'])
        self.assertNotIn('team',receipt) # writes do not dump team history into every tool result
        service=self.restart(service,start_worker=False)
        a=service._agent(a.agid)
        service.work.monitor(a,datetime.now(timezone.utc))
        self.assertEqual(len(service.work.notifications()),1)
        service.orchestration.control(a.agid,dict(op='checkpoint',id=row['id'],status='ok',summary='Checked',value={'last_seen':'message-1'}))
        service.work.monitor(a,datetime.now(timezone.utc))
        self.assertEqual(len(service.work.notifications()),2)
        current=service.work.read(a)[0]
        run=service.work.admit(a,current,datetime.now(timezone.utc),manual=True)
        asyncio.run(a.run())
        self.assertIn('message-1',self.factory.prompts[-1])
        self.assertIn(row['id'],self.factory.prompts[-1])

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
        self.assertEqual(service.store.agents()[0]['name'],'Sapi')
        service.update_agent(a.agid,dict(name='Sapi',role='Role',execution={**settings(a),'max_tools':8}))
        service=self.restart(service,start_worker=False)
        self.assertEqual(settings(service._agent(a.agid))['max_tools'],8)
