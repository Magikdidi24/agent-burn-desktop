# In-app update tests (updater.py) against a fake GitHub on 127.0.0.1 (AGENT_BURN_UPDATE_URL), never the real
# one: release check, what the network sends validated, download checked by SHA-256, installer command line
# (never run), portable copy, unsupported platforms, the About page and its buttons.
#   cd app && python -m unittest discover -s tests -v
import hashlib
import json
import logging
import os
import shutil
import sys
import tempfile
import threading
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import gui, js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import Qt, QtMsgType, QUrl, qInstallMessageHandler  # noqa: E402
from PySide6.QtGui import QColor  # noqa: E402
from PySide6.QtNetwork import QNetworkAccessManager  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402

from agentburn import __version__, paths, settings, updater  # noqa: E402

SETUP = b"MZ not a real installer\0" * 2000
NAME = "AgentBurn-Setup-9.9.9-x64.exe"


class Server:
    """Fake GitHub: files maps a path to (status, body, headers); seen records (path, headers) of each request."""

    def __init__(self):
        files, seen = self.files, self.seen = {}, []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, dict(self.headers)))
                status, body, headers = files.get(self.path, (404, b"", {}))
                self.send_response(status)
                for k, v in {**headers, "Content-Length": str(len(body))}.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def paths(self):
        return [p for p, _ in self.seen]

    def latest(self, release):
        self.files["/releases/latest"] = (200, json.dumps(release).encode(), {"Content-Type": "application/json"})

    def release(self, version="9.9.9", setup=SETUP, sums=None, **fields):
        """Release as GitHub publishes it (x64 installer behind a redirect to the download servers, SHA256SUMS
        of every package); fields replace its keys."""
        tag, name = f"desktop-v{version}", f"AgentBurn-Setup-{version}-x64.exe"
        if sums is None:
            sums = f"{'0' * 64}  agent-burn-desktop_{version}_amd64.deb\n{hashlib.sha256(setup).hexdigest()}  {name}\n".encode()
        files = f"{self.url}/releases/download/{tag}/"
        release = {"tag_name": tag, "draft": False, "prerelease": False, "html_url": f"{self.url}/releases/tag/{tag}",
                   "assets": [{"name": name, "size": len(setup), "browser_download_url": files + name},
                              {"name": "SHA256SUMS", "size": len(sums), "browser_download_url": files + "SHA256SUMS"}],
                   **fields}
        self.latest(release)
        self.files.update({f"/releases/download/{tag}/{name}": (302, b"", {"Location": "/cdn/setup"}),
                           "/cdn/setup": (200, setup, {}), f"/releases/download/{tag}/SHA256SUMS": (200, sums, {})})
        return release


