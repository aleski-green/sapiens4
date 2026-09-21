from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch, MagicMock

from sapiens.macos_links import WorkspaceLink, register_workspace_link
from sapiens import __main__ as cli


class MacOSLinksTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "Sapiens4/workspace.plist"

    def test_port_changes_and_old_server_cleanup_preserves_latest(self):
        older, newer = WorkspaceLink(self.path), WorkspaceLink(self.path)
        older.publish(49821)
        newer.publish(53172)
        older.close()
        self.assertEqual(plistlib.loads(self.path.read_bytes())["port"], 53172)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        newer.close()
        newer.close()
        self.assertFalse(self.path.exists())

    def test_unbound_or_invalid_ports_are_rejected(self):
        for port in (0, -1, 65536, "4175", True):
            with self.subTest(port=port), self.assertRaises(ValueError):
                WorkspaceLink(self.path).publish(port)
        self.assertFalse(self.path.exists())

    def test_non_macos_has_no_installation_or_registration(self):
        with patch("sapiens.macos_links.sys.platform", "linux"), \
                patch("sapiens.macos_links.subprocess.run") as install:
            self.assertIsNone(register_workspace_link(45678))
            install.assert_not_called()

    def test_macos_installs_and_publishes_supplied_port(self):
        registration = WorkspaceLink(self.path)
        with patch("sapiens.macos_links.sys.platform", "darwin"), \
                patch("sapiens.macos_links.WorkspaceLink", return_value=registration), \
                patch("sapiens.macos_links.subprocess.run") as install:
            self.assertIs(register_workspace_link(54321), registration)
            install.assert_called_once()
        self.assertEqual(plistlib.loads(self.path.read_bytes())["port"], 54321)

    def test_install_failure_does_not_abort_server(self):
        with patch("sapiens.macos_links.sys.platform", "darwin"), \
                patch("sapiens.macos_links.subprocess.run",
                      side_effect=subprocess.CalledProcessError(1, "installer")), \
                self.assertLogs(level="WARNING"):
            self.assertIsNone(register_workspace_link(45678))

    def test_cli_registers_bound_port_and_cleans_up_on_exit(self):
        server, registration = MagicMock(), MagicMock()
        server.server_port = 53421
        with patch("sys.argv", ["sapiens", "--port", "0"]), \
                patch.object(cli, "index"), patch.object(cli, "javascript"), \
                patch.object(cli, "Service"), patch.object(cli, "Server", return_value=server), \
                patch.object(cli.signal, "signal"), patch("builtins.print"), \
                patch.object(cli, "register_workspace_link", return_value=registration) as register:
            cli.main()
        register.assert_called_once_with(53421)
        server.server_close.assert_called_once()
        registration.close.assert_called_once()
