# Desktop app tests: fake CLI, popover position and height, icon, runtime QML directory
# (cache checked), Windows startup (fake registry). qml_env() also serves the other modules.
#   cd app && python -m unittest discover -s tests -v
import atexit
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP))
FIXTURES = APP.parent / "tests" / "fixtures"

from PySide6 import QtCore, QtGui, QtNetwork, QtQml, QtQuick, QtWidgets  # noqa: E402
from PySide6.QtCore import QCoreApplication, QEventLoop, QLockFile, QMetaObject, QPoint, QRect, QSize, Qt, QUrl  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication  # noqa: E402
from PySide6.QtNetwork import QLocalServer  # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine, QQmlExpression, qmlRegisterSingletonInstance  # noqa: E402
from PySide6.QtQuick import QQuickItem, QQuickWindow  # noqa: E402,F401 (QQuickWindow: type of the QML windows in Python)
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from agentburn import __main__ as appmain, diagnostics, paths, runtime, settings, shim, updater  # noqa: E402
from agentburn.tray import open_popover, pixmap, place  # noqa: E402


def gui():
    # QApplication (tray icon menus); software backend: windows can be shown offscreen, without OpenGL.
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ.setdefault("QT_QUICK_BACKEND", "software")
    QCoreApplication.setApplicationName("AgentBurn")
    return QApplication.instance() or QApplication([])


_env = {}


def qml_env():
    """Runtime QML directory, shim types and Settings/Desktop/Updater singletons registered only once per
    process (a 2nd registration makes the types incompatible), and the only engine that can read these
    singletons (registered instances: a 2nd engine gets null). Fake CLI: never the real CLI or the real HOME;
    dev updater: never a request."""
    if not _env:
        gui()
        data = Path(tempfile.mkdtemp(prefix="agent-burn-test-"))
        atexit.register(shutil.rmtree, data, True)
        cli = APP / "tests" / "fake-agent-burn"
        if sys.platform == "win32":   # sh script unusable: the same fake CLI through a .cmd
            cli = data / "fake-agent-burn.cmd"
            cli.write_text(f'@echo off\ncd /d "{APP}"\n"{sys.executable}" -m agentburn %*\n', encoding="utf-8")
        os.environ["AGENT_BURN_BIN"] = str(cli)
        os.environ["AGENT_BURN_FAKE_DIR"] = str(FIXTURES)
        qml = runtime.assemble()
        if shim._global is None:
            shim.register(qml, data)
        own = shim._global if Path(shim._global.dataDir) == data else shim.QuickshellGlobal(data, qml)
        cfg = settings.Settings(None)
        desk = diagnostics.Desktop(os.environ["AGENT_BURN_BIN"], data, data / "settings.json", data / "logs", data / "cache")
        upd = updater.Updater("dev", APP, cfg)
        qmlRegisterSingletonInstance(settings.Settings, "AgentBurn", 1, 0, "Settings", cfg)
        qmlRegisterSingletonInstance(diagnostics.Desktop, "AgentBurn", 1, 0, "Desktop", desk)
        qmlRegisterSingletonInstance(updater.Updater, "AgentBurn", 1, 0, "Updater", upd)
        _env.update(qml=qml, data=data, settings=cfg, desktop=desk, updater=upd, engine=QQmlEngine(), quickshell=own)
        atexit.register(lambda: [_env.pop(k, None) for k in ("root", "component", "engine")])   # before QApplication
    return _env


def main_root():
    """The app's Main.qml, created once per process in the shared engine (hidden windows)."""
    env = qml_env()
    # test_shim replaces the shim's Python global (run working directory), then deletes that directory: restore ours.
    shim._global = env["quickshell"]
    if "root" not in env:
        component = QQmlComponent(env["engine"], QUrl.fromLocalFile(str(env["qml"] / "Main.qml")))
        root = component.create()
        assert root is not None, [e.toString() for e in component.errors()]
        env.update(component=component, root=root)
    return env["root"]


def js(root, code):
    return QQmlExpression(QQmlEngine.contextForObject(root), root, code).evaluate()[0]


