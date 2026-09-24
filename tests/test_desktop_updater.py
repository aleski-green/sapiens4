"""Release switching must preserve state and hold jobs until startup is verified."""
import importlib.util
import json
from pathlib import Path
import tempfile
import socket
import sys
import time
import urllib.request
import urllib.error
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location('desktop_updater', Path(__file__).resolve().parents[1] / 'macos/updater.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class DesktopUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.data = self.home / 'data'
        self.data.mkdir()
        (self.data / 'agent.txt').write_text('original')
        self.old = dict(root='/old', sha='a' * 40)
        self.new = dict(root='/new', sha='b' * 40)
        updater.atomic(self.home / 'config.json', dict(data=str(self.data), legacy_root='/dev'))
        updater.atomic(self.home / 'current.json', self.old)
        self.manager = updater.Manager(self.home)

    @unittest.skipUnless(sys.platform == "darwin", "macOS bundle exchange")
    def test_bundle_exchange_preserves_previous_app(self):
        staged, installed = self.home / 'new.app', self.home / 'installed.app'
        staged.mkdir(); installed.mkdir()
        (staged / 'version').write_text('new')
        (installed / 'version').write_text('old')
        self.assertTrue(updater.replace_app(staged, installed))
        self.assertEqual((installed / 'version').read_text(), 'new')
        self.assertEqual((staged / 'version').read_text(), 'old')

    def test_real_server_holds_jobs_and_requests_until_activation(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.manager.config['port'] = port
        updater.atomic(self.home / 'config.json', self.manager.config)
        release = dict(root=str(Path(__file__).resolve().parents[1]), sha='a' * 40)
        with patch.object(updater, 'BASE', f'http://127.0.0.1:{port}'):
            proc, activation = self.manager.spawn(release, paused=True)
            try:
                self.assertFalse(updater.request('/api/health')['desktop_active'])
                with self.assertRaises(urllib.error.HTTPError) as error:
                    updater.request('/api/state')
                self.assertEqual(error.exception.code, 503)
                activation.touch()
                for _ in range(50):
                    if updater.request('/api/health')['desktop_active']:
                        break
                    time.sleep(0.1)
                self.assertTrue(updater.request('/api/health')['desktop_active'])
                self.assertEqual(len(updater.request('/api/state')['agents']), 1)
            finally:
                proc.terminate()
                proc.wait(timeout=15)

    def test_check_only_notifies_without_changing_release(self):
        with patch.object(updater, 'command', return_value='b' * 40 + '\trefs/heads/main'):
            self.manager.check()
        self.assertEqual(self.manager.current(), self.old)
        self.assertEqual(json.loads(self.manager.status_file.read_text())['phase'], 'available')

    def test_bad_remote_revision_rejected(self):
        with patch.object(updater, 'command', return_value='invalid refs/heads/main'):
            with self.assertRaises(RuntimeError):
                self.manager.check()
        self.assertEqual(self.manager.current(), self.old)

    def test_busy_includes_queued_and_computer_work(self):
        self.assertTrue(updater.busy({'jobs': [{'status': 'queued'}]}))
        self.assertTrue(updater.busy({'computer': {'owner': 'agent'}}))
        self.assertFalse(updater.busy({'jobs': [{'status': 'done'}]}))

    def test_success_backs_up_and_activates_after_commit(self):
        activation = self.home / 'activate-test'
        def spawn(release, paused=False):
            self.assertTrue(paused)
            self.assertFalse(activation.exists())
            self.assertEqual(self.manager.current(), self.old)
            self.assertTrue(list((self.home / 'backups').glob('*/agent.txt')))
            return Mock(), activation
        with patch.object(self.manager, 'check', return_value=self.new['sha']), patch.object(self.manager, 'prepare', return_value=self.new), patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn', side_effect=spawn):
            self.manager.update()
        self.assertTrue(activation.exists())
        self.assertEqual(self.manager.current(), self.new)
        self.assertEqual((self.data / 'agent.txt').read_text(), 'original')
        self.assertFalse((self.home / 'transaction.json').exists())

    def test_failed_start_restores_data_and_old_release(self):
        def spawn(release, paused=False):
            if release == self.new:
                (self.data / 'agent.txt').write_text('migration')
                raise RuntimeError('startup failed')
            self.assertEqual((self.data / 'agent.txt').read_text(), 'original')
            return Mock(), self.home / 'activation'
        with patch.object(self.manager, 'check', return_value=self.new['sha']), patch.object(self.manager, 'prepare', return_value=self.new), patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn', side_effect=spawn):
            with self.assertRaisesRegex(RuntimeError, 'startup failed'):
                self.manager.update()
        self.assertEqual(self.manager.current(), self.old)
        self.assertEqual((self.data / 'agent.txt').read_text(), 'original')
        self.assertTrue(list((self.home / 'backups').glob('failed-*/agent.txt')))

    def test_committed_recovery_never_restores_old_data(self):
        activation = self.home / 'activate-test'
        updater.atomic(self.home / 'transaction.json', dict(committed=True, activation=str(activation)))
        self.manager.recover()
        self.assertTrue(activation.exists())
        self.assertEqual((self.data / 'agent.txt').read_text(), 'original')

    def test_waits_for_work_before_stopping(self):
        activation = self.home / 'activate-test'
        with patch.object(self.manager, 'check', return_value=self.new['sha']), patch.object(self.manager, 'prepare', return_value=self.new), patch.object(updater, 'healthy', return_value=True), patch.object(updater, 'request', side_effect=[{'jobs': [{'status': 'running'}]}, {'jobs': []}]), patch.object(updater.time, 'sleep') as sleep, patch.object(self.manager, 'stop') as stop, patch.object(self.manager, 'spawn', return_value=(Mock(), activation)):
            self.manager.update()
        sleep.assert_called_once_with(10)
        stop.assert_called_once()

    def test_unrelated_server_never_signalled(self):
        with patch.object(updater.subprocess, 'run', return_value=Mock(stdout='123\n')), patch.object(updater, 'command', side_effect=['python -m other', 'n/unrelated']), patch.object(updater.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'not owned'):
                self.manager.stop()
            kill.assert_not_called()

    def test_build_failure_leaves_server_running(self):
        with patch.object(self.manager, 'check', return_value=self.new['sha']), patch.object(self.manager, 'prepare', side_effect=RuntimeError('build failed')), patch.object(self.manager, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                self.manager.update()
            stop.assert_not_called()
        self.assertEqual(self.manager.current(), self.old)

if __name__ == '__main__':
    unittest.main()
