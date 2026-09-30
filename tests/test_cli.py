"""CLI contracts against a loopback fixture, never the user's live CORPORA data."""
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import os
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from sapiens.corpora.host.cli import main, parse
from sapiens.corpora.host.cli_render import Renderer, clean, note_text
from sapiens.corpora.host.cli_transport import Client, ClientError


ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        server = self.server
        server.reads.append(self.path)
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{server.server_port}/api/state')
            self.end_headers()
            return
        if self.path == '/api/state':
            value = server.state
        elif self.path == '/api/health':
            value = {'status': 'ok'}
        elif self.path.endswith('/tasks?format=json'):
            value = {'tasks': [dict(id='work1', title='Real fixture objective', state='Completed',
                owner='chief-id', body='objective: Real fixture objective\n', result='Evidence', error=None)]}
        elif self.path.endswith('/notes'):
            value = {'path': '/fixture/Notes.html', 'content': '<section><h1>Memo</h1><p>Saved fact</p></section>'}
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.writes.append((self.path, data, self.headers.get('X-Sapiens-Local')))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'id': 'turn1', 'agent': 'chief-id', 'status': 'queued'}).encode())


class CLITest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.reads, self.server.writes = [], []
        self.server.state = {'agents': [dict(id='chief-id', name='Chief', role='Head', face='◕ᵕ◕', retired=False),
                                       dict(id='other-id', name='Researcher', role='Research', face='^‿^', retired=True)],
            'main_agent_id': 'chief-id', 'provider': 'codex', 'computer': {'built': True},
            'turns': [dict(id='turn1', agent='chief-id', status='done', input='Question', output='Answer',
                          created='2026-10-01T00:00:00Z', error=None)], 'workloads': []}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = main(['--url', self.url, *args])
        return code, out.getvalue(), err.getvalue()

    def test_live_projection_and_retired_filter(self):
        code, text, _ = self.run_cli('status', '--format', 'json')
        data = json.loads(text)
        self.assertEqual(code, 0)
        self.assertEqual(data['data']['active_sapis'], 1)
        self.assertEqual(data['data']['retired_sapis'], 1)
        _, text, _ = self.run_cli('sapi', 'list', '--format', 'json')
        self.assertEqual(len(json.loads(text)['data']['sapis']), 1)
        self.assertEqual(self.server.writes, [])
        _, human, _ = self.run_cli('sapi', 'list')
        self.assertIn('(◕ᵕ◕) Chief', human)

    def test_task_yaml_and_scope(self):
        code, text, _ = self.run_cli('task', 'show', 'work1', '--sapi', 'all', '--format', 'yaml')
        self.assertEqual((code, text), (0, 'objective: Real fixture objective\n'))
        self.assertNotIn('/api/agents/other-id/tasks?format=json', self.server.reads)

    def test_history_and_memo(self):
        _, text, _ = self.run_cli('history', '--limit', '1')
        self.assertIn('You: Question', text)
        self.assertIn('(◕ᵕ◕) Chief: Answer', text)
        _, text, _ = self.run_cli('memo', 'show')
        self.assertIn('Saved fact', text)
        self.assertNotIn('<section>', text)

    def test_clarification_submits_once_with_exact_binding(self):
        code, text, _ = self.run_cli('chat', 'My answer', '--workload', 'work1', '--format', 'json')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(text)['data']['id'], 'turn1')
        self.assertEqual(self.server.writes, [('/api/agents/chief-id/messages',
            {'text': 'My answer', 'flow': 'chat', 'workload': 'work1'}, '1')])

    def test_wait_outputs_one_json_response(self):
        code, text, err = self.run_cli('chat', 'Hello', '--wait', '--format', 'json')
        self.assertEqual(code, 0)
        self.assertEqual(len(text.splitlines()), 1)
        self.assertEqual(json.loads(text)['data']['output'], 'Answer')
        self.assertNotIn('\x1b', text + err)
        self.assertEqual(len(self.server.writes), 1)

    def test_waiting_workload_overrides_completed_origin_turn(self):
        self.server.state['workloads'] = [dict(id='work1', origin={'call': 'turn1'}, callId='child',
            owner='other-id', state='WaitingForAdmin', output='Which release?', error=None)]
        code, text, _ = self.run_cli('conversation', 'watch', 'turn1', '--format', 'json')
        self.assertEqual(code, 5)
        data = json.loads(text)['data']
        self.assertEqual(data['workload'], 'work1')
        self.assertEqual(data['output'], 'Which release?')
        self.assertEqual(self.server.reads, ['/api/state'])

    def test_failed_watch_uses_error_envelope(self):
        self.server.state['turns'][0].update(status='failed', error='Provider failed')
        code, text, _ = self.run_cli('conversation', 'watch', 'turn1', '--format', 'json')
        self.assertEqual(code, 1)
        result = json.loads(text)
        self.assertFalse(result['ok'])
        self.assertEqual(result['data']['id'], 'turn1')

    def test_jsonl_timeout_and_no_ansi_when_redirected(self):
        code, text, err = self.run_cli('status', '--watch', '--timeout', '.02', '--format', 'jsonl')
        events = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(code, 4)
        self.assertEqual([e['event'] for e in events], ['snapshot', 'timeout'])
        self.assertEqual([e['seq'] for e in events], [1, 2])
        self.assertNotIn('\x1b', text + err)

    def test_interrupt_does_not_cancel(self):
        with patch('sapiens.corpora.host.cli.time.sleep', side_effect=KeyboardInterrupt):
            code, text, _ = self.run_cli('status', '--watch', '--format', 'json')
        self.assertEqual(code, 130)
        self.assertEqual(json.loads(text)['error']['code'], 'DETACHED')
        self.assertEqual(self.server.writes, [])

    def test_invalid_commands_and_formats_do_not_touch_host(self):
        parse(['status', '--watch'], selected='Researcher')
        fresh = parse(['status'])
        self.assertFalse(fresh.watch)
        self.assertEqual(fresh.sapi, 'chief')
        for args in [('sapi', 'create'), ('status', '--format', 'jsonl'), ('status', '--timeout', 'nan'),
                     ('history', '--limit', '0'), ('memo', 'show', '--format', 'yaml')]:
            code, _, _ = self.run_cli(*args)
            self.assertEqual(code, 2, args)
        self.assertEqual(self.server.reads, [])
        code, text, _ = self.run_cli('unknown', '--format', 'json')
        self.assertFalse(json.loads(text)['ok'])

    def test_remote_urls_and_ambiguous_names_rejected(self):
        for url in ['https://example.com', 'http://127.0.0.1:80@evil.test:80',
                    'http://127.0.0.1:80/path', 'http://127.0.0.1:99999']:
            with self.assertRaises(ClientError):
                Client(url)
        self.server.state['agents'][1]['name'] = 'Chief'
        with self.assertRaises(ClientError):
            Client(self.url).agent(self.server.state, 'Chief')

    def test_ambiguous_write_is_not_retried(self):
        client = Client(self.url)
        with patch.object(client.opener, 'open', side_effect=TimeoutError) as opened:
            with self.assertRaises(ClientError) as caught:
                client.request('/api/agents/chief-id/messages', {'text': 'Hello'})
        self.assertEqual(caught.exception.code, 'SUBMISSION_UNCERTAIN')
        self.assertEqual(opened.call_count, 1)

    def test_offline_read(self):
        client = Client(self.url)
        with patch.object(client.opener, 'open', side_effect=ConnectionRefusedError):
            with self.assertRaises(ClientError) as caught:
                client.state()
        self.assertEqual(caught.exception.exit_code, 3)

    def test_terminal_control_sequences_are_removed(self):
        self.assertEqual(clean('\x1b[2Jhello\x1b]0;title\x07\x00\x9b'), 'hello')
        self.assertEqual(note_text('<script>bad()</script><p>Good &amp; saved</p>'), 'Good & saved')
        _, text, _ = self.run_cli('sapi', 'list', '--plain')
        text.encode('ascii')

    def test_actual_entrypoint_and_shell_selection(self):
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            input='use Researcher\nhistory --limit 1\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected Researcher', result.stdout)
        self.assertIn('(^‿^) Researcher >', result.stdout)
        self.assertIn('No conversations yet.', result.stdout)
        self.assertEqual(self.server.writes, [])


    def test_all_command_forms_and_global_option_positions(self):
        commands = [('sapis',), ('sapi', 'show', 'chief-id'), ('sapi', 'list', '--all'),
                    ('tasks', '--tab', 'past'), ('doctor',), ('help',)]
        for command in commands:
            with self.subTest(command=command):
                code, text, _ = self.run_cli('--format=json', *command, '--sapi', 'Chief')
                self.assertEqual(code, 0)
                self.assertTrue(json.loads(text)['ok'])
        for action in ('retry', 'cancel'):
            code, _, _ = self.run_cli('conversation', action, 'turn1')
            self.assertEqual(code, 0)
            self.assertEqual(self.server.writes[-1], (f'/api/agents/chief-id/turns/turn1/{action}', {}, '1'))

    def test_parser_rejects_unknown_options_without_sending(self):
        for command in [('chat', '--typo'), ('chat', '-typo'), ('status', '--wait'), ('sapi', 'list', '--tab', 'past')]:
            code, _, _ = self.run_cli(*command)
            self.assertEqual(code, 2, command)
        self.assertEqual(self.server.writes, [])
        code, _, _ = self.run_cli('chat', '--', '--literal-message')
        self.assertEqual(code, 0)
        self.assertEqual(self.server.writes[-1][1]['text'], '--literal-message')

    def test_prompt_inherits_options_and_only_shows_about_and_stats(self):
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url, '--plain'],
            input='sapis\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        intro = result.stdout.split('Chief >')[0]
        self.assertIn('ABOUT', intro)
        self.assertIn('STATS', intro)
        self.assertNotIn('Question', intro)
        self.assertNotIn('SAPIS', intro)
        self.assertNotIn('/tasks?format=json', ' '.join(self.server.reads))
        self.assertNotIn('(◕ᵕ◕)', result.stdout)
        result.stdout.encode('ascii')

    def test_animation_keeps_identity_and_obeys_no_animation(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        with patch.dict(os.environ, {}, clear=True):
            renderer = Renderer(stdout=io.StringIO(), stderr=stream)
            for frame, status in enumerate(('queued', 'running')):
                renderer.tick(status, frame, frame, self.server.state['agents'][0])
            renderer.clear()
            before = stream.getvalue()
            Renderer(animation=False, stderr=stream).tick('running', 0, 0)
        self.assertEqual(stream.getvalue(), before)
        self.assertEqual(before.count('(◕ᵕ◕)'), 2)
        self.assertIn('queued', before)
        self.assertIn('running', before)

    def test_http_errors_invalid_json_and_redirects_do_not_resubmit(self):
        from_error = io.BytesIO(b'{"error":"Rejected by host"}')
        client = Client(self.url)
        with patch.object(client.opener, 'open', side_effect=HTTPError(self.url, 409, 'Conflict', {}, from_error)) as opened:
            with self.assertRaises(ClientError) as caught:
                client.request('/api/agents/chief-id/messages', {'text': 'Once'})
        self.assertEqual(caught.exception.code, 'HTTP_409')
        self.assertEqual(opened.call_count, 1)
        with patch.object(client.opener, 'open', return_value=io.BytesIO(b'not json')):
            with self.assertRaises(ClientError) as caught:
                client.request('/api/agents/chief-id/messages', {'text': 'Once'})
        self.assertIn('may have been accepted', str(caught.exception))
        with self.assertRaises(ClientError) as caught:
            client.request('/redirect')
        self.assertEqual(caught.exception.code, 'HTTP_302')
        self.assertEqual(self.server.reads, ['/redirect'])


if __name__ == '__main__':
    unittest.main()
