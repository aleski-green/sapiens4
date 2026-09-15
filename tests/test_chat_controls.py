import base64
import json
from http.client import HTTPConnection
import threading
from pathlib import Path

from test_integration import IntegrationFixture
from sapiens.attachments import create_attachment
from sapiens.server import Server
from sapiens.service import APIError


class ChatControlsTest(IntegrationFixture):
    def test_names_and_distinct_avatars_persist(self):
        service = self.service(start_worker=False)
        a = service.store.agents()[0]
        for invalid in ['nova', 'Nova Test', 'Nova@', 'Éclair', 'A/b', 'A💡', '1Nova']:
            with self.assertRaises(APIError):
                service.create_agent({'name': invalid, 'role': 'Tester'})
            with self.assertRaises(APIError):
                service.update_agent(a['id'], {'name': invalid, 'role': 'Tester'})
        for name in ['Nova', 'A-_.:#+|()&$^012ab', 'Z']:
            service.create_agent({'name': name, 'role': 'Tester'})
        rows = service.store.agents()
        self.assertEqual(len({r['face'] for r in rows}), len(rows))
        service = self.restart(service, start_worker=False)
        self.assertEqual(service.store.agents(), rows)
        # Repair pre-integration defaults only once.
        service.store.update_avatar(rows[1]['id'], rows[0])
        service = self.restart(service, start_worker=False)
        repaired = service.store.agents()
        self.assertNotEqual(repaired[0]['face'], repaired[1]['face'])
        service = self.restart(service, start_worker=False)
        self.assertEqual(repaired, service.store.agents())

    def test_settings_validate_before_mutation_and_persist(self):
        service = self.service(start_worker=False)
        a = service.store.agents()[0]
        b = service.create_agent({'name': 'Nova', 'role': 'Tester'})
        settings = {'name': 'Nova', 'role': 'Research', 'manager': a['id'],
                    'schedule': {'minutes': 5, 'enabled': True, 'monitor_team': True}}
        service.update_agent(b['id'], settings)
        service = self.restart(service, start_worker=False)
        saved = service.snapshot()['orchestration'][b['id']]
        self.assertEqual(saved['manager'], a['id'])
        self.assertEqual(saved['schedule']['minutes'], 5)
        with self.assertRaises(APIError):
            service.update_agent(a['id'], {'name': 'Renamed', 'role': 'Tester', 'manager': b['id'],
                                           'schedule': {'minutes': 20}})
        with self.assertRaises(APIError):
            service.update_agent(b['id'], {**settings, 'name': 'Changed', 'schedule': {'minutes': 0}})
        self.assertEqual(service.store.agents()[0]['name'], a['name'])
        self.assertEqual(service.store.agents()[1]['name'], 'Nova')
        service.update_agent(b['id'], {**settings, 'manager': None, 'schedule': {'enabled': False}})
        self.assertIsNone(service.snapshot()['orchestration'][b['id']]['manager'])
        self.assertFalse(service.snapshot()['orchestration'][b['id']]['schedule']['enabled'])

    def test_attachments_reach_agent_and_keep_original_message(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        doc = create_attachment(service, agid, {'kind': 'document', 'name': 'notes.txt',
                                              'data': base64.b64encode(b'Quarterly total: 42').decode()})
        link = create_attachment(service, agid, {'kind': 'link', 'value': 'https://example.com/report'})
        file = create_attachment(service, agid, {'kind': 'filepath', 'value': doc['value']})
        self.assertEqual(Path(doc['value']).read_text(), 'Quarterly total: 42')
        service.save_preferences({'attachment_drafts': {agid: [doc['id']]}})
        service = self.restart(service, start_worker=False)
        self.assertEqual(service.snapshot()['attachment_drafts'][agid][0]['id'], doc['id'])
        job = service.submit(agid, {'text': 'Summarize', 'attachments': [doc['id'], link['id'], file['id']]})
        service = self.restart(service)
        done = self.wait_job(service, job['id'])
        self.assertEqual(done['input'], 'Summarize')
        self.assertEqual([a['id'] for a in done['attachments']], [doc['id'], link['id'], file['id']])
        self.assertIn(doc['value'], self.factory.prompts[-1])
        self.assertIn(link['value'], self.factory.prompts[-1])
        self.assertIn('no separate mode is required', self.factory.prompts[-1])
        job2 = service.submit(agid, {'attachments': [doc['id']]})
        self.assertEqual(self.wait_job(service, job2['id'])['input'], '')

    def test_attachment_validation_and_agent_boundary(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        other = service.create_agent({'name': 'Other', 'role': 'Tester'})['id']
        for bad in [
            {'kind': 'link', 'value': 'javascript:alert(1)'},
            {'kind': 'link', 'value': 'https://user:secret@example.com'},
            {'kind': 'filepath', 'value': '/does/not/exist'},
            {'kind': 'document', 'name': '../escape', 'data': 'WA=='},
            {'kind': 'document', 'name': 'bad.txt', 'data': '***'},
            {'kind': 'image', 'name': 'not.png', 'data': 'WA=='}]:
            with self.assertRaises(APIError):
                create_attachment(service, agid, bad)
        doc = create_attachment(service, agid, {'kind': 'document', 'name': 'safe.txt', 'data': 'WA=='})
        with self.assertRaises(APIError):
            service.submit(other, {'text': 'Read', 'attachments': [doc['id']]})
        with self.assertRaises(APIError):
            service.submit(agid, {'attachments': [doc['id']] * 9})
        Path(doc['value']).unlink()
        with self.assertRaises(APIError):
            service.submit(agid, {'attachments': [doc['id']]})

    def test_http_image_upload_and_body_limit(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        server = Server(0, service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        headers = {'Content-Type':'application/json','X-Sapiens-Local':'1'}
        def request(data, extra=None):
            conn = HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            conn.request('POST', f'/api/agents/{agid}/attachments', json.dumps(data), {**headers, **(extra or {})})
            response = conn.getresponse()
            result = response.status, json.loads(response.read())
            conn.close()
            return result
        png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jC1sAAAAASUVORK5CYII='
        status, image = request({'kind':'image','name':'pixel.png','data':png})
        self.assertEqual(status, 201)
        self.assertEqual(Path(image['value']).read_bytes(), base64.b64decode(png))
        self.assertEqual(request({'kind':'link','value':'https://example.com'}, {'Origin':'https://evil.example'})[0], 403)
        self.assertEqual(request({'kind':'document','name':'oversize.txt','data':base64.b64encode(b'x' * (10 * 1024 * 1024 + 1)).decode()})[0], 413)
