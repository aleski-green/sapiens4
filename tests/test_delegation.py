"""Real host/runner/persistence with deterministic, schema-shaped model decisions."""
from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from sapiens.corpora.host.delegation import PROMPTS, TRANSITIONS, yaml_text
from sapiens.corpora.host.server import Server
from sapiens.corpora.host.service import Service
from sapiens.validation import APIError


CRITERION = 'Return a sourced comparison.'


def answer(event, **fields):
    return dict(event=event, reason='Scripted decision based on the supplied task.',
                evidence=['Synthetic test input.'], **fields)


class Provider:
    def __init__(self):
        self.calls = []
        self.responses = {}
        self.observe = None

    def builder(self, agid, sink):
        provider = self
        class Factory:
            def spawn(self, spec):
                class LLM:
                    id = 'scripted-session'
                    def complete(self, text):
                        provider.calls.append((agid, spec.role, text))
                        if provider.observe:
                            provider.observe(agid, spec.role, text)
                        response = provider.responses.get((agid, spec.role), provider.responses.get(spec.role))
                        if callable(response):
                            response = response(text)
                        if response is None:
                            response = {
                                'Assessing': answer('FitsSpecialization', mode='Exec'),
                                'ReadyToWork': answer('TaskPrepared', taskType='research', specification=dict(
                                    objective='Compare the products.', inputs=[], expectedOutputs=['A comparison'],
                                    completionCriteria=[CRITERION])),
                                'Execution': answer('Outcome', reply='Comparison from ' + agid, outcome=dict(
                                    status='Completed', satisfiedCriteria=[CRITERION], artifacts=[])),
                                'Delegation': answer('HandoffPrepared', request='Compare the products.'),
                                'CreatingSapi': answer('SapiSpecified', name='NewResearcher', role='Research'),
                            }[spec.role]
                        return response if isinstance(response, str) else json.dumps(response)
                return LLM()
        return Factory()


class DelegationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.provider = Provider()
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=False)
        self.addCleanup(lambda: self.service.close())
        self.chief = self.service.registry.main
        self.researcher = self.service.create_agent(dict(name='Researcher', role='Research'))['id']

    def until(self, predicate):
        end = time.monotonic() + 6
        while time.monotonic() < end:
            result = predicate()
            if result:
                return result
            time.sleep(.01)
        self.fail('Timed out: ' + str(self.service.snapshot().get('workloads')))

    def wait_idle(self):
        self.until(lambda: not any(t['status'] in {'running','queued'} for t in self.service.snapshot()['turns']))
        self.until(lambda: not self.service._runners)

    def restart(self, start_worker=True):
        self.service.close()
        self.service = Service(self.temp.name, factory_builder=self.provider.builder, start_worker=start_worker)

    def chief_routes(self, target=None):
        self.provider.responses[self.chief, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('SpecialistSelected', target=target or self.researcher)

    def run_request(self, agid=None, **fields):
        result = self.service.submit(agid or self.chief, dict(text='Compare the products.', **fields))
        self.service.start()
        self.wait_idle()
        return result['id']

    def test_delegation_runs_recipient_triage_and_returns_attributed_result(self):
        self.chief_routes()
        call_id = self.run_request()
        work = self.service.store.workloads()[0]
        self.assertEqual([c['addressedTo'] for c in work['calls']], [self.chief, self.researcher])
        self.assertEqual(work['calls'][1]['causedBy'], call_id)
        self.assertEqual(work['calls'][-1]['state'], 'Completed')
        self.assertEqual(work['outcome']['author'], self.researcher)
        self.assertEqual([n for a,n,_ in self.provider.calls if a == self.chief], ['Assessing','ChiefTriage','Delegation'])
        self.assertEqual([n for a,n,_ in self.provider.calls if a == self.researcher], ['Assessing','ReadyToWork','Execution'])
        self.assertTrue(all(d['accepted'] for d in work['decisions']))
        full = self.service.delegation.tasks(self.chief, full=True)['tasks'][0]
        self.assertEqual(full['execution']['owner'], self.researcher)
        self.assertIn('renderedPrompt', full['decisions'][0])
        count = len(self.provider.calls)
        self.restart()
        self.assertEqual(len(self.provider.calls), count)
        self.assertEqual(self.service.delegation.tasks(self.chief)['tasks'][0]['task'], full['task'])

    def test_specialist_referral_then_chief_selects_another_specialist(self):
        writer = self.service.create_agent(dict(name='Writer', role='Writing'))['id']
        self.provider.responses[writer, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('SpecialistSelected', target=self.researcher)
        self.run_request(writer)
        work = self.service.store.workloads()[0]
        self.assertEqual([c['addressedTo'] for c in work['calls']], [writer,self.chief,self.researcher])
        self.assertEqual(len({w['workloadId'] for w in self.service.store.workloads()}),1)

    def test_recipient_context_distinguishes_original_routing_from_assigned_work(self):
        self.chief_routes()
        self.run_request()
        rendered = next(text for agid,node,text in self.provider.calls if agid == self.researcher and node == 'Assessing')
        context = json.loads(rendered.split('\nContext:\n',1)[1])
        self.assertTrue(context['tracked'])
        self.assertIsNotNone(context['currentCall']['causedBy'])
        self.assertEqual(context['currentCall']['addressedTo'],self.researcher)
        self.assertEqual(context['selfId'],self.researcher)
        execution = next(text for agid,node,text in self.provider.calls if agid == self.researcher and node == 'Execution')
        for decision in (rendered, execution):
            self.assertIn('decide to update or keep it intact', decision)
            self.assertIn(str(Path(__file__).parents[1] / 'prompts/examples/jarvis-notes.html'), decision)
            self.assertNotIn('{notes_example}', decision)
            self.assertNotIn('Notes.md', decision)

    def test_tracked_recipient_cannot_skip_task_specification_with_repl(self):
        self.chief_routes()
        self.provider.responses[self.researcher, 'Assessing'] = answer('FitsSpecialization',mode='Repl',reply='Done')
        self.run_request()
        work = self.service.store.workloads()[0]
        self.assertEqual(work['calls'][-1]['state'],'Failed')
        self.assertIn('accepted Task',work['calls'][-1]['error'])
        self.assertIsNone(work['outcome'])

    def test_creation_requires_authority_and_uses_named_prompt(self):
        self.provider.responses[self.chief, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('NewSpecialistNeeded')
        self.run_request(allow_create=False)
        self.assertEqual(len(self.service.store.agents()),2)
        self.assertNotIn('CreatingSapi', [n for _,n,_ in self.provider.calls])
        self.run_request(allow_create=True)
        work = self.service.store.workloads()[-1]
        self.assertEqual(work['calls'][-1]['state'], 'Completed')
        self.assertEqual(len(self.service.store.agents()),3)
        self.assertIn('CreatingSapi', [n for _,n,_ in self.provider.calls])

    def test_admin_clarification_keeps_workload_identity(self):
        self.provider.responses[self.chief, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('RequestUnclear', question='Which products?')
        first = self.run_request()
        self.assertEqual(self.service.store.workloads()[0]['calls'][0]['state'], 'WaitingForAdmin')
        self.provider.responses['ChiefTriage'] = answer('SpecialistSelected', target=self.researcher)
        second = self.service.submit(self.chief, dict(text='Products A, B, C.', workload=first))['id']
        self.wait_idle()
        work = self.service.store.workloads()[0]
        self.assertEqual(work['workloadId'], first)
        self.assertEqual(work['calls'][1]['callId'], second)
        self.assertEqual(work['calls'][1]['activation'], 'RequestClarified')
        self.assertEqual(work['calls'][-1]['state'], 'Completed')

    def test_invalid_decision_is_recorded_without_dispatch(self):
        self.provider.responses['Assessing'] = answer('StartCron', minutes=5)
        call_id = self.run_request()
        turn = self.service.store.projected_turn(call_id)
        self.assertEqual(turn['status'], 'failed')
        records = self.service.delegation.records(self.chief)['decisions']
        self.assertFalse(records[0]['accepted'])
        self.assertIn('StartCron', records[0]['rawResponse'])
        self.assertEqual(len(self.provider.calls),1)
        with self.assertRaises(APIError):
            self.service.orchestration.control(self.chief, dict(op='delegate', decision=records[0]['decisionId']))

    def test_busy_and_retired_recipients_do_not_transfer_responsibility(self):
        for busy in (True, False):
            with self.subTest(busy=busy):
                self.chief_routes()
                if busy:
                    queued = self.service.submit(self.researcher, dict(text='Other work.'))['id']
                else:
                    self.service.lifecycle.change(self.researcher, True)
                first = self.service.submit(self.chief, dict(text='Compare.'))['id']
                self.service._run_queued(self.chief)
                self.service._sync(self.service._agent(self.chief))
                self.service.delegation.reconcile(self.chief)
                work, _ = self.service.delegation.find(first)
                self.assertEqual(len(work['calls']),1)
                self.assertEqual(self.service.store.projected_turn(first)['status'],'failed')
                if busy:
                    self.service.turn_action(self.researcher, queued, 'cancel')

    def test_accepted_handoff_recovers_before_and_after_recipient_json_submission(self):
        self.chief_routes()
        first = self.service.submit(self.chief, dict(text='Compare.'))['id']
        self.service._run_queued(self.chief)
        self.service._sync(self.service._agent(self.chief))
        work, _ = self.service.delegation.find(first)
        child = work['calls'][-1]['callId']
        self.assertIsNone(self.service.store.projected_turn(child))
        # Simulate a crash between recipient JSON persistence and SQL projection.
        with patch.object(self.service, '_sync', side_effect=RuntimeError('Crash before projection')):
            with self.assertRaises(RuntimeError):
                self.service.delegation.dispatch_pending()
        self.assertEqual(len(self.service._agent(self.researcher).state['turns']), 1)
        self.restart()
        self.wait_idle()
        self.assertEqual(len(self.service._agent(self.researcher).state['turns']), 1)
        self.assertEqual(self.service.store.projected_turn(child)['status'], 'done')
        self.assertEqual([n for a,n,_ in self.provider.calls if a == self.researcher].count('Execution'),1)

    def test_accepted_intent_survives_restart_before_recipient_submission(self):
        self.chief_routes()
        self.service.submit(self.chief, dict(text='Compare.'))
        self.service._run_queued(self.chief)
        self.service._sync(self.service._agent(self.chief))
        self.assertEqual(self.service._agent(self.researcher).state['turns'], [])
        with self.assertRaises(APIError):
            self.service.lifecycle.change(self.researcher, True)
        self.restart()
        self.wait_idle()
        self.assertEqual(len(self.service._agent(self.researcher).state['turns']),1)
        self.assertEqual(self.service.store.workloads()[0]['calls'][-1]['state'],'Completed')

    def test_duplicate_handoff_receipt_never_creates_another_call(self):
        self.chief_routes()
        original = self.service.orchestration.control
        receipts = []
        def repeated(agid, data):
            result = original(agid, data)
            if data['op'] == 'delegate':
                receipts.extend([result, original(agid, data)])
            return result
        with patch.object(self.service.orchestration, 'control', side_effect=repeated):
            self.run_request()
        self.assertEqual(receipts[0],receipts[1])
        self.assertEqual(len(self.service.store.workloads()[0]['calls']),2)

    def test_call_timeout_is_shared_across_decision_nodes(self):
        with patch('sapiens.corpora.host.delegation.monotonic', side_effect=[0,1000]):
            call_id = self.run_request()
        self.assertEqual(self.provider.calls,[])
        turn = self.service.store.projected_turn(call_id)
        self.assertEqual(turn['status'],'failed')
        self.assertIn('Call time limit exhausted',turn['error'])

    def test_started_recipient_is_interrupted_and_only_explicit_retry_runs_it(self):
        self.chief_routes()
        self.service.submit(self.chief, dict(text='Compare.'))
        self.service._run_queued(self.chief)
        self.service._sync(self.service._agent(self.chief))
        self.service.delegation.dispatch_pending()
        agent = self.service._agent(self.researcher)
        with agent.transaction() as state:
            state['turns'][0]['status'] = 'running'
            child = state['turns'][0]['id']
        self.restart()
        self.wait_idle()
        self.assertEqual(self.service.store.projected_turn(child)['status'],'interrupted')
        self.assertFalse(any(a == self.researcher for a,_,_ in self.provider.calls))
        self.service.turn_action(self.researcher, child, 'retry')
        self.wait_idle()
        self.assertEqual(self.service.store.projected_turn(child)['status'],'done')
        self.assertEqual(self.service.store.workloads()[0]['calls'][-1]['attempt'],2)

    def test_routing_rejection_cannot_loop_between_same_specialist_and_chief(self):
        self.provider.responses[self.researcher, 'Assessing'] = answer('OutsideSpecialization')
        self.provider.responses['ChiefTriage'] = answer('SpecialistSelected', target=self.researcher)
        self.run_request(self.researcher)
        work = self.service.store.workloads()[0]
        self.assertEqual(len(work['calls']),2)
        self.assertEqual(work['calls'][-1]['state'],'Failed')
        self.assertIn('already assessed', work['calls'][-1]['error'])

    def test_prompt_edit_changes_future_calls_without_rewriting_history(self):
        self.run_request()
        previous = self.service.delegation.records(self.chief)['decisions'][0]
        self.service.delegation.edit_template('Assessing', dict(content='New steering. Select the supported response for this request.'))
        self.run_request()
        records = self.service.delegation.records(self.chief)['decisions']
        next_triage = [r for r in records if r['node'] == 'Assessing'][-1]
        self.assertNotEqual(previous['promptHash'], next_triage['promptHash'])
        self.assertIn('New steering.', next_triage['renderedPrompt'])
        self.assertEqual(previous, records[0])
        with self.assertRaises(APIError):
            self.service.delegation.edit_template('../Execution', dict(content='no'))

    def test_completion_requires_all_criteria_and_evidence(self):
        self.provider.responses['Execution'] = answer('Outcome', reply='Done', outcome=dict(
            status='Completed', satisfiedCriteria=[], artifacts=[]))
        call_id = self.run_request()
        self.assertEqual(self.service.store.projected_turn(call_id)['status'],'failed')
        work = self.service.store.workloads()[0]
        self.assertIsNone(work['outcome'])
        self.assertFalse(work['decisions'][-1]['accepted'])

    def test_stop_between_nodes_does_not_admit_a_handoff(self):
        self.chief_routes()
        def stop(agid, node, text):
            if node == 'Delegation':
                self.service._agent(agid).runner.cancel_event.set()
        self.provider.observe = stop
        call_id = self.run_request()
        self.assertEqual(self.service.store.projected_turn(call_id)['status'],'interrupted')
        self.assertEqual(len(self.service.store.workloads()[0]['calls']),1)

    def test_yaml_and_prompt_http_endpoints_preserve_origin_checks(self):
        self.run_request()
        server = Server(0, self.service)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        conn = HTTPConnection('127.0.0.1', server.server_port)
        self.addCleanup(conn.close)
        conn.request('GET', f'/api/agents/{self.chief}/tasks')
        response = conn.getresponse(); body = response.read().decode()
        self.assertEqual(response.status,200)
        self.assertIn('application/yaml',response.getheader('Content-Type'))
        self.assertIn('"renderedPrompt":',body)
        conn.request('GET', f'/api/agents/{self.chief}/tasks?format=json')
        response = conn.getresponse(); listing = json.loads(response.read())['tasks']
        self.assertEqual(response.status, 200)
        self.assertIn('application/json', response.getheader('Content-Type'))
        self.assertEqual(len(listing), 1)
        task = self.service.delegation.tasks(self.chief)['tasks'][0]
        self.assertEqual(listing[0]['body'], yaml_text(task['task']['specification']) + '\n')
        self.assertEqual(listing[0]['title'], task['task']['specification']['objective'])
        self.assertEqual(listing[0]['state'], 'Completed')
        self.assertEqual(listing[0]['owner'], self.chief)
        self.assertNotIn('decisions', listing[0])
        conn.request('PUT','/api/decision-prompts/Assessing',json.dumps(dict(content='Steer')),
                     {'Content-Type':'application/json','X-Sapiens-Local':'1','Origin':'https://evil.example'})
        response = conn.getresponse(); response.read(); self.assertEqual(response.status,403)
        conn.request('GET','/api/decision-prompts')
        response = conn.getresponse(); prompts = json.loads(response.read())['prompts']
        self.assertEqual({p['node'] for p in prompts},set(PROMPTS))

    def test_pr_notation_and_yaml_scalar_round_trip(self):
        self.assertEqual(TRANSITIONS['WaitingForAdmin','RequestClarified'],'ChiefTriage')
        self.assertTrue(all((Path(__file__).parents[1] / 'prompts' / (name + '.md')).is_file() for name in PROMPTS.values()))
        # A separate YAML implementation is a test oracle, never a runtime dependency.
        try:
            import yaml
        except ImportError:
            self.skipTest('Install tests/requirements.txt for the independent YAML parser check')
        value = {'tasks':[{'null':'null','bool':'yes', 'special':'<&> : # { }', 'multiline':'a\nb\n',
                           'unicode':'Привет 🧠\u0085\u2028', 'number':42, 'empty':[], 'none':None, 'active':True}]}
        self.assertEqual(yaml.safe_load(yaml_text(value)),value)
        self.assertEqual(yaml.safe_load(yaml_text({'tasks':[]})),{'tasks':[]})


if __name__ == '__main__':
    unittest.main()
