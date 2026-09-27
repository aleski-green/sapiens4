"""Real gated provider calls prove overlap without paid model requests."""
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from sapiens import computer
from sapiens.service import APIError, Service
from sapiens.server import Server
from test_integration import ScriptedFactory


class ParallelTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.factories = {}
        self.services = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for factory in self.factories.values():
            factory.gate.set()
        for service in self.services:
            service.close()
        self.temp.cleanup()

    def builder(self, agid, sink):
        factory = ScriptedFactory(gate=threading.Event())
        factory.sink = sink
        self.factories[agid] = factory
        return factory

    def service(self, **kwargs):
        service = Service(self.temp.name, factory_builder=self.builder, **kwargs)
        self.services.append(service)
        return service

    def until(self, predicate):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.01)
        self.fail('Condition did not become true')

    def test_parallel_calls_are_bounded_and_same_sapi_wakes_coalesce(self):
        s = self.service(start_worker=False, max_parallel_agents=2)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second', role='Assistant'))['id']
        c = s.create_agent(dict(name='Third', role='Assistant'))['id']
        for agid in (a,b,c):
            s.submit(agid, dict(text='Work independently'))
        for _ in range(8):
            s._queue.put(a)
        s.start()
        self.assertTrue(self.factories[a].started.wait(3))
        self.assertTrue(self.factories[b].started.wait(3))
        self.assertFalse(self.factories[c].started.is_set())
        self.assertEqual(s._agent(c).state['jobs'][-1]['status'], 'queued')
        self.assertIsNone(s.snapshot()['computer']['owner'])
        with self.assertRaises(APIError):
            s.submit(a, dict(text='Duplicate'))
        self.factories[a].gate.set()
        self.assertTrue(self.factories[c].started.wait(3))
        self.assertFalse(self.factories[b].gate.is_set())
        self.assertEqual(len(self.factories[a].prompts),1)

    def test_scheduled_task_does_not_block_another_sapis_chat(self):
        s = self.service(start_worker=False)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second', role='Assistant'))['id']
        s.orchestration.control(a, dict(op='task', title='Do the scheduled task', due='2000-01-01T00:00:00+00:00'))
        s.start()
        self.assertTrue(self.factories[a].started.wait(3))
        s.submit(b, dict(text='Answer now'))
        self.assertTrue(self.factories[b].started.wait(3))
        self.assertFalse(self.factories[a].gate.is_set())

    def test_memory_maintenance_does_not_block_chat(self):
        s = self.service(start_worker=False)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second', role='Assistant'))['id']
        agent = s._agent(a)
        with agent.store.transaction() as state:
            state['notes'].append(dict(flow='task', content='Remember the verified result'))
            state['chat_revision'] += 1
        s.orchestration.control(a, dict(op='consolidate'))
        s.start()
        self.assertTrue(self.factories[a].started.wait(3))
        self.assertTrue(any(j['flow']=='learning' and j['status']=='running' for j in agent.state['jobs']))
        s.submit(b, dict(text='Answer now'))
        self.assertTrue(self.factories[b].started.wait(3))
        self.assertFalse(self.factories[a].gate.is_set())

    def test_close_waits_for_all_runners_and_preserves_queued_work(self):
        s = self.service(start_worker=False, max_parallel_agents=2)
        ids = [s.hierarchy.main] + [s.create_agent(dict(name=n,role='Assistant'))['id'] for n in ('Second','Third')]
        for agid in ids:
            s.submit(agid, dict(text='Keep this job'))
        s.start()
        for agid in ids[:2]:
            self.assertTrue(self.factories[agid].started.wait(3))
        closing = threading.Thread(target=s.close)
        closing.start()
        self.until(s._stopping.is_set)
        self.factories[ids[0]].gate.set()
        self.until(lambda: not any(j['status']=='running' for j in s._agent(ids[0]).state['jobs']))
        self.assertTrue(closing.is_alive())
        with self.assertRaises(RuntimeError):
            Service(self.temp.name, start_worker=False)
        self.factories[ids[1]].gate.set()
        closing.join(3)
        self.assertFalse(closing.is_alive())
        self.assertFalse(self.factories[ids[2]].started.is_set())
        self.assertEqual(s._agent(ids[2]).state['jobs'][-1]['status'],'queued')
        resumed = self.service()
        self.assertTrue(self.factories[ids[2]].started.wait(3))
        for agid in ids[:2]:
            self.assertFalse(self.factories[agid].started.is_set())

    def test_desktop_ownership_is_lazy_exclusive_and_released_on_failure(self):
        s = self.service(start_worker=False)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second',role='Assistant'))['id']
        with self.assertRaises(APIError):
            s.acquire_computer(a)
        self.factories[a].fail = True
        for agid in (a,b):
            s.submit(agid, dict(text='Work'))
        s.start()
        for agid in (a,b):
            self.assertTrue(self.factories[agid].started.wait(3))
        self.assertEqual(s.orchestration.control(a, dict(op='computer_acquire')), {'owner':a})
        self.assertEqual(s.acquire_computer(a), {'owner':a})
        with self.assertRaises(APIError) as error:
            s.acquire_computer(b)
        self.assertEqual(error.exception.status,409)
        s.release_computer(b)
        self.assertEqual(s.snapshot()['computer']['owner'],a)
        self.factories[a].gate.set()
        self.until(lambda:s.snapshot()['computer']['owner'] is None)
        self.assertEqual(s.acquire_computer(b),{'owner':b})
        s.release_computer(b, lambda:self.assertEqual(s.snapshot()['computer']['owner'],b))
        self.assertIsNone(s.snapshot()['computer']['owner'])

    def test_cancelled_queued_job_is_not_started_by_a_stale_wakeup(self):
        s = self.service(start_worker=False, max_parallel_agents=1)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second', role='Assistant'))['id']
        s.submit(a, dict(text='First'))
        second = s.submit(b, dict(text='Cancel this queued job'))
        s.start()
        self.assertTrue(self.factories[a].started.wait(3))
        s.job_action(b, second['id'], 'cancel')
        self.factories[a].gate.set()
        self.until(lambda:not s._runners)
        self.assertFalse(self.factories[b].started.is_set())
        third = s.submit(b, dict(text='New request'))
        self.assertTrue(self.factories[b].started.wait(3))
        self.assertEqual(len(self.factories[b].prompts), 1)
        self.assertEqual(next(j for j in s._agent(b).state['jobs'] if j['id']==second['id'])['status'], 'cancelled')

    def test_computer_wrapper_reserves_through_real_host_endpoint(self):
        s = self.service(start_worker=False)
        a = s.hierarchy.main
        b = s.create_agent(dict(name='Second', role='Assistant'))['id']
        server = Server(0, s)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for agid in (a,b):
                s.submit(agid, dict(text='Work'))
            s.start()
            for agid in (a,b):
                self.assertTrue(self.factories[agid].started.wait(3))
            with patch.object(computer.Path, 'cwd', return_value=s.workspace.root(s._agent(a))):
                computer.acquire()
            self.assertEqual(s.snapshot()['computer']['owner'], a)
            with patch.object(computer.Path, 'cwd', return_value=s.workspace.root(s._agent(b))):
                with self.assertRaisesRegex(ValueError, 'busy'):
                    computer.acquire()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_busy_computer_wrapper_does_not_invoke_native_tools(self):
        with patch.object(computer.sys, 'platform', 'darwin'), \
             patch.object(computer, 'acquire', side_effect=ValueError('Shared computer busy')), \
             patch.object(computer.subprocess, 'run') as run, \
             patch.object(Path, 'touch') as touch:
            for argv in (['blindly','apps'], ['read','--pid','42','--path','0'], ['launch','Safari']):
                with self.assertRaisesRegex(ValueError,'busy'):
                    computer.main(argv)
            run.assert_not_called()
            touch.assert_not_called()
