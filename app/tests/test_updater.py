# In-app update tests (updater.py) against a fake GitHub on 127.0.0.1 (AGENT_BURN_UPDATE_URL), never the real
# one: release check, what the network sends validated, download checked by SHA-256, installer command line
# (never run), macOS zip unpacked by a fake ditto and checked, the macOS helper's command line, then the helper
# itself run by sh on fake bundles, portable copy, unsupported platforms, the About page and its buttons.
#   cd app && python -m unittest discover -s tests -v
import hashlib
import json
import logging
import os
import plistlib
import shutil
import subprocess
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
ZIP = b"PK not a real zip\0" * 2000
MAC = "AgentBurn-9.9.9-macos-arm64.zip"
X64, MACOS = updater.ASSETS["windows-x64"], updater.ASSETS["macos-arm64"]   # release file name templates


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

    def release(self, version="9.9.9", setup=SETUP, sums=None, name=X64, **fields):
        """Release as GitHub publishes it (one package, the x64 installer unless name says otherwise, behind a
        redirect to the download servers, SHA256SUMS of every package); fields replace its keys."""
        tag, name = f"desktop-v{version}", name.format(version)
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
        self.cache = self.tmp / "cache"
        self.setup = self.cache / updater.SETUP
        self.autostart = False
        self.cfg = settings.Settings(None, types.SimpleNamespace(autostart=lambda: self.autostart))
        mock.patch.object(paths, "cache_dir", return_value=self.cache).start()
        self.process = mock.patch.object(updater, "QProcess").start()   # never a real installer or helper
        self.process.return_value.startDetached.return_value = True
        self.info = {"CFBundleIdentifier": updater.BUNDLE_ID, "CFBundleShortVersionString": "9.9.9"}
        self.unpacked = []
        mock.patch.object(updater, "extract", self.extract).start()   # never the real ditto
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

    def extract(self, archive, folder):
        """Stands for ditto: records (zip content, folder), then unpacks a bundle whose Info.plist is self.info
        (as is if bytes, none if None)."""
        self.unpacked.append((archive.read_bytes(), folder))
        contents = folder / updater.BUNDLE / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        if self.info is not None:
            data = self.info if isinstance(self.info, bytes) else plistlib.dumps(self.info)
            (contents / "Info.plist").write_bytes(data)

    def updater(self, installed=True, target="windows-x64"):
        """Updater of a frozen build (target from build-info.json) reading the fake GitHub. Windows: installed
        (Inno's unins000.exe next to the exe) or portable; macOS: exe in Agent Burn.app/Contents/MacOS, the
        bundle alone in a folder of its own."""
        app = Path(tempfile.mkdtemp(dir=self.tmp))
        if target.startswith("macos"):
            app = app / updater.BUNDLE / "Contents" / "MacOS"
            app.mkdir(parents=True)
        elif installed:
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
            ({"assets": [{**setup, "name": [NAME]}, sums]}, f"{NAME} missing"),   # unhashable name
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
        offer = updater.parse(release, X64, updater.SITE, False)
        self.assertEqual((offer["setup"], offer["sums"], offer["size"]), (files + NAME, files + "SHA256SUMS", 1))
        self.assertTrue(offer["setup"].startswith("https://github.com/Magikdidi24/agent-burn-desktop/releases/download/"))
        self.assertEqual(updater.parse(release, X64, updater.SITE, True)["page"], release["html_url"])
        for url in (files.replace("https:", "http:") + NAME, files.replace("agent-burn-desktop", "agent-burn-desktop-x") + NAME):
            bad = {**release, "assets": [{**release["assets"][0], "browser_download_url": url}, release["assets"][1]]}
            with self.assertRaisesRegex(ValueError, "download address outside"):
                updater.parse(bad, X64, updater.SITE, False)
        for page in ("http://github.com/Magikdidi24/agent-burn-desktop/releases/tag/" + tag, "https://evil.example/"):
            with self.assertRaisesRegex(ValueError, "release page outside"):
                updater.parse({**release, "html_url": page}, X64, updater.SITE, True)

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

    def test_macos_update_unpacks_checks_and_hands_over_to_the_helper(self):
        release = self.server.release(setup=ZIP, name=MACOS)
        url = release["assets"][0]["browser_download_url"].replace(MAC, NAME)
        installer = {"name": NAME, "size": 1, "browser_download_url": url}
        self.server.latest({**release, "assets": [installer, *release["assets"]]})   # the zip is the one taken
        u = self.updater(target="macos-arm64")
        self.assertEqual((u.mode, u._bundle.name), ("installer", "Agent Burn.app"))
        self.assertEqual(self.install(u), "installing", u.message)
        self.assertEqual(self.server.paths(), ["/releases/latest", "/releases/download/desktop-v9.9.9/SHA256SUMS",
                                               f"/releases/download/desktop-v9.9.9/{MAC}", "/cdn/setup"])
        [(unpacked, work)] = self.unpacked
        self.assertEqual(unpacked, ZIP)   # the file checked, as written
        self.assertEqual(list(self.cache.iterdir()), [work])   # the zip deleted once unpacked
        self.assertTrue((work / "Agent Burn.app" / "Contents" / "Info.plist").is_file())   # left for the helper
        p = self.process.return_value
        p.setProgram.assert_called_once_with("/bin/sh")
        p.setArguments.assert_called_once_with(["-c", updater.HELPER, "sh", str(os.getpid()), str(u._bundle), str(work)])
        p.setProcessEnvironment.assert_called_once()
        p.startDetached.assert_called_once_with()
        self.quit.assert_called_once_with()

    def test_macos_release_files_validated(self):
        good = self.server.release(setup=ZIP, name=MACOS)
        zip_, sums = good["assets"]
        prefix = f"{self.server.url}/releases/download/desktop-v9.9.9/"
        cases = [({"assets": [sums]}, f"{MAC} missing from the release"),
                 ({"assets": [{**zip_, "name": NAME}, sums]}, f"{MAC} missing"),   # the Windows installer: no use
                 ({"assets": [{**zip_, "name": "AgentBurn-9.9.9-macos-x64.zip"}, sums]}, f"{MAC} missing")]
        for url in ("https://evil.example/" + MAC, prefix + "../../../../other/repo/" + MAC,
                    prefix.replace("9.9.9", "9.9.8") + MAC, prefix + NAME):
            cases.append(({"assets": [{**zip_, "browser_download_url": url}, sums]}, f"{MAC}: download address outside"))
        for size in (0, updater.MAX_SETUP + 1, "1"):
            cases.append(({"assets": [{**zip_, "size": size}, sums]}, f"{MAC}: unexpected size"))
        u = self.updater(target="macos-arm64")
        for fields, error in cases:
            self.server.latest({**good, **fields})
            self.assertEqual(self.check(u), "error", fields)
            self.assertIn("Update check failed: " + error, u.message, fields)
        self.assertEqual(set(self.server.paths()), {"/releases/latest"})

    def test_macos_mismatching_download_never_unpacked(self):
        self.server.release(setup=ZIP, name=MACOS, sums=f"{'0' * 64}  {MAC}\n".encode())
        u = self.updater(target="macos-arm64")
        self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, "Download failed: the zip does not match its SHA-256 sum, nothing was installed")
        self.assertEqual((self.unpacked, list(self.cache.iterdir())), ([], []))
        self.process.assert_not_called()
        self.quit.assert_not_called()

    def test_macos_unexpected_bundle_refused_and_cleaned_up(self):
        self.server.release(setup=ZIP, name=MACOS)
        u = self.updater(target="macos-arm64")
        good, refused = self.info, "Download failed: the zip does not hold Agent Burn 9.9.9, nothing was installed"
        for info, error in (({**good, "CFBundleIdentifier": "com.example.Other"}, refused),
                            ({**good, "CFBundleShortVersionString": "9.9.8"}, refused),
                            ({**good, "CFBundleShortVersionString": "9.9.9.1"}, refused),
                            ({"CFBundleIdentifier": updater.BUNDLE_ID}, refused),
                            ([updater.BUNDLE_ID, "9.9.9"], refused),
                            (b"<?xml version='1.0'?><plist", "Download failed: "),
                            (None, "Info.plist")):
            self.info = info
            self.assertEqual(self.install(u), "error", info)
            self.assertIn(error, u.message, info)
            self.assertEqual(list(self.cache.iterdir()), [], info)   # neither the zip nor what it held
        self.info = good
        with mock.patch.object(updater, "extract", side_effect=OSError("ditto: Couldn't read PKZip signature")):
            self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, "Download failed: ditto: Couldn't read PKZip signature")
        self.assertEqual(list(self.cache.iterdir()), [])
        self.process.assert_not_called()
        self.process.return_value.startDetached.return_value = False
        self.assertEqual(self.install(u), "error")
        self.assertEqual(u.message, "Could not start the update")
        self.assertEqual(list(self.cache.iterdir()), [])
        self.quit.assert_not_called()

    @unittest.skipIf(sys.platform == "win32", "write permission on folders: Unix")
    def test_macos_bundle_that_cannot_be_replaced_opens_the_release_page(self):
        self.server.release(setup=ZIP, name=MACOS)
        folder = Path(tempfile.mkdtemp(dir=self.tmp))
        exe = folder / "Agent Burn.app" / "Contents" / "MacOS"
        (folder / "AgentBurn").mkdir()
        exe.mkdir(parents=True)
        # Folder read-only (disk image, App Translocation, a standard account's /Applications), bundle of another
        # account, exe outside a bundle.
        for locked, exe_dir in ((folder, exe), (exe.parents[1], exe), (None, folder / "AgentBurn")):
            if locked:
                locked.chmod(0o555)
            with mock.patch.dict(os.environ, {"AGENT_BURN_UPDATE_URL": self.server.url}):
                u = updater.Updater("macos-arm64", exe_dir, self.cfg)
            if locked:
                locked.chmod(0o755)
            self.assertEqual((u.mode, u._bundle), ("portable", None), exe_dir)
        self.assertEqual(self.check(u), "available")
        u.update()
        self.opened.assert_called_once_with(QUrl(f"{self.server.url}/releases/tag/desktop-v9.9.9"))
        self.assertEqual(self.server.paths(), ["/releases/latest"])   # nothing downloaded
        self.process.assert_not_called()
        self.quit.assert_not_called()

    def test_unsupported_platforms_do_nothing(self):
        self.server.release()
        for target in ("dev", "linux-x86_64", "", "windows-x86", "macos-x64", "macos-universal", "darwin"):
            u = self.updater(target=target)
            u.start()
            u.check()
            u.update()
            wait_for(lambda: False, 0.2)
            self.assertEqual((u.mode, u.state, u._timer.isActive()), ("", "", False), target)
            self.assertEqual(u.findChildren(QNetworkAccessManager), [])
        self.assertEqual(self.server.seen, [])

    def test_url_override_only_for_this_machine(self):
        app = Path(tempfile.mkdtemp(dir=self.tmp))
        for base in ("https://evil.example", "http://10.0.0.1:8000", "file:///C:/x"):
            with mock.patch.dict(os.environ, {"AGENT_BURN_UPDATE_URL": base}):
                u = updater.Updater("windows-x64", app, self.cfg)
            self.assertEqual((u._api, u._site), (updater.API, updater.SITE), base)
        self.assertTrue(any("ignored" in line for line in self.logged), self.logged)

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


