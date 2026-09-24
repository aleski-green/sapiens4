"""Release switching must preserve state and hold jobs until startup is verified."""
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
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

    def test_sdk_probe_skips_incompatible_sdk(self):
        selected = self.home / 'MacOSX26.sdk'
        compatible = self.home / 'MacOSX15.sdk'
        selected.mkdir(); compatible.mkdir()
        with patch.object(updater, 'command', return_value=str(selected)), patch.object(updater.subprocess, 'run', side_effect=[Mock(returncode=1), Mock(returncode=0)]) as run:
            env = updater.swift_environment()
        self.assertEqual(env['SDKROOT'], str(compatible.resolve()))
        self.assertEqual(run.call_count, 2)

    def test_sdk_probe_reports_repair_when_no_sdk_works(self):
        selected = self.home / 'MacOSX26.sdk'
        selected.mkdir()
        with patch.object(updater, 'command', return_value=str(selected)), patch.object(updater.subprocess, 'run', return_value=Mock(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, 'Repair or reinstall'):
                updater.swift_environment()

    def test_swiftpm_loader_failure_uses_direct_compiler_and_self_test(self):
        package = self.home / 'blindly4'
        package.mkdir()
        original = Path(__file__).resolve().parents[1] / 'blindly4/Package.swift'
        shutil.copy2(original, package / 'Package.swift')
        failure = Mock(returncode=1, stderr='dyld: Symbol not found: llbuild', stdout='')
        with patch.object(updater.subprocess, 'run', side_effect=[failure, Mock(returncode=0)]) as run, patch.object(updater, 'command') as command:
            updater.build_blindly(self.home, {'SDKROOT': '/compatible.sdk'})
        self.assertEqual(run.call_args_list[1].args[0][:4], ['xcrun', 'swiftc', '-sdk', '/compatible.sdk'])
        command.assert_called_once_with([str(package / '.build/release/blindly4'), '--self-test'])

    def test_source_errors_and_complex_packages_do_not_use_fallback(self):
        package = self.home / 'blindly4'
        package.mkdir()
        original = Path(__file__).resolve().parents[1] / 'blindly4/Package.swift'
        for error, manifest in [('source compilation error', original.read_text()),
                                ('Symbol not found: llbuild', 'import PackageDescription\n// different package')]:
            with self.subTest(error=error):
                (package / 'Package.swift').write_text(manifest)
                with patch.object(updater.subprocess, 'run', return_value=Mock(returncode=1, stderr=error, stdout='')) as run:
                    with self.assertRaises(RuntimeError):
                        updater.build_blindly(self.home, {'SDKROOT': '/compatible.sdk'})
                self.assertEqual(run.call_count, 1)

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

    def test_crash_after_rollback_restart_preserves_new_work(self):
        backup = self.home / 'backups/original'
        shutil.copytree(self.data, backup)
        updater.atomic(self.home / 'current.json', self.new)
        updater.atomic(self.home / 'transaction.json', dict(
            old=self.old, new=self.new, backup=str(backup), committed=False))
        (self.data / 'agent.txt').write_text('failed migration')

        def restart_then_crash(release, paused=False):
            self.assertEqual(release, self.old)
            self.assertEqual((self.data / 'agent.txt').read_text(), 'original')
            (self.data / 'agent.txt').write_text('work completed after restart')
            raise SystemExit('helper crashed after worker resumed')

        with patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn', side_effect=restart_then_crash):
            with self.assertRaises(SystemExit):
                self.manager.recover()
        with patch.object(updater, 'healthy', return_value=True), patch.object(self.manager, 'stop') as stop, patch.object(self.manager, 'spawn') as spawn:
            self.manager.launch()
        self.assertEqual((self.data / 'agent.txt').read_text(), 'work completed after restart')
        self.assertEqual(self.manager.current(), self.old)
        stop.assert_not_called()
        spawn.assert_not_called()
        self.assertFalse((self.home / 'transaction.json').exists())

    def test_crash_before_rollback_restart_can_launch_restored_release(self):
        backup = self.home / 'backups/original'
        shutil.copytree(self.data, backup)
        updater.atomic(self.home / 'current.json', self.new)
        updater.atomic(self.home / 'transaction.json', dict(
            old=self.old, new=self.new, backup=str(backup), committed=False))
        with patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn', side_effect=SystemExit):
            with self.assertRaises(SystemExit):
                self.manager.recover()
        with patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn') as spawn:
            self.manager.launch()
        spawn.assert_called_once_with(self.old)
        self.assertEqual((self.data / 'agent.txt').read_text(), 'original')

    def test_desktop_failures_remain_retryable_without_touching_backend(self):
        candidate = self.home / 'candidate.app'
        helper = Path('Contents/Resources/updater.py')
        (candidate / helper).parent.mkdir(parents=True)
        (candidate / helper).write_text('new helper')
        installed = self.home / 'installed.app'
        self.manager.config['app'] = str(installed)
        self.new['desktop'] = str(candidate)

        def copy_bundle(args):
            self.assertEqual(args[0], 'ditto')
            shutil.copytree(args[1], args[2])

        def exchange(staged, app):
            shutil.copytree(staged, app, dirs_exist_ok=True)
            return False

        for failure in ['copy', 'exchange', 'helper']:
            with self.subTest(failure=failure):
                updater.atomic(self.home / 'current.json', self.old)
                with patch.object(self.manager, 'check', return_value=self.new['sha']), patch.object(self.manager, 'prepare', return_value=self.new), patch.object(updater, 'healthy', return_value=False), patch.object(self.manager, 'spawn', return_value=(Mock(), self.home / 'activation')), patch.object(updater, 'command', side_effect=copy_bundle), patch.object(updater, 'replace_app', side_effect=exchange):
                    target, attribute = {
                        'copy': (updater, 'command'),
                        'exchange': (updater, 'replace_app'),
                        'helper': (updater.shutil, 'copy2'),
                    }[failure]
                    with patch.object(target, attribute, side_effect=OSError('injected desktop failure')):
                        with self.assertRaisesRegex(OSError, 'injected desktop failure'):
                            self.manager.update()
                self.assertEqual(self.manager.current()['sha'], self.new['sha'])
                self.assertFalse((self.home / 'transaction.json').exists())
                # Construct a fresh manager to verify the retry survives relaunch.
                updater.atomic(self.home / 'config.json', self.manager.config)
                manager = updater.Manager(self.home)
                with patch.object(updater, 'command', return_value=self.new['sha'] + '\trefs/heads/main'):
                    manager.check()
                self.assertEqual(json.loads(manager.status_file.read_text())['phase'], 'available')
                (self.data / 'agent.txt').write_text('new backend work')
                backups = set((self.home / 'backups').iterdir())
                with patch.object(manager, 'check', return_value=self.new['sha']), patch.object(manager, 'prepare') as prepare, patch.object(manager, 'stop') as stop, patch.object(manager, 'spawn') as spawn, patch.object(updater, 'command', side_effect=copy_bundle), patch.object(updater, 'replace_app', side_effect=exchange):
                    manager.update()
                prepare.assert_not_called()
                stop.assert_not_called()
                spawn.assert_not_called()
                self.assertEqual(set((self.home / 'backups').iterdir()), backups)
                self.assertEqual((self.data / 'agent.txt').read_text(), 'new backend work')
                self.assertEqual((installed / helper).read_text(), 'new helper')
                self.assertEqual((self.home / 'updater.py').read_text(), 'new helper')
                self.assertEqual(manager.current()['desktop_revision'], self.new['sha'])
                with patch.object(updater, 'command', return_value=self.new['sha'] + '\trefs/heads/main'):
                    manager.check()
                status = json.loads(manager.status_file.read_text())
                self.assertEqual(status['phase'], 'current')
                self.assertEqual(status['desktop_revision'], self.new['sha'])

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