def wait_for(cond, seconds=10):
    end = time.monotonic() + seconds
    while not cond() and time.monotonic() < end:
        QCoreApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 50)
    return cond()


def fake(*args, **extra):
    env = {**os.environ, "AGENT_BURN_FAKE_DIR": str(FIXTURES), **extra}
    return subprocess.run([sys.executable, "-m", "agentburn", *args], cwd=APP, env=env,
                          capture_output=True, timeout=30)


class FakeCli(unittest.TestCase):
    def test_summary_ends_today_with_account_observed_now(self):
        r = fake("summary", "--value", "--json", "--no-color")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        today = datetime.date.today().isoformat()
        self.assertEqual(d["daily"][-1]["date"], today)
        self.assertEqual(d["agents"][0]["daily"][-1]["date"], today)
        self.assertEqual(d["subscription"]["period"]["to"], today)
        a = d["claudeAccount"]
        self.assertLess(abs(a["observedAtMs"] - time.time() * 1000), 60000)
        # Resets keep their offset from the reading of the capture.
        self.assertEqual(a["weeklyResetsAtMs"] - a["observedAtMs"], 1792875599646 - 1792714971475)
        self.assertEqual(a["scoped"][0]["resetsAtMs"] - a["observedAtMs"], 1792875600000 - 1792714971475)

    def test_harness_claude(self):
        r = fake("harness", "claude", "--value", "--json", "--no-color")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["plan"], "Max 5×")

    def test_quota_only_reading_observed_now(self):
        # 5-min tick of Burn.qml: light reading, not the full harness (otherwise "unreadable report").
        r = fake("harness", "claude", "--json", "--no-color", AGENT_BURN_QUOTA_ONLY="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        q = json.loads(r.stdout)
        self.assertEqual((q["agent"], q["window"]["windowMinutes"]), ("claude", 10080))
        self.assertLess(abs(q["observedAt"] - time.time() * 1000), 60000)

    def test_harness_without_fixture_fails(self):
        self.assertNotEqual(fake("harness", "codex", "--json").returncode, 0)

    def test_harness_agent_other_than_claude_or_codex_refused(self):
        # The file name comes from argv: "../summary-live" would serve another JSON.
        for args in (("harness",), ("harness", "../summary-live"), ("harness", "gemini", "--json")):
            r = fake(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertEqual(r.stdout, b"", args)


class Startup(unittest.TestCase):
    def test_basic_render_loop_on_linux_unless_chosen(self):
        # Qt 6.12 threaded render loop: crashes in QtWaylandClient when a window is shown. Offscreen
        # (selftest) the basic loop captures the enlarged popover badly, and no Wayland is involved.
        for platform, qpa, preset, loop in (("linux", None, None, "basic"), ("linux", "xcb", None, "basic"),
                                            ("linux", None, "threaded", "threaded"), ("linux", "offscreen", None, None),
                                            ("win32", None, None, None), ("darwin", None, None, None)):
            with mock.patch.dict(os.environ, {"AGENT_BURN_BIN": "agent-burn"}), mock.patch.object(sys, "platform", platform), \
                    mock.patch.object(sys, "argv", ["agentburn"]), mock.patch.object(appmain, "run", return_value=0):
                for name, value in (("QT_QPA_PLATFORM", qpa), ("QSG_RENDER_LOOP", preset)):
                    os.environ.pop(name, None)
                    if value:
                        os.environ[name] = value
                self.assertEqual(appmain.main(), 0)
                self.assertEqual(os.environ.get("QSG_RENDER_LOOP"), loop, (platform, qpa, preset))


class SingleInstance(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "session pipe: cannot be isolated in a test")
    def test_launch_losing_the_lock_waits_for_the_winner_then_exits(self):
        # Two launches at the same moment: the winner holds the lock but is not listening yet; the loser
        # does not become a 2nd instance (2nd icon, duplicate CLI runs), it hands over as soon as the server listens.
        gui()
        mac = sys.platform == "darwin"
        with tempfile.TemporaryDirectory(dir="/tmp" if mac else None) as tmp:   # macOS: socket path ≤ 104 bytes
            rt = Path(tmp) / "rt"
            rt.mkdir(mode=0o700)
            # Linux: the runtime directory; macOS: the cache under HOME.
            name = str(Path(tmp) / "Library" / "Caches" / "AgentBurn" / "AgentBurn.sock" if mac else rt / "AgentBurn.sock")
            Path(name).parent.mkdir(parents=True, exist_ok=True)
            lock = QLockFile(name + ".lock")
            self.assertTrue(lock.tryLock(0))
            env = {**os.environ, "XDG_RUNTIME_DIR": str(rt), "QT_QPA_PLATFORM": "offscreen", "QT_QPA_PLATFORMTHEME": "none",
                   "AGENT_BURN_DATA": tmp, "HOME": tmp,
                   "AGENT_BURN_FAKE_DIR": str(FIXTURES), "AGENT_BURN_BIN": str(APP / "tests" / "fake-agent-burn"),
                   **{v: f"{tmp}/{v}" for v in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME")}}
            loser = subprocess.Popen([sys.executable, "-m", "agentburn"], cwd=APP, env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.addCleanup(lambda: loser.poll() is None and (loser.kill(), loser.wait()))
            wait_for(lambda: False, 1.5)   # the loser has already polled once, in vain
            server, got = QLocalServer(), []
            server.newConnection.connect(lambda: got.append(server.nextPendingConnection()))
            self.assertTrue(server.listen(name), server.errorString())
            self.assertTrue(wait_for(lambda: loser.poll() is not None, 20), "still running: 2nd instance")
            self.assertEqual(loser.returncode, 0)
            self.assertTrue(wait_for(lambda: len(got) == 1, 2))
            server.close()


class WindowSize(unittest.TestCase):
    def test_never_below_the_minimum_unless_the_screen_is_smaller(self):
        dash = main_root().property("dashboard")
        declared = dash.minimumSize()
        self.assertEqual(declared, QSize(900, 600))
        self.addCleanup(dash.setMinimumSize, declared)
        # 1080p screen, 1366×768 at 100%, 1366×768 at 125% (40 px taskbar), 1280×720 at 150%.
        for area, size, minimum in ((QRect(0, 0, 1920, 1040), QSize(1200, 800), QSize(900, 600)),
                                    (QRect(0, 0, 1366, 728), QSize(1200, 680), QSize(900, 600)),
                                    (QRect(0, 0, 1093, 574), QSize(1045, 526), QSize(900, 526)),
                                    (QRect(1920, 0, 853, 440), QSize(805, 392), QSize(805, 392))):
            dash.setMinimumSize(declared)
            appmain.fit(dash, 1200, 800, area)
            self.assertEqual((dash.size(), dash.minimumSize()), (size, minimum), area)
            # Centered, entirely on screen, never smaller than its minimum.
            self.assertTrue(area.contains(dash.geometry()), (area, dash.geometry()))
            self.assertEqual(dash.geometry().center().x() - area.center().x(), 0, area)
            self.assertTrue(dash.width() >= dash.minimumWidth() and dash.height() >= dash.minimumHeight())


class CloseToTray(unittest.TestCase):
    def setUp(self):
        gui()
        self.app, self.tray = mock.Mock(), True
        self.dash, self.prefs = QQuickWindow(), QQuickWindow()
        self.cfg = settings.Settings(None)
        desktop = types.SimpleNamespace(property=lambda name: {"trayAvailable": self.tray}[name])
        appmain.quit_when_closed(self.app, self.dash, self.prefs, self.cfg, desktop)
        for w in (self.dash, self.prefs):   # windows of this test, destroyed afterwards without calling back the app
            self.addCleanup(w.visibleChanged.disconnect)

    def quits(self):
        wait_for(lambda: False, 0.7)   # after the 500 ms round trip of Burn.openDashboard
        return self.app.quit.called

    def test_dashboard_closed_before_settings_still_quits_without_close_to_tray(self):
        self.cfg.closeToTray = False
        self.dash.show()
        self.prefs.show()
        self.dash.hide()
        self.assertFalse(self.quits())   # settings still open
        self.prefs.hide()
        self.assertTrue(self.quits())

    def test_reopened_dashboard_drops_the_intent(self):
        self.cfg.closeToTray = False
        self.prefs.show()
        self.dash.show()
        self.dash.hide()
        self.dash.show()   # Burn.openDashboard: closes then reopens
        self.prefs.hide()
        self.assertFalse(self.quits())

    def test_close_to_tray_stays_unless_there_is_no_tray(self):
        self.dash.show()
        self.dash.hide()
        self.assertFalse(self.quits())
        self.tray = False
        self.prefs.show()
        self.prefs.hide()
        self.assertTrue(self.quits())


SCREEN = QRect(0, 0, 1920, 1080)
CARD = QSize(440, 600)


class Placement(unittest.TestCase):
    def test_bottom_taskbar_card_above_icon_kept_on_screen(self):
        pos, edge = place(QRect(1800, 1044, 24, 24), SCREEN, QRect(0, 0, 1920, 1032), CARD)
        self.assertEqual(edge, Qt.BottomEdge)
        self.assertEqual(pos, QPoint(1920 - 16 - 440, 1032 - 16 - 600))

    def test_bottom_taskbar_centered_on_icon(self):
        pos, _ = place(QRect(988, 1044, 24, 24), SCREEN, QRect(0, 0, 1920, 1032), CARD)
        self.assertEqual(pos, QPoint(1000 - 220, 1032 - 16 - 600))

    def test_top_taskbar(self):
        pos, edge = place(QRect(988, 12, 24, 24), SCREEN, QRect(0, 48, 1920, 1032), CARD)
        self.assertEqual(edge, Qt.TopEdge)
        self.assertEqual(pos, QPoint(1000 - 220, 48 + 16))

    def test_left_taskbar(self):
        pos, edge = place(QRect(12, 900, 24, 24), SCREEN, QRect(48, 0, 1872, 1080), CARD)
        self.assertEqual(edge, Qt.LeftEdge)
        self.assertEqual(pos, QPoint(48 + 16, 1080 - 16 - 600))

    def test_right_taskbar(self):
        pos, edge = place(QRect(1884, 300, 24, 24), SCREEN, QRect(0, 0, 1872, 1080), CARD)
        self.assertEqual(edge, Qt.RightEdge)
        self.assertEqual(pos, QPoint(1872 - 16 - 440, 16))

    def test_autohide_taskbar_goes_by_icon(self):
        pos, edge = place(QRect(1800, 1044, 24, 24), SCREEN, SCREEN, CARD)
        self.assertEqual(edge, Qt.BottomEdge)
        self.assertEqual(pos.y(), 1044 - 16 - 600)

    def test_second_screen(self):
        pos, edge = place(QRect(4400, 1400, 24, 24), QRect(1920, 0, 2560, 1440), QRect(1920, 0, 2560, 1392), CARD)
        self.assertEqual(edge, Qt.BottomEdge)
        self.assertEqual(pos, QPoint(1920 + 2560 - 16 - 440, 1392 - 16 - 600))


class TrayIcon(unittest.TestCase):
    def test_16px_badge_ink_and_grey_flame_without_data(self):
        app = gui()  # noqa: F841 (QPixmap requires it)
        # dark warn, light warn, light good (light in HSL but black has more contrast: 4.78 vs 4.40).
        for tone, ink in (("#ff9f0a", Qt.black), ("#c93400", Qt.white), ("#248a3d", Qt.black)):
            img = pixmap(16, 25, QColor(tone)).toImage()
            px = [img.pixelColor(x, y) for x in range(16) for y in range(16)]
            self.assertIn(QColor(tone), px, tone)    # opaque badge
            self.assertIn(QColor(ink), px, tone)     # highest-contrast digits
        img = pixmap(16, -1, QColor("#98989f")).toImage()
        self.assertIn(QColor("#98989f"), [img.pixelColor(x, y) for x in range(16) for y in range(16)])   # solid flame


class Runtime(unittest.TestCase):
    def test_shared_and_own_qml_with_singletons(self):
        QCoreApplication.setApplicationName("AgentBurn")
        d = runtime.assemble()
        shared = APP.parent / "shared"
        for f in runtime.SHARED:
            self.assertEqual((d / f).read_bytes(), (shared / f).read_bytes(), f)
        self.assertTrue((d / "assets" / "burn" / "claude.png").is_file())
        self.assertTrue((d / "widgets" / "IconImage.qml").is_file())
        q = (d / "qmldir").read_text().splitlines()
        self.assertIn("singleton Burn 1.0 Burn.qml", q)
        self.assertIn("singleton Colors 1.0 Colors.qml", q)
        self.assertIn("BurnPopover 1.0 BurnPopover.qml", q)
        self.assertEqual(runtime.assemble(), d)   # same content → same directory, nothing copied again

    def test_rename_refused_uses_assembled_copy(self):
        # Windows: rename refused while the antivirus holds a file just written. Empty cache
        # on every platform (XDG_CACHE_HOME has no effect on Windows).
        with tempfile.TemporaryDirectory() as cache, mock.patch.object(paths, "cache_dir", return_value=Path(cache)), \
                mock.patch.object(Path, "rename", side_effect=PermissionError(13, "access denied")) as rename:
            d = runtime.assemble()
            self.assertTrue(rename.called)
            self.assertEqual([p.name for p in Path(cache).iterdir()], [d.name])   # the temporary copy, alone
            self.assertTrue((d / "qmldir").is_file())
            self.assertTrue((d / "BurnPopover.qml").is_file())

    def test_tampered_cache_rebuilt(self):
        with tempfile.TemporaryDirectory() as cache, mock.patch.object(paths, "cache_dir", return_value=Path(cache)):
            d = runtime.assemble()
            good = (d / "Burn.qml").read_bytes()
            (d / "Burn.qml").write_bytes(good + b"\n// modified\n")
            self.assertEqual(runtime.assemble(), d)
            self.assertEqual((d / "Burn.qml").read_bytes(), good)
            (d / "Extra.qml").write_text("import QtQuick\nItem {}\n")   # extra file: rebuilt too
            (d / "qmldir").unlink()
            self.assertEqual(runtime.assemble(), d)
            self.assertFalse((d / "Extra.qml").exists())
            self.assertTrue((d / "qmldir").is_file())

    def test_inline_components_not_named_like_a_qt_type(self):
        # PySide types a QML object by its class name: an inline component named like a Qt type (Section,
        # enum QDateTimeEdit.Section) takes that type when Python reaches it, is read out of bounds, and segfaults.
        qt = set()
        for m in (QtCore, QtGui, QtNetwork, QtQml, QtQuick, QtWidgets):
            for c in (getattr(m, n) for n in dir(m)):
                if isinstance(c, type):
                    qt |= {c.__name__} | {v.__name__ for v in vars(c).values() if isinstance(v, type)}
        inline = {n for f in [*(APP / "qml").rglob("*.qml"), *(APP.parent / "shared").glob("*.qml")]
                  for n in re.findall(r"^\s*component (\w+)\s*:", f.read_text(encoding="utf-8"), re.M)}
        self.assertTrue(inline)
        self.assertEqual(inline & qt, set())


class Popover(unittest.TestCase):
    def test_taller_than_screen_scrolls(self):
        env = qml_env()
        component = QQmlComponent(env["engine"], QUrl.fromLocalFile(str(env["qml"] / "PopoverWindow.qml")))
        pop = component.create()
        self.assertIsNotNone(pop, [e.toString() for e in component.errors()])
        pad = pop.property("pad")
        card = pop.height() - 2 * pad
        flick = next(i for i in pop.findChildren(QQuickItem) if i.metaObject().className() == "QQuickFlickable")
        pop.setProperty("maxHeight", card - 50)
        self.assertEqual(pop.height(), card - 50 + 2 * pad)
        self.assertEqual(flick.property("contentHeight") - flick.height(), 50)   # the rest scrolls
        # Offscreen: a single screen, no taskbar; icon in its bottom-right corner.
        a = QGuiApplication.primaryScreen().availableGeometry()
        open_popover(pop, QRect(a.x() + a.width() - 20, a.y() + a.height() - 20, 10, 10))
        self.assertEqual(pop.property("maxHeight"), a.height() - 2 * 16)
        self.assertGreaterEqual(pop.y() + pad, a.y() + 16)
        self.assertLessEqual(pop.y() + pop.height() - pad, a.y() + a.height() - 16)
        del pop, component

    def test_short_screen_keyboard_scrolls_the_card(self):
        # 1366×768 at 125%: the card scrolls. Page Down, End, Home, and Tab brings the control on screen.
        env = qml_env()
        component = QQmlComponent(env["engine"], QUrl.fromLocalFile(str(env["qml"] / "PopoverWindow.qml")))
        pop = component.create()
        self.addCleanup(lambda: (pop.setVisible(False), component))   # component kept: it would destroy the window
        pop.setProperty("maxHeight", 300)
        QMetaObject.invokeMethod(pop, "open")
        self.assertTrue(wait_for(lambda: pop.isVisible() and pop.isActive(), 5))
        flick = next(i for i in pop.findChildren(QQuickItem) if i.metaObject().className() == "QQuickFlickable")
        wait_for(lambda: False, 0.4)
        end = flick.property("contentHeight") - flick.height()
        self.assertGreater(end, 0)
        QTest.keyClick(pop, Qt.Key.Key_PageDown)
        self.assertEqual(flick.property("contentY"), min(end, flick.height() - 40))
        QTest.keyClick(pop, Qt.Key.Key_End)
        self.assertEqual(flick.property("contentY"), end)
        QTest.keyClick(pop, Qt.Key.Key_Home)
        self.assertEqual(flick.property("contentY"), 0)
        last = [i for i in pop.findChildren(QQuickItem) if i.property("activeFocusOnTab") and i.isVisible()][-1]
        last.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        top = last.mapToItem(flick.property("contentItem"), 0, 0).y() - flick.property("contentY")
        self.assertTrue(0 <= top and top + last.height() <= flick.height(), (top, last.height(), flick.height()))


class Autostart(unittest.TestCase):
    def test_entry_disabled_by_windows_shows_off_and_is_reenabled(self):
        reg = {}   # fake winreg: key path → {value: data}

        class Key(dict):
            __enter__ = lambda self: self
            __exit__ = lambda self, *exc: None

        def value(key, name):   # winreg raises FileNotFoundError for a missing value
            if name not in key:
                raise FileNotFoundError(name)
            return key[name]

        fake = types.SimpleNamespace(HKEY_CURRENT_USER=0, KEY_SET_VALUE=2, REG_SZ=1,
                                     OpenKey=lambda root, path, *a: reg.setdefault(path, Key()),
                                     QueryValueEx=lambda key, name: (value(key, name), 3),
                                     DeleteValue=lambda key, name: (value(key, name), key.pop(name)),
                                     SetValueEx=lambda key, name, _, kind, data: key.__setitem__(name, data))
        with mock.patch.dict(sys.modules, {"winreg": fake}):
            sys.modules.pop("agentburn.platform_win", None)
            from agentburn import platform_win as pw
            self.assertFalse(pw.autostart())
            pw.set_autostart(True)
            self.assertTrue(pw.autostart())
            reg[pw.APPROVED][pw.NAME] = bytes([3]) + bytes(11)   # disabled in Task Manager
            self.assertFalse(pw.autostart())
            pw.set_autostart(True)
            self.assertTrue(pw.autostart())
            self.assertNotIn(pw.NAME, reg[pw.APPROVED])
            pw.set_autostart(False)
            self.assertFalse(pw.autostart())
            pw.set_autostart(True)
            reg[pw.APPROVED][pw.NAME] = b""   # empty REG_BINARY: not a disable (no more IndexError)
            self.assertTrue(pw.autostart())


if __name__ == "__main__":
    unittest.main()