class Update(unittest.TestCase):
    def setUp(self):
        gui()
        self.server = Server()
        self.addCleanup(self.server.close)
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-burn-update-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.setup = self.tmp / "cache" / updater.SETUP
        self.autostart = False
        self.cfg = settings.Settings(None, types.SimpleNamespace(autostart=lambda: self.autostart))
        mock.patch.object(paths, "cache_dir", return_value=self.tmp / "cache").start()
        self.process = mock.patch.object(updater, "QProcess").start()   # never a real installer
        self.process.return_value.startDetached.return_value = True
        self.quit = mock.patch.object(updater, "QCoreApplication").start().quit
        self.opened = mock.patch.object(updater, "QDesktopServices").start().openUrl
        self.addCleanup(mock.patch.stopall)
        self.logged = []   # the updater's log lines, kept off stderr
        handler = logging.Handler()
        handler.emit = lambda record: self.logged.append(record.getMessage())
        updater.log.addHandler(handler)
        updater.log.setLevel(logging.INFO)
        self.addCleanup(updater.log.setLevel, logging.NOTSET)
        self.addCleanup(updater.log.removeHandler, handler)

    def updater(self, installed=True, target="windows-x64"):
        """Updater of a frozen Windows build (target from build-info.json), installed (Inno's unins000.exe
        next to the exe) or portable, reading the fake GitHub."""
        app = Path(tempfile.mkdtemp(dir=self.tmp))
        if installed:
            (app / "unins000.exe").touch()
        with mock.patch.dict(os.environ, {"AGENT_BURN_UPDATE_URL": self.server.url}):
            u = updater.Updater(target, app, self.cfg)
        self.addCleanup(u._timer.stop)
        return u

    def check(self, u):
        u.check()
        self.assertTrue(wait_for(lambda: u.state != "checking", 10))
        return u.state

    def install(self, u):
        self.assertEqual(self.check(u), "available", u.message)
        u.update()
        self.assertTrue(wait_for(lambda: u.state != "downloading", 10))
        return u.state

    def test_newer_release_found(self):
        self.server.release()
        u = self.updater()
        self.assertEqual((u.mode, u.state), ("installer", ""))
        self.assertEqual(self.check(u), "available")
        self.assertEqual(u.version, "9.9.9")
        path, headers = self.server.seen[0]
        self.assertEqual(path, "/releases/latest")
        self.assertEqual((headers["User-Agent"], headers["Accept"]), (f"AgentBurn/{__version__}", "application/vnd.github+json"))

    def test_same_older_draft_or_prerelease_is_up_to_date(self):
        u = self.updater()
        for version, fields in ((__version__, {}), ("0.9.9", {}), ("9.9.9", {"draft": True}), ("9.9.9", {"prerelease": True})):
            self.server.release(version, **fields)
            self.assertEqual(self.check(u), "current", (version, fields))
        with mock.patch.object(updater, "__version__", "1.0.9"):   # numbers, not text: 1.0.10 is newer
            self.server.release("1.0.10")
            self.assertEqual(self.check(u), "available")

    def test_unusable_answers_refused_with_a_clean_message(self):
        good = self.server.release()
        setup, sums = good["assets"]
        prefix = f"{self.server.url}/releases/download/desktop-v9.9.9/"
        cases = [
            ({"tag_name": "v9.9.9"}, "unexpected release tag"),
            ({"tag_name": "desktop-v9.9"}, "unexpected release tag"),
            ({"tag_name": "desktop-v9.9.9\n"}, "unexpected release tag"),
            ({"tag_name": "desktop-v９.9.9"}, "unexpected release tag"),   # fullwidth 9
            ({"tag_name": "desktop-v9.9.9-\x1b[31mbeta‮"}, "unexpected release tag 'desktop-v9.9.9-[31mbeta'"),
            ({"tag_name": None}, "unexpected release tag"),
            ({"assets": [sums]}, f"{NAME} missing from the release"),
            ({"assets": [setup]}, "SHA256SUMS missing from the release"),
            ({"assets": "nope"}, f"{NAME} missing from the release"),
            ({"assets": [{**setup, "name": "AgentBurn-Setup-9.9.9-arm64.exe"}, sums]}, f"{NAME} missing"),
        ]
        for url in ("https://evil.example/" + NAME, prefix + "../../../../other/repo/" + NAME,
                    prefix.replace("9.9.9", "9.9.8") + NAME, prefix + NAME + "?x", None):
            cases.append(({"assets": [{**setup, "browser_download_url": url}, sums]}, f"{NAME}: download address outside"))
        for size in (0, -1, updater.MAX_SETUP + 1, "40000000", True, None):
            cases.append(({"assets": [{**setup, "size": size}, sums]}, f"{NAME}: unexpected size"))
        u = self.updater()
        for fields, error in cases:
            self.server.latest({**good, **fields})
            self.assertEqual(self.check(u), "error", fields)
            self.assertIn("Update check failed: " + error, u.message, fields)
            u.update()   # nothing to install
            self.assertEqual(u.state, "error")
        for body, error in ((b"[]", "unreadable answer"), (b"{", "Expecting"), (b"\xff", "utf-8"), (b"[" * 100000, "recursion")):
            self.server.files["/releases/latest"] = (200, body, {})
            self.assertEqual(self.check(u), "error")
            self.assertIn(error, u.message)
        self.server.files["/releases/latest"] = (403, b'{"message": "API rate limit exceeded"}', {})
        self.assertEqual(self.check(u), "error")
        self.assertEqual(u.message, "Update check failed: HTTP 403")
        self.assertEqual(set(self.server.paths()), {"/releases/latest"})   # never anything downloaded
        self.assertIn("update: Update check failed: unexpected release tag 'desktop-v9.9.9-[31mbeta'", self.logged)
        self.assertEqual([line for line in self.logged if "\x1b" in line or "\u202e" in line], [])

    def test_github_addresses_only_over_https(self):
        tag = "desktop-v9.9.9"
        files = f"{updater.SITE}/releases/download/{tag}/"
        release = {"tag_name": tag, "html_url": f"{updater.SITE}/releases/tag/{tag}",
                   "assets": [{"name": NAME, "size": 1, "browser_download_url": files + NAME},
                              {"name": "SHA256SUMS", "size": 1, "browser_download_url": files + "SHA256SUMS"}]}
        offer = updater.parse(release, "x64", updater.SITE, False)
        self.assertEqual((offer["setup"], offer["sums"], offer["size"]), (files + NAME, files + "SHA256SUMS", 1))
        self.assertTrue(offer["setup"].startswith("https://github.com/Magikdidi24/agent-burn-desktop/releases/download/"))
        self.assertEqual(updater.parse(release, "x64", updater.SITE, True)["page"], release["html_url"])
        for url in (files.replace("https:", "http:") + NAME, files.replace("agent-burn-desktop", "agent-burn-desktop-x") + NAME):
            bad = {**release, "assets": [{**release["assets"][0], "browser_download_url": url}, release["assets"][1]]}
            with self.assertRaisesRegex(ValueError, "download address outside"):
                updater.parse(bad, "x64", updater.SITE, False)
        for page in ("http://github.com/Magikdidi24/agent-burn-desktop/releases/tag/" + tag, "https://evil.example/"):
            with self.assertRaisesRegex(ValueError, "release page outside"):
                updater.parse({**release, "html_url": page}, "x64", updater.SITE, True)

    def test_checksums_file(self):
        h, other = "ab" * 32, "cd" * 32
        self.assertEqual(updater.checksum(f"{other}  x.deb\r\n{h.upper()} *{NAME}\r\n", NAME), h)   # binary mode, CRLF
        self.assertIsNone(updater.checksum(f"{h}  {NAME}.sig\n{h}  ./{NAME}\n{h[:-1]}  {NAME}\n", NAME))
        self.assertIsNone(updater.checksum(f"{h}  {NAME}\n{other}  {NAME}\n", NAME))   # two different sums
        self.assertEqual(updater.clean("a\x1b[31mb\nc‮d\x00"), "a[31mbcd")

    def test_update_downloads_checks_runs_the_installer_and_quits(self):
        self.server.release()
        for autostart, extra in ((False, ["/MERGETASKS=!autostart"]), (True, [])):
            self.autostart = autostart
            self.process.reset_mock()
            self.quit.reset_mock()
            del self.server.seen[:]
            u = self.updater()
            progress = []
            u.changed.connect(lambda: progress.append(u.progress))
            self.assertEqual(self.install(u), "installing", u.message)
            self.assertEqual(self.server.paths(), ["/releases/latest", "/releases/download/desktop-v9.9.9/SHA256SUMS",
                                                   f"/releases/download/desktop-v9.9.9/{NAME}", "/cdn/setup"])
            self.assertIn(100, progress)
            self.assertEqual(self.setup.read_bytes(), SETUP)
            p = self.process.return_value
            p.setProgram.assert_called_once_with(str(self.setup))
            # Start at login off: Inno must not restore its remembered "autostart" task.
            p.setArguments.assert_called_once_with(["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/relaunch=1", *extra])
            p.setProcessEnvironment.assert_called_once()
            p.startDetached.assert_called_once_with()
            self.quit.assert_called_once_with()

    def test_mismatching_or_oversized_download_deleted_and_never_run(self):
        u = self.updater()
        self.server.release(sums=f"{'0' * 64}  {NAME}\n".encode())
        self.assertEqual(self.install(u), "error")
        self.assertIn("does not match its SHA-256 sum", u.message)
        self.assertFalse(self.setup.exists())
        release = self.server.release()
        release["assets"][0]["size"] = len(SETUP) - 10   # more data than announced: stopped there
        self.server.latest(release)
        self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, "Download failed: larger than announced")
        self.assertFalse(self.setup.exists())
        self.server.release(sums=f"{'0' * 64}  agent-burn-desktop_9.9.9_amd64.deb\n".encode())
        self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, f"Download failed: no single SHA-256 sum for {NAME}")
        self.process.assert_not_called()
        self.quit.assert_not_called()

    def test_installer_that_cannot_start_is_reported(self):
        self.server.release()
        self.process.return_value.startDetached.return_value = False
        u = self.updater()
        self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, "Could not start the installer")
        self.assertFalse(self.setup.exists())
        self.quit.assert_not_called()

    def test_portable_copy_opens_the_release_page(self):
        self.server.release()
        u = self.updater(installed=False)
        self.assertEqual(u.mode, "portable")
        self.assertEqual(self.check(u), "available")
        u.update()
        self.opened.assert_called_once_with(QUrl(f"{self.server.url}/releases/tag/desktop-v9.9.9"))
        self.assertEqual(self.server.paths(), ["/releases/latest"])   # nothing downloaded
        self.process.assert_not_called()
        self.quit.assert_not_called()
        self.server.release(html_url="https://evil.example/releases/tag/desktop-v9.9.9")
        self.assertEqual(self.check(u), "error")
        self.assertEqual(u.message, "Update check failed: release page outside the repository")

    def test_unsupported_platforms_do_nothing(self):
        self.server.release()
        for target in ("dev", "linux-x86_64", "", "windows-x86"):
            u = self.updater(target=target)
            u.start()
            u.check()
            u.update()
            wait_for(lambda: False, 0.2)
            self.assertEqual((u.mode, u.state, u._timer.isActive()), ("", "", False), target)
            self.assertEqual(u.findChildren(QNetworkAccessManager), [])
        self.assertEqual(self.server.seen, [])

    def test_automatic_checks_one_request_at_a_time(self):
        self.server.release()
        u = self.updater()
        self.assertFalse(u._timer.isActive())   # not before start(): selftest, --show
        u.start()
        self.assertEqual((u._timer.isActive(), u._timer.interval()), (True, 60_000))
        u._timer.timeout.emit()
        self.assertEqual((u._timer.isActive(), u._timer.interval()), (True, 24 * 3600 * 1000))
        u.check()   # one already running: ignored
        self.assertTrue(wait_for(lambda: u.state == "available", 10))
        self.assertEqual(self.server.paths(), ["/releases/latest"])