@unittest.skipIf(sys.platform == "win32", "HELPER: POSIX sh")
class MacHelper(unittest.TestCase):
    """updater.HELPER run by sh on two fake bundles, a stand-in for macOS's open first on PATH."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-burn-helper-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app, self.work = self.tmp / "Applications" / "Agent Burn.app", self.tmp / "cache" / "update-1"
        for bundle, version in ((self.app, "old"), (self.work / "Agent Burn.app", "new")):
            (bundle / "Contents").mkdir(parents=True)
            (bundle / "Contents" / "version").write_text(version)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.stub("open", 'printf "%s\\n" "$@" >> "$0.log"')
        self.env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"}

    def stub(self, name, body):
        (self.bin / name).write_text(f"#!/bin/sh\n{body}\n")
        (self.bin / name).chmod(0o755)

    def helper(self, pid=None):
        """HELPER started for the app of that PID (default: one that has already quit)."""
        if pid is None:
            gone = subprocess.Popen(["true"])
            gone.wait()
            pid = gone.pid
        return subprocess.Popen(["sh", "-c", updater.HELPER, "sh", str(pid), str(self.app), str(self.work)], env=self.env,
                                stderr=subprocess.DEVNULL)   # mv's complaints, expected here

    def result(self):
        """Version of the bundle in place, the work folder still there, what open was given."""
        log = self.bin / "open.log"
        return ((self.app / "Contents" / "version").read_text(), self.work.exists(),
                log.read_text().splitlines() if log.exists() else [])

    def test_swaps_once_the_app_has_quit_then_opens_it(self):
        app = subprocess.Popen(["sleep", "1"])
        helper = self.helper(app.pid)
        with self.assertRaises(subprocess.TimeoutExpired):
            helper.wait(1.5)   # until the app is reaped (a zombie still answers kill -0)
        self.assertEqual(self.result(), ("old", True, []))
        app.wait()
        self.assertEqual(helper.wait(10), 0)
        self.assertEqual(self.result(), ("new", False, [str(self.app)]))   # old bundle deleted with the work folder

    def test_bundle_that_cannot_move_left_as_it_was(self):
        self.app.parent.chmod(0o555)   # read-only folder
        self.addCleanup(self.app.parent.chmod, 0o755)
        self.assertEqual(self.helper().wait(10), 0)
        self.assertEqual(self.result(), ("old", False, [str(self.app)]))   # new bundle discarded, old one reopened

    def test_old_bundle_put_back_when_the_new_one_cannot_move_in(self):
        # The new bundle half copied, as across disks, then a failure.
        self.stub("mv", f'[ "$1" = "{self.work / "Agent Burn.app"}" ] && mkdir -p "$2/Contents" && exit 1\n'
                        f'exec {shutil.which("mv")} "$@"')
        self.assertEqual(self.helper().wait(10), 0)
        self.assertEqual(self.result(), ("old", False, [str(self.app)]))
        self.assertEqual(sorted(p.name for p in self.app.iterdir()), ["Contents"])   # not nested in the half copy


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
