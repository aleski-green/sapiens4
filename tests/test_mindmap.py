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
        # Repeated requests without new input are free no-ops, including after restart.
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        status = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(status['status'], 'done')
        self.assertEqual(first, status['run']['id'])
        self.assertFalse(status['has_updates'])
        service = self.restart(service, start_worker=False)
        self.assertEqual(service.snapshot()['orchestration'][owner]['memory']['status'], 'done')
        calls = len(self.factory.prompts)
        self.assertEqual(service.orchestration.control(owner, {'op':'consolidate'})['status'], 'unchanged')
        service.scheduled()
        self.assertEqual(len(self.factory.prompts), calls)
        service.submit(owner, {'text':'A new preference'})
        asyncio.run(service._agent(owner).run())
        self.assertTrue(service.snapshot()['orchestration'][owner]['memory']['has_updates'])
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        self.assertNotEqual(first, service.snapshot()['orchestration'][owner]['memory']['run']['id'])
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

    def test_explicit_memory_does_not_retry_old_failure_or_budget_blocked_work(self):
        service, owner = self.prepare()
        self.factory.fail = True
        failed = service.submit(owner, {'text':'Check Slack'})
        agent = service._agent(owner)
        asyncio.run(agent.run())
        self.factory.fail = False
        blocked = agent.submit('computer', 'Unrelated stopped work')
        with agent.store.transaction() as state:
            next(j for j in state['jobs'] if j['id'] == blocked)['status'] = 'budget_blocked'
        service._sync(agent)
        service.orchestration.control(owner, {'op':'consolidate'})
        self.assertIsNone(service.snapshot()['orchestration'][owner]['memory']['blocker'])
        service.scheduled()
        memory = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(memory['status'], 'done')
        statuses = {j['id']: j['status'] for j in agent.state['jobs']}
        self.assertEqual(statuses[failed['id']], 'failed')
        self.assertEqual(statuses[blocked], 'budget_blocked')
        self.assertEqual(len(self.factory.prompts), 4)  # Failed chat + three memory roles.
        self.assertEqual(len(agent.memx), 1)
        service.scheduled()
        self.assertEqual(len(self.factory.prompts), 4)  # No repeated learning or chat retry.

    def test_state_changes_unlock_but_bookkeeping_and_learning_do_not(self):
        service, owner = self.prepare()
        agent = service._agent(owner)
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        self.assertFalse(service.memory_status(agent, service.snapshot()['jobs'])['has_updates'])
        settings = service.orchestration.settings(agent)
        settings.update(next_check='2099-01-01T00:00:00+00:00', last_check='2026-01-01T00:00:00+00:00')
        service.orchestration.save(agent, settings)
        service.orchestration.prepare(agent)
        self.assertFalse(service.snapshot()['orchestration'][owner]['memory']['has_updates'])
        # Exercise migration from the archived input of a pre-fingerprint run.
        with agent.store.transaction() as state:
            for job in state['jobs']:
                job.pop('memory_input_fingerprint', None)
        self.assertFalse(service.snapshot()['orchestration'][owner]['memory']['has_updates'])
        service.orchestration.control(owner, {'op':'schedule', 'minutes':17})
        self.assertTrue(service.snapshot()['orchestration'][owner]['memory']['has_updates'])
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        self.assertFalse(service.snapshot()['orchestration'][owner]['memory']['has_updates'])
        with agent.store.transaction() as state:
            state['tasks'].append({'id':'new-task', 'title':'New work'})
        self.assertTrue(service.snapshot()['orchestration'][owner]['memory']['has_updates'])

    def test_input_arriving_during_learning_is_not_marked_learned(self):
        service, owner = self.prepare()
        agent = service._agent(owner)
        original = agent._work
        def work(job, snapshot, config):
            result = original(job, snapshot, config)
            if job['flow'] == 'learning':
                with agent.store.transaction() as state:
                    state['tasks'].append({'id':'arrived-during-learning', 'title':'Later work'})
            return result
        agent._work = work
        service.orchestration.control(owner, {'op':'consolidate'})
        service.scheduled()
        status = service.snapshot()['orchestration'][owner]['memory']
        self.assertEqual(status['status'], 'done')
        self.assertTrue(status['has_updates'])