class AboutPage(unittest.TestCase):
    """The About section with the shared Updater singleton (dev, unsupported) made to look like a Windows build."""

    def setUp(self):
        self.root = main_root()
        self.win = self.root.property("settingsWindow")
        self.u = qml_env()["updater"]
        self.server = Server()
        self.addCleanup(self.server.close)
        self.addCleanup(self.force, mode="", state="", version="", message="", offer=None, net=None,
                        api=updater.API, site=updater.SITE)
        self.addCleanup(self.win.close)
        self.messages = []
        qInstallMessageHandler(lambda kind, context, message: kind != QtMsgType.QtDebugMsg
                               and not message.startswith("This plugin does not support") and self.messages.append(message))
        self.addCleanup(qInstallMessageHandler, None)

    def force(self, **values):
        for k, v in values.items():
            setattr(self.u, "_" + k, v)
        self.u.changed.emit()
        wait_for(lambda: False, 0.1)

    def shown(self):
        """Visible labels and buttons of the window, by text."""
        texts, buttons, todo = {}, {}, [self.win.contentItem()]
        while todo:
            item = todo.pop()
            todo += item.childItems()
            if item.isVisible() and item.inherits("QQuickAbstractButton"):
                buttons[item.property("text")] = item
            elif item.isVisible() and item.inherits("QQuickLabel"):
                texts[item.property("text")] = item
        return texts, buttons

    def test_update_state_and_buttons(self):
        js(self.root, "openSettings('about')")
        self.assertTrue(wait_for(self.win.isVisible, 5))
        wait_for(lambda: False, 0.3)
        texts, buttons = self.shown()
        self.assertNotIn("Updates", texts)   # Linux, dev: nothing
        self.assertNotIn("Check for updates", buttons)
        self.server.release()
        self.force(mode="portable", net=QNetworkAccessManager(self.u), api=self.server.url, site=self.server.url)
        texts, buttons = self.shown()
        self.assertIn("Not checked yet.", texts)
        check = buttons["Check for updates"]
        check.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertTrue(wait_for(lambda: self.u.state == "available", 10))
        wait_for(lambda: False, 0.1)
        texts, buttons = self.shown()
        self.assertIn("Agent Burn 9.9.9 is available.", texts)
        with mock.patch.object(updater, "QDesktopServices") as services:
            buttons["Open download page"].forceActiveFocus(Qt.FocusReason.TabFocusReason)
            QTest.keyClick(self.win, Qt.Key.Key_Return)
        services.openUrl.assert_called_once_with(QUrl(f"{self.server.url}/releases/tag/desktop-v9.9.9"))
        self.force(mode="installer")
        self.assertIn("Update now", self.shown()[1])
        self.force(state="downloading", progress=42)
        texts, buttons = self.shown()
        self.assertIn("Downloading Agent Burn 9.9.9… 42%", texts)
        self.assertFalse(buttons["Check for updates"].isEnabled())
        self.assertLess(buttons["Check for updates"].opacity(), 1)   # looks disabled too
        self.assertNotIn("Update now", buttons)
        self.force(state="error", message="Download failed: larger than announced")
        texts, buttons = self.shown()
        self.assertEqual(QColor(texts["Download failed: larger than announced"].property("color")),
                         QColor(js(self.root, "Colors.danger.toString()")))
        self.assertTrue(buttons["Check for updates"].isEnabled())
        self.assertEqual(self.messages, [])


if __name__ == "__main__":
    unittest.main()
