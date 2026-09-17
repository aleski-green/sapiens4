import asyncio
from http.client import HTTPConnection
import json
from pathlib import Path
import threading
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.server import Server
from sapiens.service import APIError
from sapiens.runtime import LocalLLM
from agentpy.interfaces import LLMSpec


class WorkspaceTest(IntegrationFixture):
    def test_artifact_and_tabs_survive_restart_and_stale_browser(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        original = dict(workspaces={a.agid:dict(tabs=[dict(id='human',type='blank',title='Notes')],activeTab='human')})
        saved = service.save_preferences(original)['preferences']
        control = service.orchestration.control
        receipt = control(a.agid, dict(op='artifact_save',name='cip.md',content='# CIP\n<script>unsafe</script>'))
        artifact = receipt['artifact']
        tab_id = artifact['tab']['id']
        self.assertTrue(Path(artifact['path']).is_file())
        self.assertEqual(control(a.agid,dict(op='artifact_read',name='cip.md'))['content'], '# CIP\n<script>unsafe</script>')
        with self.assertRaisesRegex(APIError, 'Workspace changed'):
            service.save_preferences(saved)
        tabs = service.store.read_preferences()['workspaces'][a.agid]['tabs']
        self.assertEqual([t['id'] for t in tabs], ['human', tab_id])
        self.assertIn('&lt;script&gt;', tabs[-1]['html'])
        self.assertNotIn('<script>unsafe', tabs[-1]['html'])
        control(a.agid,dict(op='artifact_save',name='cip.md',content='# Revised CIP'))
        self.assertEqual(len(control(a.agid,dict(op='workspace'))['tabs']),2)
        self.assertEqual(control(a.agid,dict(op='workspace'))['active_tab'],tab_id)
        service = self.restart(service, start_worker=False)
        service.orchestration.prepare(service._agent(a.agid))
        facts = json.loads(service._agent(a.agid).manifests['host-facts'])
        self.assertEqual(facts['workspace']['artifacts'][0]['name'],'cip.md')
        self.assertEqual(facts['workspace']['active_tab'],tab_id)
        service.orchestration.control(a.agid,dict(op='workspace_close',id=tab_id))
        self.assertEqual(service.workspace.summary(service._agent(a.agid))['active_tab'],'human')
        self.assertTrue(Path(artifact['path']).exists())

    def test_artifact_source_isolation_and_dashboard_update(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        b = service._agent(service.create_agent(dict(name='Nova',role='Researcher'))['id'])
        control = service.orchestration.control
        (service.workspace.root(a)/'draft.html').write_text('<h1>Dashboard</h1><script>document.title="Ready"</script>')
        first = control(a.agid,dict(op='artifact_save',name='dashboard.html',path='draft.html'))['artifact']
        self.assertIn("default-src 'none'",service.store.read_preferences()['workspaces'][a.agid]['tabs'][0]['html'])
        self.assertEqual(service.workspace.summary(b)['tabs'],[])
        for data in [dict(name='../escape.md',content='bad'), dict(name='ok.md',path='../secret'),
                     dict(name='ok.md',path=str(Path('/etc/passwd'))), dict(name='ok.md',content='x',open='yes')]:
            with self.assertRaises(APIError):control(a.agid,dict(op='artifact_save',**data))
        (service.workspace.root(a)/'outside').symlink_to('/etc/passwd')
        with self.assertRaises(APIError):control(a.agid,dict(op='artifact_save',name='ok.md',path='outside'))
        with self.assertRaises(APIError):control(b.agid,dict(op='artifact_read',name='dashboard.html'))
        with self.assertRaises(APIError):control(a.agid,dict(op='workspace_open',url='javascript:alert(1)'))
        control(a.agid,dict(op='artifact_save',name='dashboard.html',content='<h1>Updated</h1>',open=False))
        tab = service.store.read_preferences()['workspaces'][a.agid]['tabs'][0]
        self.assertEqual(tab['id'],first['tab']['id'])
        self.assertIn('Updated',tab['html'])
        self.assertNotIn('Dashboard',tab['html'])

    def test_artifact_http_serves_text_not_executable_html(self):
        service = self.service(start_worker=False)
        server = Server(0,service)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        a = service._agent(service.hierarchy.main)
        self.assertIn('artifact_save',a.manifests['host-control'])
        artifact = service.orchestration.control(a.agid,dict(op='artifact_save',name='dashboard.html',content='<script>alert(1)</script>'))['artifact']
        conn = HTTPConnection('127.0.0.1',server.server_port)
        conn.request('GET',artifact['url'])
        response = conn.getresponse()
        self.assertEqual(response.status,200)
        self.assertEqual(response.getheader('Content-Type'),'text/plain; charset=utf-8')
        self.assertEqual(response.getheader('X-Content-Type-Options'),'nosniff')
        self.assertIn(b'<script>',response.read())
        conn.close()

    def test_new_chat_after_failure_does_not_retry_failed_run(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        self.factory.fail = True
        first = service.submit(a.agid,dict(text='Create a document'))['id']
        asyncio.run(a.run())
        self.factory.fail = False
        second = service.submit(a.agid,dict(text='Use the saved file'))['id']
        asyncio.run(a.run())
        jobs = {j['id']:j for j in a.state['jobs']}
        self.assertEqual(jobs[first]['status'],'failed')
        self.assertEqual(jobs[second]['status'],'done')
        self.assertEqual(len(self.factory.prompts),2)

    def test_tool_stop_retains_last_observation_and_saved_artifact(self):
        root = Path(self.directory.name)
        (root/'artifacts').mkdir()
        llm = LocalLLM(spec=LLMSpec(role='conversation'),workdir=root,event_sink=lambda _:None)
        llm.max_tools = 1
        def run(instance, prompt):
            (root/'artifacts'/'cip.md').write_text('# Saved CIP')
            instance._consume_event(dict(type='item.completed',item=dict(id='1',type='command_execution',command='save CIP',aggregated_output='saved',exit_code=0)))
        with patch('sapiens.runtime.CodexLLM.complete',run):
            answer = llm.complete('Write a proposal')
            self.assertIn('Warning', answer)
            self.assertIn('cip.md', answer)
            self.assertIn('not fully verified', llm.warning)
        retained = json.loads((root/'recent-context.json').read_text())[-1]
        self.assertIn('saved',retained['observations'][-1]['data'])
