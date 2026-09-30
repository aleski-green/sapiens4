"""HTML wiki notes, chat-only runtime, and non-destructive legacy migration."""
import asyncio
from html import escape, unescape
from http.client import HTTPConnection
import json
from pathlib import Path
import threading
import time

from test_integration import IntegrationFixture
from sapiens.corpora.host.assets import asset, javascript
from sapiens.corpora.sapis.notes import Notes
from sapiens.corpora.sapis.conversations import Config
from sapiens.corpora.host.server import Server
from sapiens.validation import APIError


class NotesTest(IntegrationFixture):
    @staticmethod
    def document(about='who: Nova', content='facts: {}'):
        return (f'<section id="about"><pre><code class="language-yaml">{escape(about)}</code></pre></section>'
                '<section id="map"><nav><a href="#facts">Facts</a> — saved facts</nav></section>'
                f'<section id="content"><article id="facts"><pre><code class="language-yaml">{escape(content)}</code></pre></article></section>')

    def test_model_updates_or_keeps_wiki_and_context_only_contains_about_and_map(self):
        service = self.service()
        agid = service.registry.main
        notes = Notes(service.workspace.root(service._agent(agid)))
        self.assertEqual(list(notes.context()), ['path', 'about', 'map'])
        content = self.document('who: Nova', 'user_name: UniqueSavedName')
        self.factory.on_complete = lambda prompt: notes.path.write_text(content)
        first = service.submit(agid, dict(text='Save my name in notes'))
        self.wait_turn(service, first['id'])
        self.assertIn('Notes.html', self.factory.prompts[0])
        self.factory.on_complete = None
        revision = notes.metadata()['revision']
        second = service.submit(agid, dict(text='What is my name?'))
        self.wait_turn(service, second['id'])
        self.assertEqual(notes.metadata()['revision'], revision)
        self.assertIn('who: Nova', self.factory.prompts[-1])
        self.assertIn('saved facts', self.factory.prompts[-1])
        self.assertNotIn('UniqueSavedName', self.factory.prompts[-1], 'Detailed content is read on demand')
        self.assertIn('decide to update or keep it intact', self.factory.prompts[-1])
        service = self.restart(service)
        self.assertEqual(notes.read()['content'], content)
        self.assertEqual(len(self.factory.prompts), 2)

    def test_notes_are_isolated_and_external_edits_change_revision(self):
        service = self.service(start_worker=False)
        a = service._agent(service.registry.main)
        b = service._agent(service.create_agent(dict(name='Nova', role='Assistant'))['id'])
        notes = Notes(service.workspace.root(a)); revision = notes.metadata()['revision']
        notes.path.write_text(self.document('who: Only for the chief'))
        self.assertNotEqual(notes.metadata()['revision'], revision)
        service.orchestration.prepare(b)
        self.assertNotIn('Only for the chief', b.manifests['host-facts'])

    def test_complete_content_and_invalid_files_do_not_block_context(self):
        service = self.service(start_worker=False)
        notes = Notes(service.workspace.root(service._agent(service.registry.main)))
        content = self.document(content='x' * 70000 + 'TAIL')
        notes.path.write_text(content)
        self.assertEqual(notes.read()['content'], content)
        self.assertNotIn('TAIL', str(notes.context()))
        notes.path.write_text(self.document(about='x' * 13000))
        self.assertIsNone(notes.context()['about'])
        for invalid in (b'\xff', b'<section id="content"></section>', b'<section id="about"></section>' * 3):
            notes.path.write_bytes(invalid)
            self.assertIn('error', notes.context())
        notes.path.unlink(); outside = service.root / 'private.txt'; outside.write_text('Not notes')
        notes.path.symlink_to(outside)
        with self.assertRaises(APIError): notes.read()
        self.assertNotIn('Not notes', str(notes.context()))
        self.assertIn('error', notes.metadata())

    def test_migration_preserves_legacy_text_and_never_overwrites_html(self):
        notes = Notes(Path(self.directory.name) / 'workspace'); notes.workspace.mkdir()
        original = 'facts:\n  name: Aleksi\n  image: "<script>literal 😎</script>"\nnotes: []\n'
        legacy = notes.workspace / 'Notes.yaml'; legacy.write_bytes(original.encode())
        (notes.workspace / 'Notes.md').write_text('Older notes')
        notes.ensure('Nova', 'Research assistant')
        self.assertIn('Research assistant', notes.context()['about'])
        self.assertIn('saved facts', notes.context()['map'])
        source = notes.read()['content']
        self.assertNotIn('<script>', source)
        self.assertIn('<script>literal 😎</script>', unescape(source))
        self.assertEqual(legacy.read_bytes(), original.encode())
        self.assertNotIn('Older notes', source)
        revision = notes.metadata()['revision']; notes.ensure()
        self.assertEqual(notes.metadata()['revision'], revision)
        notes.path.write_text(self.document()); notes.ensure()
        self.assertEqual(notes.path.read_text(), self.document())

    def test_unsafe_legacy_files_and_images_never_escape_workspace(self):
        notes = Notes(Path(self.directory.name) / 'workspace'); notes.workspace.mkdir()
        outside = Path(self.directory.name) / 'private.md'; outside.write_text('Private data')
        legacy = notes.workspace / 'Notes.md'; legacy.symlink_to(outside)
        notes.ensure(); self.assertFalse(notes.path.exists()); self.assertIn('error', notes.context())
        legacy.unlink(); legacy.write_bytes(b'\xff')
        notes.ensure(); self.assertEqual(legacy.read_bytes(), b'\xff')
        image = notes.workspace / 'sample.gif'; image.write_bytes(b'GIF89a')
        self.assertEqual(notes.image('sample.gif'), (b'GIF89a', 'image/gif'))
        for path in ('../private.md', str(outside), 'Notes.md'):
            with self.assertRaises((ValueError, APIError)): notes.image(path)
        image.unlink(); image.symlink_to(outside)
        with self.assertRaises(ValueError): notes.image('sample.gif')

    def test_removed_commands_and_flows_are_rejected_including_batches(self):
        service = self.service(start_worker=False)
        a = service._agent(service.registry.main)
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
                a.runner.submit(flow, 'Must not execute')
            with self.assertRaises(APIError):
                service.submit(a.agid, dict(text='Must not execute', flow=flow))
        self.assertEqual(a.state['turns'], [])
        self.assertEqual(set(Config.flows), {'chat','computer'})
        self.assertFalse(hasattr(service, 'scheduled'))
        self.assertFalse(hasattr(a, 'awake'))
        self.assertFalse(hasattr(a, 'consolidate'))

    def test_notes_http_and_removed_routes(self):
        service = self.service(start_worker=False)
        a = service._agent(service.registry.main)
        content = self.document(content='<script>alert("notes")</script>')
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
        (service.workspace.root(a) / 'a b.gif').write_bytes(b'GIF89a')
        connection.request('GET', f'/api/agents/{a.agid}/notes?image=a%2520b.gif')
        response = connection.getresponse()
        self.assertEqual((response.status, response.getheader('Content-Type'), response.read()),
                         (200, 'image/gif', b'GIF89a'))
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
        self.assertIn(b'data-panel="tasks">Tasks', asset('/workspace/')[1])
        self.assertIn(b'disabled aria-disabled="true" title="Inactive">Jobs', asset('/workspace/')[1])

    def test_legacy_data_is_archived_but_never_scheduled_or_used_as_memory(self):
        service = self.service(start_worker=False)
        a = service._agent(service.registry.main)
        turn = service.submit(a.agid, dict(text='Historic chat'))['id']
        asyncio.run(a.runner.run())
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
        a.path.write_text(json.dumps(saved))
        (a.root / 'host.json').write_text(json.dumps(dict(enabled=True, consolidate_requested=True, next_check=None)))
        (a.root / 'recurring.json').write_text('[{"enabled":true,"prompt":"DO NOT RUN"}]')
        a.set_manifest('operating-policy','OLD POLICY MUST NOT BE USED')
        a.set_manifest('task-comments','OLD TASK COMMENT MUST NOT BE USED')
        original = a.path.read_bytes()
        service = self.restart(service)
        current = service._agent(a.agid)
        self.assertEqual((a.root / 'legacy-state-v1.json').read_bytes(), original)
        self.assertEqual(current.state['schema_version'], 3)
        self.assertEqual([t['id'] for t in current.state['turns']], [turn])
        self.assertEqual(service.snapshot()['turns'][0]['output'], 'Connected through AgentPy.')
        self.assertEqual(service.snapshot()['preferences']['panel'], 'notes')
        self.assertNotIn('work_views', service.snapshot()['preferences'])
        self.assertIn('about', Notes(service.workspace.root(current)).context())
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
        agent = service._agent(service.registry.main)
        with agent.transaction() as state:
            state['chat'] = [dict(role='agent', content='old context ' * 2000) for _ in range(10)]
        notes = Notes(service.workspace.root(agent))
        notes.path.write_text(self.document(about='who: Keep my name Aleksi.'))
        service.start()
        request = service.submit(agent.agid, dict(text='Current request ' * 900))
        self.wait_turn(service, request['id'])
        prompt = self.factory.prompts[-1]
        self.assertLessEqual(len(prompt), 60_000)
        self.assertIn('Keep my name Aleksi.', prompt)
        self.assertIn(('Current request ' * 900).strip(), prompt)
        self.assertIn('history_truncated', prompt)
