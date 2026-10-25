# Diagnostics tests (Desktop singleton): text fields, secrets redacted (Burn error, environment),
# no environment variable copied, CLI version read in the background, build info,
# opening folders (xdg-open with the cleaned environment, File Explorer on Windows).
#   cd app && python -m unittest discover -s tests -v
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import APP, js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402

from agentburn import diagnostics  # noqa: E402

TOKEN = "sk-ant-oat01-SECRETSECRET1234567890abcdef"


def desktop(bin=None):
    env = qml_env()
    d = env["data"]
    return diagnostics.Desktop(bin or os.environ["AGENT_BURN_BIN"], d, d / "conf" / "settings.json", d / "logs", d / "cache")


class Text(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = main_root()
        js(cls.root, "Burn.refresh(false)")
        assert wait_for(lambda: js(cls.root, "Burn.summary !== null && !Burn.loading"), 30), "fake CLI report"

    def test_fields_providers_and_errors(self):
        d = desktop()
        d.attach(self.root)
        js(self.root, f"Burn.note('summary', 'refused: Bearer {TOKEN} for john@example.com')")
        with mock.patch.dict(os.environ, {"AB_DIAG_CANARY": "canary-4f2a9", "CLAUDE_CODE_OAUTH_TOKEN": TOKEN}):
            text = d.diagnosticsText()
        for label in ("Agent Burn: 1.0.0 (dev)", "Pinned CLI: agent-burn ", "CLI: ", "System: ", "Qt: ",
                      "Desktop: ", "Screens: ", "System tray: no", "Data: ", "Settings: ",
                      "Logs: ", "Cache: ", "agent-burn data: Live, updated ",
                      "Claude Code: Live.", "Codex: Not detected.", "Recent errors:"):
            self.assertIn(label, text)
        self.assertRegex(text, r"revision [0-9a-f]{12}\n")   # pinned revision, abbreviated (not a redacted 40-char hex)
        self.assertRegex(text, r"\n  \d{4}-\d\d-\d\d \d\d:\d\d:\d\d summary: refused: Bearer \[redacted\] for \[redacted\]")
        for leak in ("SECRETSECRET", "john@example.com", "canary-4f2a9", "AB_DIAG_CANARY", "CLAUDE_CODE_OAUTH_TOKEN",
                     "PATH=", "HOME="):
            self.assertNotIn(leak, text)

    def test_without_root_and_clipboard_copy(self):
        d = desktop()
        self.assertIn("agent-burn data: not read", d.diagnosticsText())
        d.attach(self.root)
        d.copyDiagnostics()
        self.assertEqual(QGuiApplication.clipboard().text(), d.diagnosticsText())

    def test_settings_in_memory_for_the_selftest(self):
        d = diagnostics.Desktop(os.environ["AGENT_BURN_BIN"], qml_env()["data"], None, "logs", "cache")
        self.assertEqual(d.configDir, "in memory")   # not the real settings directory, unused
        self.assertIn("Settings: in memory\n", d.diagnosticsText())

    def test_tray_state_notifies(self):
        d = desktop()
        seen = []
        d.changed.connect(lambda: seen.append(d.trayAvailable))
        d.setTrayAvailable(True)
        d.setTrayAvailable(True)
        self.assertEqual(seen, [True])
        self.assertIn("System tray: yes", d.diagnosticsText())


class CliVersion(unittest.TestCase):
    def test_read_in_background(self):
        d = desktop()
        self.assertEqual(d.cliVersion, "")
        self.assertTrue(dict(d.facts())["CLI"].endswith("(version not read)"))
        d.probeCli()
        self.assertEqual(d.cliVersion, "")   # no waiting: nothing yet
        self.assertTrue(dict(d.facts())["CLI"].endswith("(being read)"))   # 1st line of the selftest log
        self.assertTrue(wait_for(lambda: d.cliVersion != "", 20))
        self.assertEqual(d.cliVersion, "agent-burn (fixtures)")

    def test_missing_cli(self):
        d = desktop(str(APP / "tests" / "absent"))
        d.probeCli()
        self.assertTrue(wait_for(lambda: d.cliVersion != "", 10))
        self.assertEqual(d.cliVersion, "not found")

    @unittest.skipIf(sys.platform == "win32", "fake CLI in sh")
    def test_empty_or_hung_version(self):
        # Nothing on stdout: "unreadable", not "reading…" forever; hung: killed at the timeout, reported as such.
        with tempfile.TemporaryDirectory() as tmp:
            for body, shown in (("exit 0", "unreadable"), ("exec sleep 30", "no response (1 s)")):
                cli = Path(tmp) / "agent-burn"
                cli.write_text(f"#!/bin/sh\n{body}\n")
                cli.chmod(0o755)
                d = desktop(str(cli))
                with mock.patch.object(diagnostics, "PROBE_MS", 1000):
                    d.probeCli()
                    self.assertTrue(wait_for(lambda: d.cliVersion != "", 10), body)
                self.assertEqual(d.cliVersion, shown)


class BuildInfo(unittest.TestCase):
    def test_dev_reads_the_pinned_cli_from_cli_env(self):
        b = diagnostics.build_info()
        self.assertEqual(sorted(b), sorted(diagnostics.BUILD_KEYS))
        self.assertEqual((b["appVersion"], b["target"]), ("1.0.0", "dev"))
        self.assertRegex(b["cliRev"], r"^[0-9a-f]{40}$")
        self.assertRegex(b["cliVersion"], r"^agent-burn \d+\.\d+\.\d+$")

    def test_frozen_reads_build_info_next_to_the_exe(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sys, "frozen", True, create=True), \
                mock.patch.object(sys, "executable", str(Path(d) / "AgentBurn.exe")):
            info = {"appVersion": "1.2.3", "cliRev": "abc", "cliVersion": "agent-burn 20.0.21",
                    "target": "x86_64-pc-windows-msvc", "builtAt": "2026-10-25T10:00:00Z", "other": 1}
            (Path(d) / "build-info.json").write_text(json.dumps(info), encoding="utf-8")
            self.assertEqual(diagnostics.build_info(), {k: info[k] for k in diagnostics.BUILD_KEYS})
            (Path(d) / "build-info.json").write_text("{broken", encoding="utf-8")
            with self.assertLogs("agentburn", "WARNING"):
                b = diagnostics.build_info()
            self.assertEqual((b["appVersion"], b["target"], b["cliRev"]), ("1.0.0", "", ""))


class OpenDirs(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "xdg-open: Linux")
    def test_linux_xdg_open_detached_with_clean_environment(self):
        qml_env()
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, dump = Path(tmp) / "bin", Path(tmp) / "xdg-open.txt"
            bin_dir.mkdir()
            (bin_dir / "xdg-open").write_text(f'#!/bin/sh\n{{ echo "$1"; env; }} > "{dump}.part" && mv "{dump}.part" "{dump}"\n')
            (bin_dir / "xdg-open").chmod(0o755)
            leaks = {"LD_LIBRARY_PATH": "/bundle", "QT_PLUGIN_PATH": "/bundle/plugins", "_PYI_ARCHIVE_FILE": "/b"}
            d = desktop()
            with mock.patch.dict(os.environ, {**leaks, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}), \
                    mock.patch.object(sys, "frozen", True, create=True):
                d.openLogs()
            self.assertTrue(wait_for(dump.exists), "xdg-open never launched")
            lines = dump.read_text().splitlines()
            self.assertEqual(Path(lines[0]), qml_env()["data"] / "logs")
            env = dict(x.split("=", 1) for x in lines[1:] if "=" in x)
            for name in leaks:
                self.assertNotIn(name, env)

    def test_windows_uses_the_explorer_and_logs_failures(self):
        d = desktop()
        with mock.patch.object(sys, "platform", "win32"), mock.patch.object(diagnostics, "QDesktopServices") as services:
            services.openUrl.return_value = False
            with self.assertLogs("agentburn", "WARNING") as logs:
                d.openDataDir()
        services.openUrl.assert_called_once_with(QUrl.fromLocalFile(str(qml_env()["data"])))
        self.assertTrue(re.search(r"cannot open", logs.output[0]))

    def test_licenses_only_when_bundled(self):
        d = desktop()
        self.assertFalse(d.licensesAvailable)   # dev: no licenses/ directory
        with mock.patch.object(diagnostics, "open_path") as opened:
            d.openLicenses()
        opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
