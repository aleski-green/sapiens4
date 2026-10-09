"""Group contracts, durable routing and concurrent edits against real host runners."""
import json
import sys
import threading
import time
import unittest
from http.client import HTTPConnection

from sapiens.corpora.host.server import Server
from sapiens.corpora.host.service import APIError
from sapiens.corpora.sapis.attachments import create_attachment
from test_integration import IntegrationFixture
if sys.platform != 'win32':
    from macos.updater import busy


class GroupsTest(IntegrationFixture):
    def setup_group(self, start_worker=False):
        s = self.service(start_worker=start_worker)
        chief = s.registry.main
        lead = s.create_agent(dict(name='Lead', role='Coordinator'))['id']
        member = s.create_agent(dict(name='Researcher', role='Research'))['id']
        outsider = s.create_agent(dict(name='Outside', role='Other'))['id']
        group = s.groups.create(dict(name='Research Group', lead=lead, members=[lead, member]), chief)
        return s, chief, lead, member, outsider, group

    def until(self, condition):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(.01)
        self.fail('Group condition did not become true')

    def test_creation_introduces_purpose_roster_and_lead_without_dispatch(self):
        s, chief, lead, member, outsider, _ = self.setup_group()
        purpose = 'Review papers on {learning}, then maintain our research backlog.'
        group = s.orchestration.control(chief, dict(op='group_create', name='Paper team',
            description=purpose, lead=lead, members=[member, lead]))
        messages = group['messages']
        self.assertEqual([m['author'] for m in messages], ['admin', chief, lead])
        self.assertIn(purpose, messages[0]['text'])
        self.assertIn('@Lead', messages[1]['text'])
        self.assertIn('@Researcher', messages[1]['text'])
        self.assertNotIn('@Outside', messages[1]['text'])
        self.assertIn('I’m Lead, Lead of this group.', messages[2]['text'])
        self.assertEqual(len({m['id'] for m in messages}), 3)
        self.assertTrue(all(m['created'] and m['source'] == 'group-introduction' for m in messages))
        self.assertEqual(group['requests'], [])
        self.assertEqual(s.groups.get(group['id'])['messages'], messages)
        s.groups.chat.dispatch()
        self.assertEqual(s.snapshot()['turns'], [])
        s = self.restart(s, start_worker=False)
        self.assertEqual(s.groups.get(group['id'])['messages'], messages)
        changed = s.groups.update(group['id'], dict(revision=group['revision'], lead=member), chief)
        archived = s.groups.update(group['id'], dict(revision=changed['revision'], archived=True), chief)
        restored = s.groups.update(group['id'], dict(revision=archived['revision'], archived=False), chief)
        self.assertEqual(restored['messages'], messages)
        self.assertEqual(self.factory.prompts, [])

    def test_creation_without_purpose_has_a_short_fallback(self):
        s, chief, lead, member, outsider, group = self.setup_group()
        self.assertIn('Research Group', group['messages'][0]['text'])
        self.assertIn('define the first task', group['messages'][0]['text'])
        self.assertEqual(len(group['messages']), 3)

    def test_group_history_and_lead_memo_after_all_member_replies(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        folder = s.groups.folder(g['id'])
        original = '<section id="about">Our group</section><section id="map"></section><section id="content">Existing knowledge</section>'
        (folder / 'Notes.html').write_text(original)
        personal = {a: (s._agent(a).workspace / 'Notes.html').read_bytes() for a in (lead, member)}
        contexts = []
        base_spawn = self.factory.spawn
        def spawn(spec):
            llm = base_spawn(spec)
            def complete(text):
                self.factory.prompts.append(text)
                context = json.JSONDecoder().raw_decode(text.split('Current Group context:\n', 1)[1])[0]
                contexts.append((spec.role, context))
                if spec.role == 'group-memo':
                    self.assertEqual(context['self_id'], lead)
                    self.assertEqual(context['memo'], original)
                    self.assertTrue(any(m['text'] == 'Verified member finding' for m in context['messages']))
                    (folder / 'Notes.html').write_text(original.replace('Existing knowledge', 'Existing knowledge; Verified member finding'))
                    return 'Memo saved.'
                return '@Researcher investigate' if context['self_id'] == lead else 'Verified member finding'
            llm.complete = complete
            return llm
        self.factory.spawn = spawn
        s.groups.chat.submit(g['id'], dict(text='Investigate together'))
        s.start()
        self.until(lambda: any(r.get('memo') and r['settled'] for r in s.groups.get(g['id'])['requests']))
        self.until(lambda: not s._runners)
        group = s.groups.get(g['id'])
        self.assertEqual([role for role, _ in contexts], ['group', 'group', 'group-memo'])
        self.assertIn('Verified member finding', (folder / 'Notes.html').read_text())
        self.assertNotIn('Memo saved.', [m['text'] for m in group['messages']])
        self.assertEqual(len(group['messages']), 6)
        for agid in (lead, member):
            self.assertEqual(s._agent(agid).state['chat'], [])
            self.assertIsNone(s._agent(agid).state['last_output'])
            self.assertEqual((s._agent(agid).workspace / 'Notes.html').read_bytes(), personal[agid])
            self.assertEqual(s.delegation.task_list(agid)['tasks'], [])
        s = self.restart(s)
        s.groups.chat.reconcile()
        self.assertEqual(len(s.groups.get(g['id'])['requests']), 3)

    def test_member_addressed_admin_call_queues_current_lead_memo_durably(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        message = s.groups.chat.submit(g['id'], dict(text='@Researcher answer directly'))
        request = s.groups.get(g['id'])['requests'][0]
        agent = s._agent(member)
        # Run only the member; leave the Lead's follow-up queued across restart.
        import asyncio
        asyncio.run(agent.runner.run())
        s._sync(agent); s.groups.chat.reconcile()
        group = s.groups.get(g['id'])
        self.assertEqual(len(group['requests']), 2)
        followup = group['requests'][-1]
        self.assertTrue(followup['memo'])
        self.assertEqual(followup['root'], message['id'])
        self.assertEqual(followup['target'], lead)
        s = self.restart(s, start_worker=False)
        s.groups.chat.reconcile()
        self.assertEqual(len(s.groups.get(g['id'])['requests']), 2)
        group = s.groups.get(g['id'])
        s.groups.update(g['id'], dict(revision=group['revision'], lead=member), chief)
        s.groups.chat.dispatch()
        self.assertEqual(s.groups.get(g['id'])['requests'][-1]['target'], member)
        self.assertEqual(s._agent(member).state['chat'], [])

    def test_nonexclusive_membership_stable_identity_and_transfer(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        other = s.groups.create(dict(name='Second', lead=member, members=[lead, member]))
        self.assertEqual(len(s.groups.facts(member)), 2)
        for _ in range(3):
            self.assertEqual(s.groups.get(g['id'])['strip_order'], g['strip_order'])
        with self.assertRaises(APIError):
            s.groups.update(g['id'], dict(revision=g['revision'], lead=member), lead)
        changed = s.groups.update(g['id'], dict(revision=g['revision'], lead=member), chief)
        self.assertEqual(changed['strip_order'][0], member)
        self.assertEqual(changed['color'], g['color'])
        self.assertEqual(changed['id'], g['id'])
        with self.assertRaises(APIError):
            s.groups.update(g['id'], dict(revision=changed['revision'], members=[member, outsider]), lead)
        changed = s.groups.update(g['id'], dict(revision=changed['revision'], members=[member, outsider]), member)
        self.assertEqual(len(changed['members']), 2)
        s = self.restart(s, start_worker=False)
        self.assertEqual(s.groups.get(g['id'])['strip_order'], changed['strip_order'])
        self.assertEqual(s.groups.get(other['id'])['members'], [lead, member])

    def test_eleven_group_limit_create_join_restore_and_preferences(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        for i in range(10):
            s.groups.create(dict(name=f'Group {i}', lead=lead, members=[lead, member]))
        with self.assertRaisesRegex(APIError, '11 active Groups'):
            s.groups.create(dict(name='Twelfth', lead=lead, members=[lead, outsider]))
        other = s.groups.create(dict(name='Other', lead=chief, members=[chief, outsider]))
        with self.assertRaisesRegex(APIError, '11 active Groups'):
            s.groups.update(other['id'], dict(revision=other['revision'], members=[chief, outsider, member]), chief)
        archived = s.groups.update(g['id'], dict(revision=g['revision'], archived=True), chief)
        added = s.groups.create(dict(name='New slot', lead=lead, members=[lead, member]))
        with self.assertRaisesRegex(APIError, '11 active Groups'):
            s.groups.update(g['id'], dict(revision=archived['revision'], archived=False), chief)
        s.groups.update(added['id'], dict(revision=added['revision'], archived=True), chief)
        restored = s.groups.update(g['id'], dict(revision=archived['revision'], archived=False), chief)
        s.groups.update(g['id'], dict(revision=restored['revision'], description='Still editable'), lead)
        s.save_preferences(dict(groupView=g['id'], scope='groups', selected=member))
        self.assertEqual(s.snapshot()['preferences']['groupView'], g['id'])
        with self.assertRaises(APIError):
            s.save_preferences(dict(groupView='missing'))
        s.save_preferences(dict(groupView=None))

    def test_invalid_membership_and_permissions(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        for members in ([lead], [lead, lead], [member, outsider], [lead, 'missing']):
            with self.subTest(members=members), self.assertRaises(APIError):
                s.groups.create(dict(name='Invalid', lead=lead, members=members))
        with self.assertRaises(APIError):
            s.groups.create(dict(name='Forbidden', lead=lead, members=[lead, member]), member)
        with self.assertRaises(APIError):
            s.groups.work.create(g['id'], dict(title='No'), outsider)
        with self.assertRaises(APIError):
            s.groups.update(g['id'], dict(revision=g['revision'], archived=True), lead)
        with self.assertRaises(APIError):
            s.lifecycle.change(lead, True)
        with self.assertRaises(APIError):
            s.groups.work.create(g['id'], dict(title='No', assignee=outsider), lead)

    def test_default_lead_and_explicit_member_routing_with_private_chat_isolation(self):
        s, chief, lead, member, outsider, g = self.setup_group(start_worker=True)
        private = s.submit(lead, dict(text='PRIVATE PERSONAL CONTEXT'))
        self.wait_turn(s, private['id'])
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        s.groups.chat.submit(g['id'], dict(text='Hello Group'))
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 5)
        group = s.groups.get(g['id'])
        self.assertEqual(group['requests'][0]['target'], lead)
        self.assertEqual(group['messages'][4]['author'], lead)
        self.assertNotIn('PRIVATE PERSONAL CONTEXT', self.factory.prompts[-1])
        s.groups.chat.submit(g['id'], dict(text='@Researcher Please reply'))
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 7)
        self.assertEqual([r for r in s.groups.get(g['id'])['requests'] if not r.get('memo')][-1]['target'], member)
        self.assertEqual(s.groups.get(g['id'])['messages'][-1]['author'], member)
        self.assertTrue(all(t.get('group') == g['id'] for t in s.snapshot()['turns'] if t['id'] != private['id']))
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        personal = s.submit(lead, dict(text='Personal again'))
        self.wait_turn(s, personal['id'])
        self.assertNotIn('Hello Group', self.factory.prompts[-1])

    def test_lead_mentions_dispatch_once_and_members_do_not_ping_pong(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        base_spawn = self.factory.spawn
        def spawn(spec):
            llm = base_spawn(spec)
            llm.complete = lambda text: '@Researcher please contribute. @Lead FYI'
            return llm
        self.factory.spawn = spawn
        s.groups.chat.submit(g['id'], dict(text='Coordinate'))
        s.start()
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 6)
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        for _ in range(3):
            s.groups.chat.reconcile(); s.groups.chat.dispatch()
        group = s.groups.get(g['id'])
        self.assertEqual([r['target'] for r in group['requests'] if not r.get('memo')], [lead, member])
        self.assertEqual([m['author'] for m in group['messages'][3:]], ['admin', lead, member])

    def test_queued_group_requests_survive_restart_without_duplicate_execution(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        s.groups.chat.submit(g['id'], dict(text='First'))
        s.groups.chat.submit(g['id'], dict(text='Second'))
        self.assertEqual(len(s._agent(lead).state['turns']), 1)
        s = self.restart(s)
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 7)
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        self.assertEqual(len([p for p in self.factory.prompts if p.startswith('You are acting as yourself inside')]), 2)
        s = self.restart(s)
        self.assertEqual(len([p for p in self.factory.prompts if p.startswith('You are acting as yourself inside')]), 2)
        self.assertEqual(len(s.groups.get(g['id'])['messages']), 7)

    def test_autonomous_tasks_use_one_record_and_reject_stale_edits(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        task = s.groups.work.create(g['id'], dict(title='Research', assignee=member), member)
        changed = s.groups.work.update(g['id'], task['id'], dict(revision=1, title='Lead revision'), lead)
        self.assertEqual(s.groups.work.assigned(member)[0]['title'], 'Lead revision')
        with self.assertRaises(APIError):
            s.groups.work.update(g['id'], task['id'], dict(revision=1, title='Stale'), member)
        changed = s.groups.work.update(g['id'], task['id'], dict(revision=changed['revision'], deleted=True), lead)
        changed = s.groups.work.update(g['id'], task['id'], dict(revision=changed['revision'], deleted=False), member)
        self.assertEqual(changed['state'], 'backlog')
        self.assertEqual(len(changed['history']), 3)
        group = s.groups.get(g['id'])
        with self.assertRaises(APIError):
            s.groups.update(g['id'], dict(revision=group['revision'], members=[lead, outsider]))

    def test_lead_can_delete_during_execution_and_late_result_does_not_revive_task(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        gate = self.factory.gate = threading.Event()
        self.addCleanup(gate.set)
        task = s.groups.work.create(g['id'], dict(title='Original work', assignee=member), lead)
        running = s.groups.work.run(g['id'], task['id'], task['revision'], lead)
        s.start(); self.assertTrue(self.factory.started.wait(2))
        deleted = s.groups.work.update(g['id'], task['id'], dict(revision=running['revision'], deleted=True), lead)
        gate.set()
        self.until(lambda: bool(s.groups.get(g['id'])['tasks'][0]['results']))
        saved = s.groups.get(g['id'])['tasks'][0]
        self.assertTrue(saved['deleted'])
        self.assertEqual(saved['revision'], deleted['revision'])
        self.assertTrue(saved['results'][0]['stale'])
        self.assertTrue(s.groups.get(g['id'])['messages'][-1]['stale'])

    def test_successful_task_result_and_archive_restore_do_not_replay(self):
        s, chief, lead, member, outsider, g = self.setup_group(start_worker=True)
        task = s.groups.work.create(g['id'], dict(title='Complete', assignee=member), lead)
        s.groups.work.run(g['id'], task['id'], task['revision'], lead)
        self.until(lambda: s.groups.get(g['id'])['tasks'][0]['state'] == 'done')
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        group = s.groups.get(g['id'])
        group = s.groups.update(g['id'], dict(revision=group['revision'], archived=True), chief)
        group = s.groups.update(g['id'], dict(revision=group['revision'], archived=False), chief)
        s = self.restart(s)
        self.assertEqual(len([p for p in self.factory.prompts if p.startswith('You are acting as yourself inside')]), 1)
        self.assertEqual(s.groups.get(g['id'])['tasks'][0]['state'], 'done')

    def test_archive_cancels_pending_requests_and_preserves_history(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        s.groups.chat.submit(g['id'], dict(text='Pending'))
        s.groups.chat.submit(g['id'], dict(text='Waiting behind it'))
        group = s.groups.get(g['id'])
        s.groups.update(g['id'], dict(revision=group['revision'], archived=True), chief)
        s.start()
        self.until(lambda: all(r['status'] == 'cancelled' for r in s.snapshot()['groups'][0]['requests']))
        self.assertFalse(self.factory.started.is_set())
        group = s.groups.get(g['id'])
        s.groups.update(g['id'], dict(revision=group['revision'], archived=False), chief)
        self.assertEqual(len(s.groups.get(g['id'])['messages']), 5)

    def test_host_control_and_http_preferences_browser_and_validation(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        result = s.orchestration.control(member, dict(op='group_task_create', group=g['id'], title='Member initiative', assignee=lead))
        self.assertEqual(result['author'], member)
        with self.assertRaises(APIError):
            s.orchestration.control(member, dict(op='group_update', group=g['id'], revision=s.groups.get(g['id'])['revision'], lead=member))
        server = Server(0, s)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            def request(method, path, data=None, local=True):
                conn = HTTPConnection('127.0.0.1', server.server_port)
                conn.request(method, path, body=json.dumps(data) if data is not None else None,
                             headers={'Content-Type':'application/json', **({'X-Sapiens-Local':'1'} if local else {})})
                response=conn.getresponse(); status=response.status; body=json.loads(response.read()); conn.close()
                return status, body
            self.assertEqual(request('PUT', '/api/preferences', dict(selected=g['id'], panel='work', scope='groups'))[0], 200)
            self.assertEqual(request('POST', f"/api/groups/{g['id']}/control", dict(op='workspace_open', url='https://example.com'))[0], 200)
            self.assertEqual(request('GET', '/api/groups')[1]['groups'][0]['id'], g['id'])
            notes_url = f"/api/groups/{g['id']}/notes"
            self.assertEqual(request('GET', notes_url)[0], 409)
            folder = s.groups.folder(g['id'])
            memo = '<section id="about">Group memory</section><section id="map"></section><section id="content">Shared finding</section>'
            (folder / 'Notes.html').write_text(memo)
            self.assertEqual(request('GET', notes_url)[1]['content'], memo)
            info = request('GET', '/api/groups')[1]['groups'][0]['notes']
            self.assertEqual(info['workspace'], str(folder))
            self.assertNotEqual(info['revision'], 'missing')
            self.assertEqual(request('GET', '/api/groups/unknown/notes')[0], 404)
            self.assertEqual(request('GET', notes_url + '?image=../private.png')[0], 409)

            self.assertEqual(request('POST', f"/api/groups/{g['id']}/messages", dict(text='X'), False)[0], 403)
            self.assertEqual(request('POST', f"/api/groups/{g['id']}/messages", dict(text='X', target=outsider))[0], 400)
            self.assertEqual(request('POST', '/api/groups', dict(name='Bad', lead=lead, members=[lead]))[0], 400)
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_shared_attachments_and_workspace_stay_scoped_to_group(self):
        s, chief, lead, member, outsider, g = self.setup_group(start_worker=True)
        attachment = create_attachment(s, g['id'], dict(kind='link', value='https://example.com/reference'))
        other = s.groups.create(dict(name='Other', lead=lead, members=[lead, member]))
        with self.assertRaises(APIError):
            s.groups.chat.submit(other['id'], dict(text='Bad cross-group reference', attachments=[attachment['id']]))
        s.groups.chat.submit(g['id'], dict(text='', attachments=[attachment['id']]))
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 5)
        self.assertIn('https://example.com/reference', self.factory.prompts[-1])
        s.orchestration.control(member, dict(op='workspace_open', group=g['id'], url='https://example.com/shared'))
        self.assertEqual(s.workspace.summary(s._agent(member))['tabs'], [])
        self.assertEqual(s.orchestration.control(member, dict(op='workspace', group=g['id']))['tabs'][0]['url'], 'https://example.com/shared')
        with self.assertRaises(APIError):
            s.orchestration.control(outsider, dict(op='workspace_open', group=g['id'], url='https://example.com/forbidden'))

    def test_failed_group_call_can_be_retried_without_duplicate_messages(self):
        s, chief, lead, member, outsider, g = self.setup_group(start_worker=True)
        self.factory.fail = True
        s.groups.chat.submit(g['id'], dict(text='Try once'))
        self.until(lambda: s.groups.get(g['id'])['requests'][0]['status'] == 'failed')
        self.until(lambda: not s._runners and all(r['settled'] for r in s.groups.get(g['id'])['requests']))
        self.assertEqual(len(s.groups.get(g['id'])['messages']), 4)
        self.factory.fail = False
        rid = s.groups.get(g['id'])['requests'][0]['id']
        s.groups.chat.action(g['id'], rid, 'retry')
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 5)
        self.assertEqual(len([r for r in s.groups.get(g['id'])['requests'] if not r.get('memo')]), 1)
        self.assertEqual(len([p for p in self.factory.prompts if p.startswith('You are acting as yourself inside')]), 2)

    def test_transfer_during_call_preserves_author_and_new_calls_reach_new_lead(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        gate = self.factory.gate = threading.Event()
        self.addCleanup(gate.set)
        s.groups.chat.submit(g['id'], dict(text='Already accepted by old Lead'))
        s.start(); self.assertTrue(self.factory.started.wait(2))
        # Keep the revision read and transfer together while the background
        # dispatcher records that the gated call has started.
        with s._lock:
            group = s.groups.get(g['id'])
            s.groups.update(g['id'], dict(revision=group['revision'], lead=member), chief)
        gate.set()
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 5)
        self.assertEqual(s.groups.get(g['id'])['messages'][-1]['author'], lead)
        s.groups.chat.submit(g['id'], dict(text='For new Lead'))
        self.until(lambda: len(s.groups.get(g['id'])['messages']) == 7)
        self.assertEqual(s.groups.get(g['id'])['messages'][-1]['author'], member)

    def test_mentions_require_at_and_accept_sentence_punctuation(self):
        s, chief, lead, member, outsider, g = self.setup_group()
        self.assertEqual(s.groups.chat.mentions(g, 'Researcher is a member'), [])
        self.assertEqual(s.groups.chat.mentions(g, '@Researcher.'), [member])
        self.assertEqual(s.groups.chat.mentions(g, '@Researcher.extra'), [])

    @unittest.skipIf(sys.platform == 'win32', 'macOS updater')
    def test_desktop_update_waits_for_group_queue_without_a_projected_turn(self):
        self.assertTrue(busy(dict(turns=[], groups=[dict(requests=[dict(status='queued')])])))
        self.assertFalse(busy(dict(turns=[], groups=[dict(requests=[dict(status='done')])])) )
