"""Installation must verify the actual worker, not just a healthy HTTP server."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

if sys.platform != 'win32':
    from macos import install
from sapiens.runtime import settings as codex_config
from sapiens import preflight


class PreflightTest(unittest.TestCase):
    def setUp(self):
        for target, value in (
            ('sapiens.preflight.codex_binary', '/test/codex'),
            ('sapiens.preflight.cli_version', (0, 158, 0)),
            ('sapiens.preflight.subprocess.run', Mock(returncode=0)),
        ):
            mocker = patch(target, return_value=value)
            mocker.start()
            self.addCleanup(mocker.stop)

    def test_missing_cli_does_not_attempt_login_or_model_call(self):
        with patch.object(preflight, 'codex_binary', return_value=None), \
                patch.object(preflight.ModelProbe, 'complete') as complete:
            with self.assertRaisesRegex(RuntimeError, 'not found'):
                preflight.check()
        complete.assert_not_called()

    def test_old_cli_is_rejected_before_authentication(self):
        with patch.object(preflight, 'cli_version', return_value=(0, 145, 0)), \
                patch.object(preflight.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, '0.156.1 or newer'):
                preflight.check()
        run.assert_not_called()

    def test_missing_login_is_actionable(self):
        with patch.object(preflight.subprocess, 'run', return_value=Mock(returncode=1)), \
                patch.object(preflight.ModelProbe, 'complete') as complete:
            with self.assertRaisesRegex(RuntimeError, 'login'):
                preflight.check()
        complete.assert_not_called()

    def test_real_probe_uses_default_model_and_isolated_read_only_workdir(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(preflight.ModelProbe, 'complete', autospec=True,
                             return_value='SAPIENS_PREFLIGHT_OK') as complete:
            result = preflight.check()
        probe, prompt = complete.call_args.args
        self.assertEqual(result['model'], 'gpt-6-sol')
        self.assertEqual(result['reasoning'], 'high')
        command = probe._command(prompt)
        self.assertEqual(command[:2], ['/test/codex', 'exec'])
        self.assertIn('model="gpt-6-sol"', command)
        self.assertIn('model_reasoning_effort="high"', command)
        self.assertIn('--ephemeral', command)
        self.assertEqual(command[command.index('--sandbox') + 1], 'read-only')
        self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', command)
        self.assertNotIn('--ignore-user-config', command)
        self.assertFalse(probe.workdir.exists())

    def test_override_model_and_effort_are_actually_probed(self):
        with patch.dict(os.environ, {'SAPIENS_CODEX_MODEL': 'gpt-6-astra',
                                     'SAPIENS_CODEX_REASONING_EFFORT': 'high'}), \
                patch.object(preflight.ModelProbe, 'complete', autospec=True,
                             return_value='SAPIENS_PREFLIGHT_OK') as complete:
            preflight.check()
        probe, prompt = complete.call_args.args
        self.assertIn('model="gpt-6-astra"', probe._command(prompt))
        self.assertIn('model_reasoning_effort="high"', probe._command(prompt))

    def test_model_rejection_and_timeout_fail_instead_of_reporting_success(self):
        for error in (RuntimeError('model is not supported with this account'),
                      TimeoutError('connection timed out')):
            with self.subTest(error=error), \
                    patch.object(preflight.ModelProbe, 'complete', side_effect=error):
                with self.assertRaisesRegex(RuntimeError, 'installation has not been activated'):
                    preflight.check()

    def test_unexpected_reply_fails(self):
        with patch.object(preflight.ModelProbe, 'complete', return_value='Something else'):
            with self.assertRaisesRegex(RuntimeError, 'unexpected reply'):
                preflight.check()


class VersionTest(unittest.TestCase):
    def setUp(self):
        codex_config.codex_binary.cache_clear()
        self.addCleanup(codex_config.codex_binary.cache_clear)

    def test_runtime_and_installer_choose_newest_installed_cli(self):
        versions = {'/path/codex': (0, 145, 0),
                    '/Applications/Codex.app/Contents/Resources/codex': (0, 158, 0),
                    '/Applications/ChatGPT.app/Contents/Resources/codex': (0, 156, 1)}
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(codex_config.sys, 'platform', 'darwin'), \
                patch.object(codex_config.shutil, 'which', return_value='/path/codex'), \
                patch.object(codex_config.os, 'access', return_value=True), \
                patch.object(codex_config, 'cli_version', side_effect=versions.__getitem__):
            self.assertEqual(codex_config.codex_binary(),
                             '/Applications/Codex.app/Contents/Resources/codex')

    def test_invalid_explicit_override_does_not_silently_select_another_cli(self):
        with patch.dict(os.environ, {'SAPIENS_CODEX_BINARY': '/missing/codex'}), \
                patch.object(codex_config.shutil, 'which', return_value=None), \
                patch.object(codex_config, 'cli_version') as version:
            self.assertIsNone(codex_config.codex_binary())
        version.assert_not_called()

    def test_version_parser_rejects_unrecognized_output(self):
        for output in ('not a Codex binary', 'other-cli 9.0.0'):
            with patch.object(codex_config.subprocess, 'run', return_value=Mock(stdout=output)):
                with self.assertRaisesRegex(RuntimeError, 'Could not read'):
                    codex_config.cli_version('/test/codex')

    def test_version_parser_accepts_release_and_prerelease_suffix(self):
        for output in ('codex-cli 0.158.0\n', 'codex-cli 0.159.0-alpha.1\n'):
            with patch.object(codex_config.subprocess, 'run', return_value=Mock(stdout=output)):
                version = codex_config.cli_version('/test/codex')
            self.assertGreaterEqual(version, codex_config.MIN_CODEX_VERSION)


@unittest.skipIf(sys.platform == 'win32', 'macOS installer')
class InstallerPreflightTest(unittest.TestCase):
    def test_failed_check_does_not_create_or_modify_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'managed'
            root = Path(directory) / 'repo'
            failure = subprocess.CalledProcessError(1, 'preflight')
            for existing in (False, True):
                if existing:
                    home.mkdir()
                    (home / 'config.json').write_text('existing config')
                    (home / 'current.json').write_text('existing release')
                with patch.object(install, 'HOME', home), patch.object(install, 'ROOT', root), \
                        patch.object(install.subprocess, 'run', side_effect=failure) as run:
                    with self.assertRaises(subprocess.CalledProcessError):
                        install.install()
                run.assert_called_once_with([sys.executable, '-m', 'sapiens.preflight'],
                                            cwd=root, check=True, timeout=180)
                if existing:
                    self.assertEqual((home / 'current.json').read_text(), 'existing release')
                    self.assertEqual((home / 'config.json').read_text(), 'existing config')
                else:
                    self.assertFalse(home.exists())


if __name__ == '__main__':
    unittest.main()
