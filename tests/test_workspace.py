import asyncio
import json
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading
import unittest

from test_integration import IntegrationFixture
from sapiens.validation import APIError
from sapiens.server import Server


class WorkspaceTest(IntegrationFixture):
    def test_files_tabs_bookmarks_and_zoom_survive_restart(self):
        service = self.service(start_worker=False)
        owner = service.hierarchy.main
        agent = service._agent(owner)
        file = service.workspace.root(agent) / 'notes with spaces.md'
        file.write_text('# Notes\n<script>literal</script>')
        control = lambda op, **fields: service.orchestration.control(owner, dict(op=op, **fields))
        ws = control('workspace_open', path=file.name)['workspace']
        tab = ws['tabs'][0]
        self.assertEqual(tab['path'], str(file))
        self.assertEqual(tab['url'], file.as_uri())
        self.assertNotIn('html', tab)
        control('workspace_zoom', factor=1.5)
        control('workspace_bookmark')
        control('workspace_bookmark')
        self.assertEqual(len(control('workspace')['bookmarks']), 1)
        control('workspace_open', url='https://example.com')
        control('workspace_focus', id=tab['id'])
        control('workspace_reload')
        self.assertEqual(control('workspace')['tabs'][0]['command']['action'], 'reload')
        service = self.restart(service, start_worker=False)
        ws = service.workspace.summary(service._agent(owner))
        self.assertEqual(ws['active_tab'], tab['id'])
        self.assertEqual(ws['tabs'][0]['zoom'], 1.5)
        self.assertEqual(ws['bookmarks'][0]['path'], str(file))
        service.orchestration.control(owner, dict(op='workspace_close', id=tab['id']))
        self.assertEqual(file.read_text(), '# Notes\n<script>literal</script>')
        self.assertEqual(len(service.workspace.summary(service._agent(owner))['tabs']), 1)

    def test_live_navigation_and_stale_reports(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        control = lambda op, **fields: service.orchestration.control(agent.agid, dict(op=op, **fields))
        tab = control('workspace_open', url='https://example.com')['workspace']['tabs'][0]
        report = dict(id=tab['id'], seq=tab['command']['seq'], url='https://example.com/redirected', title='Actual page title', can_back=True)
        self.assertTrue(service.workspace.observed(agent, report)['saved'])
        current = control('workspace')['tabs'][0]
        self.assertEqual(current['url'], report['url'])
        self.assertEqual(current['title'], report['title'])
        control('workspace_open', id=tab['id'], url='https://example.org')
        self.assertFalse(service.workspace.observed(agent, report)['saved'])
        self.assertEqual(control('workspace')['tabs'][0]['url'], 'https://example.org')
        control('workspace_close', id=tab['id'])
        self.assertFalse(service.workspace.observed(agent, report)['saved'])
        self.assertEqual(control('workspace')['tabs'], [])

    def test_legacy_documents_become_files_without_data_loss(self):
        service = self.service(start_worker=False)
        owner = service.hierarchy.main
        file = service.workspace.root(service._agent(owner)) / 'artifacts' / 'old.md'
        file.parent.mkdir(); file.write_text('Saved work')
        prefs = service.store.read_preferences()
        prefs.pop('browser_version')
        prefs['workspaces'] = {owner: dict(activeTab='old', tabs=[
            dict(id='old', title='Old notes', type='html', artifact='old.md', html='Cached preview'),
            dict(id='inline', title='Inline', type='html', html='<h1>Keep me</h1>')])}
        service.store.preferences(prefs)
        service = self.restart(service, start_worker=False)
        tabs = service.workspace.summary(service._agent(owner))['tabs']
        self.assertEqual(tabs[0]['path'], str(file))
        self.assertEqual(file.read_text(), 'Saved work')
        self.assertEqual(Path(tabs[1]['path']).read_text(), '<h1>Keep me</h1>')
        self.assertTrue(all('html' not in t and 'artifact' not in t for t in tabs))
        service = self.restart(service, start_worker=False)
        self.assertEqual(service.workspace.summary(service._agent(owner))['tabs'], tabs)

    def test_validation_and_independent_owners(self):
        service = self.service(start_worker=False)
        a = service.hierarchy.main
        b = service.create_agent(dict(name='Nova', role='Researcher'))['id']
        control = service.orchestration.control
        tab = control(a, dict(op='workspace_open', url='https://example.com'))['workspace']['tabs'][0]
        self.assertEqual(control(b, dict(op='workspace'))['tabs'], [])
        for data in [dict(op='workspace_open',url='javascript:alert(1)'),
                     dict(op='workspace_open',url='https://user:pass@example.com'),
                     dict(op='workspace_open',path='missing.md'),
                     dict(op='workspace_open',url='https://example.com',path='a.md'),
                     dict(op='workspace_zoom',factor=0),dict(op='workspace_zoom',factor=True),
                     dict(op='workspace_zoom',factor=float('nan')),
                     dict(op='artifact_save',name='old.md',content='removed')]:
            with self.assertRaises(APIError): control(a,data)
        with self.assertRaises(APIError): control(b,dict(op='workspace_close',id=tab['id']))
        # General UI preference saves cannot replace browser state.
        with self.assertRaises(APIError): service.save_preferences({'workspaces':{}})
        service.save_preferences({'drafts':{a:'Typing'}})
        self.assertEqual(control(a,dict(op='workspace'))['tabs'][0]['id'],tab['id'])

    @unittest.skipUnless(sys.platform == 'darwin', 'Native browser requires macOS')
    def test_native_browser_and_app_bridge(self):
        class Page(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/one')
                    self.end_headers()
                    return
                if self.path == '/text':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'Plain text on the web')
                    return
                title = 'First page' if self.path == '/one' else 'Second page'
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.send_header('X-Frame-Options', 'DENY')
                self.send_header('Content-Security-Policy', "frame-ancestors 'none'")
                self.end_headers()
                self.wfile.write(f'<title>{title}</title><h1>Not embeddable</h1>'.encode())

        service = self.service(start_worker=False)
        owner = service.hierarchy.main
        file = service.workspace.root(service._agent(owner)) / 'integration.md'
        file.write_text('Native browser integration')
        service.orchestration.control(owner, dict(op='workspace_open', path=str(file)))
        server = Server(0, service)
        pages = ThreadingHTTPServer(('127.0.0.1', 0), Page)
        for host in (server, pages):
            threading.Thread(target=host.serve_forever, daemon=True).start()
            self.addCleanup(host.server_close)
            self.addCleanup(host.shutdown)
        root = Path(__file__).resolve().parents[1]
        binary = str(Path(self.directory.name) / 'browser-tests')
        subprocess.run(['xcrun', 'swiftc', '-framework', 'Cocoa', '-framework', 'WebKit',
                        str(root / 'macos/Browser.swift'), str(root / 'macos/BrowserTests.swift'),
                        '-o', binary], check=True, capture_output=True, timeout=90)
        result = subprocess.run([binary, f'http://127.0.0.1:{server.server_port}',
                                 f'http://127.0.0.1:{pages.server_port}'],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = service.workspace.summary(service._agent(owner))
        self.assertEqual(state['tabs'], [])
        self.assertEqual(state['bookmarks'][0]['path'], str(file))
        self.assertEqual(self.factory.prompts, [])

    def test_new_chat_after_failure_does_not_retry_failed_run(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        self.factory.fail = True
        first = service.submit(a.agid,dict(text='Create a document'))['id']
        asyncio.run(a.run())
        self.factory.fail = False
        second = service.submit(a.agid,dict(text='Use the saved file'))['id']
        asyncio.run(a.run())
        turns = {j['id']:j for j in a.state['turns']}
        self.assertEqual(turns[first]['status'],'failed')
        self.assertEqual(turns[second]['status'],'done')
        self.assertEqual(len(self.factory.prompts),2)
