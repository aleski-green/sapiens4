import asyncio
import json
from http.client import HTTPConnection
import threading

from test_integration import IntegrationFixture
from test_orchestration import MemoryFactory
from sapiens.assets import memory_viewer
from sapiens.server import Server


class MindMapTest(IntegrationFixture):
    def prepare(self):
        self.factory = MemoryFactory()
        service = self.service(start_worker=False)
        owner = service.store.agents()[0]['id']
        service.orchestration.control(owner, {'op':'schedule', 'enabled':False})
        return service, owner

    def test_waiting_done_repeat_and_restart(self):
        service, owner = self.prepare()
        service.submit(owner, {'text':'Use concise answers'})
        control = service.orchestration.control
        control(owner, {'op':'consolidate'})
        request = service.orchestration.settings(service._agent(owner))['consolidation_id']
        control(owner, {'op':'consolidate'})
        self.assertEqual(request, service.orchestration.settings(service._agent(owner))['consolidation_id'])
        service.scheduled()
        self.assertEqual(service.snapshot()['orchestration'][owner]['memory']['status'], 'waiting')
        self.assertEqual(service.memory(owner)['memx'], [])
        service = self.restart(service, start_worker=False)
        asyncio.run(service._agent(owner).run())
        service.scheduled()
        status = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(status['status'], 'done')
        self.assertEqual(service.memory(owner)['memx'][0]['content'], 'Use concise answers')
        first = status['run']['id']
        # A new explicit request must run even without another chat revision.
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        status = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(status['status'], 'done')
        self.assertNotEqual(first, status['run']['id'])
        service = self.restart(service, start_worker=False)
        self.assertEqual(service.snapshot()['orchestration'][owner]['memory']['status'], 'done')
        other = service.create_agent({'name':'Nova', 'role':'Researcher'})['id']
        self.assertEqual(service.memory(other)['memx'], [])
        service.save_preferences({'panel':'mindmap'})
        self.assertEqual(service.snapshot()['preferences']['panel'], 'mindmap')

    def test_failure_is_not_done_and_duplicate_does_not_queue_more(self):
        service, owner = self.prepare()
        service.submit(owner, {'text':'Use concise answers'})
        asyncio.run(service._agent(owner).run())
        self.factory.fail = True
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        status = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(status['status'], 'failed')
        self.assertEqual(service.memory(owner)['memx'], [])
        service.orchestration.control(owner, {'op':'consolidate'})
        self.assertFalse(service.orchestration.settings(service._agent(owner))['consolidate_requested'])
        self.assertEqual(service.snapshot()['orchestration'][owner]['memory']['status'], 'failed')

    def test_read_api_and_pinned_viewer(self):
        service, owner = self.prepare()
        server = Server(0, service)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        conn = HTTPConnection('127.0.0.1', server.server_port)
        self.addCleanup(conn.close)
        conn.request('GET', f'/api/agents/{owner}/memory')
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.read()), {'memx':[]})
        conn.request('GET', '/api/agents/missing/memory')
        response = conn.getresponse()
        self.assertEqual(response.status, 404)
        response.read()
        viewer = memory_viewer()
        self.assertIn('Interactive JSON tree', viewer)
        self.assertIn("event.source !== parent", viewer)
        self.assertNotIn("loadExample('commerce');", viewer)
