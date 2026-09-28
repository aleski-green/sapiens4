"""Plain notes, chat-only runtime, and non-destructive legacy migration."""
import asyncio
from copy import deepcopy
from http.client import HTTPConnection
import json
from pathlib import Path
import threading
import time

from test_integration import IntegrationFixture
from sapiens.assets import asset, javascript
from sapiens.notes import Notes
from sapiens.runtime import Config
from sapiens.server import Server
from sapiens.validation import APIError


class NotesTest(IntegrationFixture):
    def test_model_edits_file_and_next_chat_reads_latest_notes(self):
        service = self.service()
        agid = service.hierarchy.main
        path = service.workspace.root(service._agent(agid)) / 'Notes.md'
        self.assertEqual(path.read_text(), '')
        self.factory.on_complete = lambda prompt: path.write_text('# Preferences\nCall me Aleksi.\n')
        first = service.submit(agid, dict(text='Save my name in notes'))
        self.wait_turn(service, first['id'])
        self.assertIn('Notes.md', self.factory.prompts[0])
        self.factory.on_complete = None
        second = service.submit(agid, dict(text='What is my name?'))
        self.wait_turn(service, second['id'])
        self.assertIn('Call me Aleksi.', self.factory.prompts[-1])
        self.assertEqual(len(self.factory.prompts), 2)
        service = self.restart(service)
        self.assertEqual(path.read_text(), '# Preferences\nCall me Aleksi.\n')
        self.assertEqual(service.snapshot()['orchestration'][agid]['notes']['path'], str(path))
        self.assertEqual(len(self.factory.prompts), 2)

    def test_notes_are_isolated_and_external_file_edits_change_revision(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        b = service._agent(service.create_agent(dict(name='Nova', role='Assistant'))['id'])
        notes = Notes(service.workspace.root(a))
        revision = notes.metadata()['revision']
        notes.path.write_text('Only for the chief')
        self.assertNotEqual(notes.metadata()['revision'], revision)
        self.assertEqual(Notes(service.workspace.root(b)).read()['content'], '')
        service.orchestration.prepare(b)
        self.assertNotIn('Only for the chief', b.manifests['host-facts'])
        notes.path.unlink()
        self.assertEqual(notes.read()['content'], '')

    def test_notes_reading_is_bounded_and_invalid_files_do_not_block_chat(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        notes = Notes(service.workspace.root(a))
        notes.path.write_text('x' * 70000)
        self.assertEqual(len(notes.read()['content']), 64000)
        self.assertTrue(notes.read()['truncated'])
        self.assertEqual(len(notes.context()['content']), 12000)
        notes.path.write_bytes(b'\xff')
        self.assertIn('UTF-8', notes.context()['error'])
        outside = service.root / 'private.txt'
        outside.write_text('Not notes')
        notes.path.unlink()
        notes.path.symlink_to(outside)
        with self.assertRaises(APIError):
            notes.read()
        self.assertIn('error', notes.metadata())
        service.orchestration.prepare(a)
        self.assertNotIn('Not notes', a.manifests['host-facts'])
        notes.path.unlink()
        notes.path.mkdir()
        with self.assertRaises(APIError):
            notes.read()

    def test_removed_commands_and_flows_are_rejected_including_batches(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        for op in ('consolidate','task','finish_task','run_task','rename_task','task_comment',
                   'dismiss_task','request_agent','recurring_job','run_job','checkpoint',
                   'strategy','job_diagnostics','schedule','budget_diagnostics','execution'):
            with self.subTest(op=op):
                with self.assertRaises(APIError):
                    service.orchestration.control(a.agid, dict(op=op))
                with self.assertRaises(APIError):
                    service.orchestration.control(a.agid, dict(op='batch', operations=[dict(op=op)]))
        for flow in ('learning','scheduled','task','strategy','team_review','morphosis'):
            with self.assertRaises(ValueError):
                a.submit(flow, 'Must not execute')
            with self.assertRaises(APIError):
                service.submit(a.agid, dict(text='Must not execute', flow=flow))
        self.assertEqual(a.state['turns'], [])
        self.assertEqual(set(Config.flows), {'chat','computer'})
        self.assertFalse(hasattr(service, 'scheduled'))
        self.assertFalse(hasattr(a, 'awake'))
        self.assertFalse(hasattr(a, 'consolidate'))

    def test_notes_http_and_removed_routes(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        content = '<script>alert("notes")</script>\n# Plain markdown'
        Notes(service.workspace.root(a)).path.write_text(content)
        server = Server(0, service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connection = HTTPConnection('127.0.0.1', server.server_port)
        self.addCleanup(connection.close)
        connection.request('GET', f'/api/agents/{a.agid}/notes')
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.read())['content'], content)
        for suffix in ('memory','tasks/missing','usage'):
            connection.request('GET', f'/api/agents/{a.agid}/{suffix}')
            response = connection.getresponse(); response.read()
            self.assertEqual(response.status, 404)
        headers = {'Content-Type':'application/json','X-Sapiens-Local':'1'}
        for suffix in ('jobs/missing/retry', 'tasks/missing/comments'):
            connection.request('POST', f'/api/agents/{a.agid}/{suffix}', '{}', headers)
            response = connection.getresponse(); response.read()
            self.assertEqual(response.status, 404)
        connection.request('GET', f'/api/agents/{a.agid}/notes', headers={'Origin':'https://evil.example'})
        response = connection.getresponse(); response.read()
        self.assertEqual(response.status, 403)
        self.assertIsNone(asset('/mindmap.html'))
        self.assertNotIn('renderMindMap', javascript())
        self.assertIn(b'disabled aria-disabled="true" title="Inactive">Tasks', asset('/workspace/')[1])

    def test_legacy_data_is_archived_but_never_scheduled_or_used_as_memory(self):
        service = self.service(start_worker=False)
        a = service._agent(service.hierarchy.main)
        turn = service.submit(a.agid, dict(text='Historic chat'))['id']
        asyncio.run(a.run())
        service._sync(a)
        saved = a.state
        saved['schema_version'] = 1
        saved['jobs'] = saved.pop('turns')
        for row in saved['jobs']:
            row['task'] = row.pop('input')
        for field in ('chat','events'):
            for row in saved[field]:
                if 'turn' in row:
                    row['job'] = row.pop('turn')
        saved.update(memx=[{'id':'obsolete', 'text':'OLD MEMORY MUST NOT BE USED'}],
            tasks=[{'id':'old-task','status':'open','due':'2000-01-01T00:00:00+00:00'}],
            notes=[{'content':'OLD AUTOMATIC NOTE'}], memory_pending=True,
            chat_revision=10, learned_revision=0, next_awake=None, last_circa=None,
            morphos_version='old-version', projects=[], outbox=[])
        for flow in ('learning','scheduled','task','team_review','strategy'):
            saved['jobs'].append(dict(id=flow, flow=flow, task='DO NOT RUN', status='queued',
                                     created='2026-01-01T00:00:00+00:00', tokens=0))
        with service.store.connect() as db:
            db.execute('ALTER TABLE turns RENAME TO jobs')
            db.execute('PRAGMA user_version=2')
        service.store.preferences(dict(selected=a.agid, panel='mindmap', work_views={'tasks':'past'}))
        service.close()
        a.store.path.write_text(json.dumps(saved))
        (a.root / 'host.json').write_text(json.dumps(dict(enabled=True, consolidate_requested=True, next_check=None)))
        (a.root / 'recurring.json').write_text('[{"enabled":true,"prompt":"DO NOT RUN"}]')
        a.set_manifest('operating-policy','OLD POLICY MUST NOT BE USED')
        a.set_manifest('task-comments','OLD TASK COMMENT MUST NOT BE USED')
        original = a.store.path.read_bytes()
        service = self.restart(service)
        current = service._agent(a.agid)
        self.assertEqual((a.root / 'legacy-state-v1.json').read_bytes(), original)
        self.assertEqual(current.state['schema_version'], 3)
        self.assertEqual([t['id'] for t in current.state['turns']], [turn])
        self.assertEqual(service.snapshot()['turns'][0]['output'], 'Connected through AgentPy.')
        self.assertEqual(service.snapshot()['preferences']['panel'], 'notes')
        self.assertNotIn('work_views', service.snapshot()['preferences'])
        self.assertEqual(Notes(service.workspace.root(current)).read()['content'], '')
        time.sleep(1.1)  # Former scheduler checked every second.
        self.assertEqual(len(self.factory.prompts), 1)
        request = service.submit(a.agid, dict(text='New conversation'))
        self.wait_turn(service, request['id'])
        for sentinel in ('OLD MEMORY','OLD AUTOMATIC NOTE','OLD POLICY','OLD TASK COMMENT','DO NOT RUN'):
            self.assertNotIn(sentinel, self.factory.prompts[-1])
        service = self.restart(service, start_worker=False)
        self.assertEqual((a.root / 'legacy-state-v1.json').read_bytes(), original)
        self.assertEqual(len(service.snapshot()['turns']), 2)

    def test_long_history_does_not_require_consolidation_to_continue(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        with agent.store.transaction() as state:
            state['chat'] = [dict(role='agent', content='old context ' * 2000) for _ in range(10)]
        notes = Notes(service.workspace.root(agent))
        notes.path.write_text('Keep my name Aleksi.')
        service.start()
        request = service.submit(agent.agid, dict(text='Current request ' * 900))
        self.wait_turn(service, request['id'])
        prompt = self.factory.prompts[-1]
        self.assertLessEqual(len(prompt), 60_000)
        self.assertIn('Keep my name Aleksi.', prompt)
        self.assertIn(('Current request ' * 900).strip(), prompt)
        self.assertIn('history_truncated', prompt)
