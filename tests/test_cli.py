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

    def test_watch_follows_server_past_old_timeouts_without_its_own_deadline(self):
        turn = self.server.state['turns'][0]
        turn['status'] = 'running'
        with patch('sapiens.corpora.host.cli.time.monotonic', side_effect=[0, 1900, 1901, 1902, 1903]), \
             patch('sapiens.corpora.host.cli.time.sleep', side_effect=lambda _: turn.update(status='done')):
            code, text, err = self.run_cli('conversation', 'watch', 'turn1', '--format', 'jsonl')
        events = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(code, 0)
        self.assertEqual([e['event'] for e in events], ['snapshot', 'state_changed'])
        self.assertEqual([e['data']['state'] for e in events], ['running', 'done'])
        self.assertNotIn('\x1b', text + err)
        self.assertEqual(self.server.writes, [])

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
            input='call @Researcher\nchat -1\ncorpora\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('(^‿^) Researcher · Research', result.stdout)
        self.assertIn('sapiens4 ⌘ @Researcher >', result.stdout)
        self.assertEqual(result.stdout.count('>> sapiens4 ⌘ corpora >'), 2)
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
        intro = result.stdout.split('>> sapiens4::corpora >')[0]
        self.assertIn('ABOUT', intro)
        self.assertIn('STATS', intro)
        self.assertNotIn('Question', intro)
        self.assertNotIn('SAPIS', intro)
        self.assertNotIn('/tasks?format=json', ' '.join(self.server.reads))
        self.assertNotIn('(◕ᵕ◕)', result.stdout)
        result.stdout.encode('ascii')

    def test_show_tree_and_inspect_preserve_context(self):
        self.server.state['agents'][1]['retired'] = False
        self.server.state['agents'].reverse()  # Chief is first even when snapshot order differs.
        self.server.state['orchestration'] = {'chief-id': {'notes': {'path': '/fixture/workspaces/chief-id/Notes.html'}}}
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            input='show\nshow @Chief\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn('corpora\n├── *(◕ᵕ◕) Chief · Head\n└── (^‿^) Researcher · Research', result.stdout)
        self.assertIn('id: chief-id\nworkspace: /fixture/workspaces/chief-id', result.stdout)
        self.assertEqual(result.stdout.count('>> sapiens4 ⌘ corpora >'), 3)
        self.assertNotIn('sapiens4 ⌘ @', result.stdout)
        self.assertEqual(self.server.writes, [])

    def test_sapi_text_preserves_quotes_and_option_like_content(self):
        message = "Don't change  'quotes' or --format=json or @Researcher."
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            input='call @Chief\n' + message + '\ncorpora\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.writes, [('/api/agents/chief-id/messages', {'text': message, 'flow': 'chat'}, '1')])
        self.assertIn('Answer', result.stdout)
        self.assertEqual(result.stdout.count('>> sapiens4 ⌘ corpora >'), 2)
        self.assertIn('sapiens4 ⌘ @Chief >', result.stdout)
        self.assertNotIn('Type a message', result.stdout)

    def test_chat_reads_individual_messages_in_order_and_never_sends(self):
        self.server.state['turns'] = [dict(id=f'turn{i}', agent='chief-id', status='done',
            input=f'Question{i}', output=f'Answer{i}', created=str(i), error=None) for i in (3, 1, 2)]
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            input='chat @Chief -5\ncall @Researcher\nchat\ncorpora\nexit\n', capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('Question1', result.stdout)
        messages = ['Answer1', 'Question2', 'Answer2', 'Question3', 'Answer3']
        offsets = [result.stdout.index(text) for text in messages]
        self.assertEqual(offsets, sorted(offsets))
        self.assertIn('No conversations yet.', result.stdout)
        self.assertEqual(self.server.writes, [])

    def test_bad_navigation_and_history_stay_local(self):
        result = subprocess.run([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            input='call @Unknown\ncall Chief\nchat\ncall @Chief\nchat -0\nchat -bad\nhelp\ncorpora\nsapiens4\nexit\n',
            capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Expected one Sapi matching', result.stdout)
        self.assertIn('Use call @name', result.stdout)
        self.assertIn('chat [-5]', result.stdout)
        self.assertEqual(self.server.writes, [])

    def test_prompt_palette_and_highlights_identity(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        with patch.dict(os.environ, {'TERM': 'xterm-256color'}, clear=True):
            renderer = Renderer(stdout=stream)
            prompt = renderer.prompt({'name': 'ready\x1b[2J\n'})
            gray, pink, green, reset = '\x1b[38;2;185;176;189m', '\x1b[38;2;255;90;165m', '\x1b[38;2;217;233;184m', '\x1b[0m'
            self.assertEqual(renderer.prompt(), gray + '>> ' + reset + pink + 'sapiens4' + reset + gray + ' ⌘ ' + reset + green + 'corpora' + reset + gray + ' > ' + reset)
            self.assertEqual(clean(prompt), 'sapiens4 ⌘ @ready > ')
            self.assertIn(gray + ' ⌘ ' + reset + '@ready', prompt)
            self.assertNotIn('\x1b[32mready', prompt)
            for variable, value in [('NO_COLOR', ''), ('TERM', 'dumb')]:
                with patch.dict(os.environ, {variable: value}):
                    self.assertEqual(renderer.prompt(), '>> sapiens4 ⌘ corpora > ')
            renderer.text(renderer.sapis([dict(self.server.state['agents'][0], chief=True, state='ready',
                details={}, workspace='/fixture/workspaces/chief-id')]))
        self.assertIn('\x1b[38;2;167;189;182mchief-id\x1b[0m', stream.getvalue())
        self.assertEqual(Renderer(stdout=io.StringIO()).prompt(), '>> sapiens4 ⌘ corpora > ')
        self.assertEqual(Renderer(stdout=io.StringIO(), plain=True).prompt(), '>> sapiens4::corpora > ')

    def test_tab_completes_live_active_names_without_sending(self):
        self.server.state['agents'] += [dict(id='pink-id', name='PINK-SapiTheChief', retired=False),
            dict(id='proof-id', name='Proof Reader', retired=False)]
        def enter(renderer, agent, history, complete):
            if agent:
                self.assertEqual(history, [])
                self.assertEqual(complete('call @P'), [])
                self.assertEqual(complete('Message to @P'), [])
                self.assertEqual(complete('chat @P'), ['chat @PINK-SapiTheChief', 'chat @Publisher'])
                return 'exit'
            self.assertEqual(complete('call @pi'), ['call @PINK-SapiTheChief'])
            self.assertEqual(complete('show @P'), ['show @PINK-SapiTheChief', "show @'Proof Reader'"])
            self.assertEqual(complete('call @R'), [])
            self.assertEqual(complete('chat @'), ['chat @Chief', 'chat @PINK-SapiTheChief', "chat @'Proof Reader'"])
            self.assertEqual(complete('sapiens4 call @Pi'), ['sapiens4 call @PINK-SapiTheChief'])
            self.assertEqual(complete('status @P'), [])
            self.server.state['agents'][-1]['name'] = 'Publisher'
            self.assertEqual(complete('call @Pu'), ['call @Publisher'])
            with patch.object(Client, 'state', side_effect=ClientError('HOST_UNAVAILABLE', 'offline')):
                self.assertEqual(complete('call @P'), [])
            return 'call @Chief'
        with patch.object(Renderer, 'read', autospec=True, side_effect=enter):
            self.assertEqual(self.run_cli('shell')[0], 0)
        self.assertEqual(self.server.writes, [])

    @unittest.skipUnless(os.name == 'posix', 'Requires a POSIX terminal')
    def test_terminal_arrows_restore_drafts_and_keep_context_history(self):
        import fcntl, pty, select, struct, termios, time
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        process = subprocess.Popen([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            env=dict(os.environ, TERM='xterm-256color', PYTHONIOENCODING='utf-8', PROMPT_TOOLKIT_NO_CPR='1'))
        os.close(slave)
        pending = b''
        def expect(*texts):
            nonlocal pending
            deadline = time.monotonic() + 5
            while not all(text.rstrip() in clean(pending.decode(errors='replace')) for text in texts):
                self.assertLess(time.monotonic(), deadline, pending.decode(errors='replace'))
                if select.select([master], [], [], .1)[0]:
                    pending += os.read(master, 65536)
            pending = b''
        try:
            expect('>> sapiens4 ⌘ corpora > ')
            os.write(master, b'show\n'); expect('Chief · Head', '>> sapiens4 ⌘ corpora > ')
            os.write(master, b'status\n'); expect('corpora | online', '>> sapiens4 ⌘ corpora > ')
            os.write(master, b'\x1b[A\x1b[A\n')
            expect('Chief · Head', '>> sapiens4 ⌘ corpora > ')
            os.write(master, b'stat\x1bOA\x1bOBus\n')
            expect('corpora | online', '>> sapiens4 ⌘ corpora > ')  # Down restores the original "stat" draft.
            os.write(master, b'call @Ch\t\n')
            expect('sapiens4 ⌘ @Chief > ')
            os.write(master, b'Review this once.\n')
            expect('Answer', 'sapiens4 ⌘ @Chief > ')
            os.write(master, b'\x1b[A\x1b[B\nchat -1\n')
            expect('Chief: Answer', 'sapiens4 ⌘ @Chief > ')
            os.write(master, b'corpora\n')
            expect('>> sapiens4 ⌘ corpora > ')
            os.write(master, b'\x1b[A\n')  # Corpora history returns "call @Chief".
            expect('sapiens4 ⌘ @Chief > ')
            os.write(master, b'\x1b[A\x1b[A\n')  # Sapi history returns "chat -1".
            expect('Chief: Answer', 'sapiens4 ⌘ @Chief > ')
            os.write(master, b'exit\n')
            expect('Detached.')
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(self.server.writes, [('/api/agents/chief-id/messages',
                {'text': 'Review this once.', 'flow': 'chat'}, '1')])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)

    @unittest.skipUnless(os.name == 'posix', 'Requires a POSIX terminal')
    def test_repeated_arrows_preserve_colored_prompt_on_narrow_screen(self):
        import codecs, fcntl, pty, pyte, select, struct, termios, time
        width = 50
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        environment = dict(os.environ, TERM='xterm-256color', PYTHONIOENCODING='utf-8', PROMPT_TOOLKIT_NO_CPR='1')
        environment.pop('NO_COLOR', None)
        self.server.state['agents'][0]['name'] = 'PINK-SapiTheChief'
        process = subprocess.Popen([sys.executable, str(ROOT / 'sapiens4'), 'shell', '--url', self.url],
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True, env=environment)
        os.close(slave)
        screen = pyte.Screen(width, 24)
        stream, decoder = pyte.Stream(screen), codecs.getincrementaldecoder('utf-8')()
        prompt = '>> sapiens4 ⌘ corpora > '
        def expect_input(value):
            target = prompt + value
            deadline = time.monotonic() + 5
            while True:
                self.assertLess(time.monotonic(), deadline, '\n'.join(screen.display))
                if select.select([master], [], [], .1)[0]:
                    stream.feed(decoder.decode(os.read(master, 65536)))
                count = len(target) // width + 1
                end = screen.cursor.y
                rows = screen.display[max(0, end - count + 1):end + 1]
                if ''.join(rows).rstrip() == target.rstrip():
                    start = end - count + 1
                    self.assertEqual(screen.buffer[start][3].fg, 'ff5aa5')
                    self.assertEqual(screen.buffer[start][14].fg, 'd9e9b8')
                    self.assertEqual(screen.buffer[start][12].fg, 'b9b0bd')
                    return
        try:
            expect_input('')
            commands = ['show', 'chat @PINK-SapiTheChief -5', 'show @PINK-SapiTheChief', 'help']
            for command in commands:
                os.write(master, command.encode()); expect_input(command)
                os.write(master, b'\n'); expect_input('')
            for command in reversed(commands):
                os.write(master, b'\x1b[A'); expect_input(command)
            for command in commands[1:] + ['']:
                os.write(master, b'\x1b[B'); expect_input(command)
            # Repeat the user's exact sequence, then edit the recalled line.
            os.write(master, b'\x1b[A\x1b[A\x1b[A'); expect_input(commands[1])
            os.write(master, b'\x01\x0bexit'); expect_input('exit')
            os.write(master, b'\n')
            deadline = time.monotonic() + 5
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try: os.read(master, 65536)
                    except OSError: break
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(self.server.writes, [])
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
            os.close(master)

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


    def test_terminal_colors_use_saved_palette_after_sanitizing(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        agent = dict(self.server.state['agents'][0], color='#f7d6d1')
        with patch.dict(os.environ, {'TERM': 'xterm-256color'}, clear=True):
            renderer = Renderer(stdout=stream)
            renderer.text(renderer.avatar(agent) + 'Chief | ready\x1b[2J')
        output = stream.getvalue()
        self.assertIn('\x1b[48;2;247;214;209;38;2;39;33;55m(◕ᵕ◕)\x1b[0m', output)
        self.assertIn('\x1b[32mready\x1b[0m', output)
        self.assertNotIn('\x1b[2J', output)
        self.assertEqual(clean(output), '(◕ᵕ◕) Chief | ready\n')

    def test_colors_are_disabled_for_plain_pipes_machine_and_no_color(self):
        agent = dict(self.server.state['agents'][0], color='#f7d6d1')
        for environment, plain, format, tty in [({'NO_COLOR': ''}, False, 'human', True),
                ({'TERM': 'dumb'}, False, 'human', True), ({}, True, 'human', True),
                ({}, False, 'human', False), ({}, False, 'json', True), ({}, False, 'jsonl', True)]:
            with self.subTest(environment=environment, plain=plain, format=format, tty=tty):
                stream = io.StringIO()
                stream.isatty = lambda: tty
                with patch.dict(os.environ, environment, clear=True):
                    renderer = Renderer(format=format, plain=plain, stdout=stream)
                    renderer.emit({'state': 'ready'}, renderer.avatar(agent) + 'ready')
                self.assertNotIn('\x1b', stream.getvalue())


if __name__ == '__main__':
    unittest.main()
