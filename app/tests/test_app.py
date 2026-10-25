# Tests de l'app de bureau : faux CLI, position et hauteur du popover, icône, dossier QML d'exécution
# (cache vérifié), démarrage avec Windows (registre factice). qml_env() sert aussi aux autres modules.
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
from PySide6.QtQuick import QQuickItem, QQuickWindow  # noqa: E402,F401 (QQuickWindow : type des fenêtres QML côté Python)
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from agentburn import __main__ as appmain, diagnostics, paths, runtime, settings, shim  # noqa: E402
from agentburn.tray import open_popover, pixmap, place  # noqa: E402


def gui():
    # QApplication (menus de l'icône) ; moteur logiciel : fenêtres affichables hors écran, sans OpenGL.
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ.setdefault("QT_QUICK_BACKEND", "software")
    QCoreApplication.setApplicationName("AgentBurn")
    return QApplication.instance() or QApplication([])


_env = {}


def qml_env():
    """Dossier QML d'exécution, types du shim et singletons Settings/Desktop enregistrés une seule fois par
    process (un 2e enregistrement rend les types incompatibles), et le seul moteur qui puisse lire ces
    singletons (instances enregistrées : un 2e moteur reçoit null). Faux CLI : jamais le vrai CLI ni le vrai HOME."""
    if not _env:
        gui()
        data = Path(tempfile.mkdtemp(prefix="agent-burn-test-"))
        atexit.register(shutil.rmtree, data, True)
        cli = APP / "tests" / "fake-agent-burn"
        if sys.platform == "win32":   # script sh inutilisable : le même faux CLI par un .cmd
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
        qmlRegisterSingletonInstance(settings.Settings, "AgentBurn", 1, 0, "Settings", cfg)
        qmlRegisterSingletonInstance(diagnostics.Desktop, "AgentBurn", 1, 0, "Desktop", desk)
        _env.update(qml=qml, data=data, settings=cfg, desktop=desk, engine=QQmlEngine(), quickshell=own)
        atexit.register(lambda: [_env.pop(k, None) for k in ("root", "component", "engine")])   # avant QApplication
    return _env


def main_root():
    """Main.qml de l'app, créé une fois par process dans le moteur partagé (fenêtres cachées)."""
    env = qml_env()
    # test_shim remplace le global Python du shim (dossier courant des runs) puis efface son dossier : le nôtre.
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
        # Les resets gardent leur écart au relevé de la capture.
        self.assertEqual(a["weeklyResetsAtMs"] - a["observedAtMs"], 1792875599646 - 1792714971475)
        self.assertEqual(a["scoped"][0]["resetsAtMs"] - a["observedAtMs"], 1792875600000 - 1792714971475)

    def test_harness_claude(self):
        r = fake("harness", "claude", "--value", "--json", "--no-color")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["plan"], "Max 5×")

    def test_quota_only_reading_observed_now(self):
        # Tick de 5 min de Burn.qml : relevé léger, pas le harness complet (sinon « Rapport illisible »).
        r = fake("harness", "claude", "--json", "--no-color", AGENT_BURN_QUOTA_ONLY="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        q = json.loads(r.stdout)
        self.assertEqual((q["agent"], q["window"]["windowMinutes"]), ("claude", 10080))
        self.assertLess(abs(q["observedAt"] - time.time() * 1000), 60000)

    def test_harness_without_fixture_fails(self):
        self.assertNotEqual(fake("harness", "codex", "--json").returncode, 0)

    def test_harness_agent_other_than_claude_or_codex_refused(self):
        # Le nom de fichier vient d'argv : « ../summary-live » servirait un autre JSON.
        for args in (("harness",), ("harness", "../summary-live"), ("harness", "gemini", "--json")):
            r = fake(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertEqual(r.stdout, b"", args)


class Startup(unittest.TestCase):
    def test_basic_render_loop_on_linux_unless_chosen(self):
        # Boucle à fil de Qt 6.12 : plantages dans QtWaylandClient à l'affichage d'une fenêtre. Hors écran
        # (selftest) la boucle basique capture mal le popover agrandi, et il n'y a rien de Wayland.
        for platform, qpa, preset, loop in (("linux", None, None, "basic"), ("linux", "xcb", None, "basic"),
                                            ("linux", None, "threaded", "threaded"), ("linux", "offscreen", None, None),
                                            ("win32", None, None, None)):
            with mock.patch.dict(os.environ, {"AGENT_BURN_BIN": "agent-burn"}), mock.patch.object(sys, "platform", platform), \
                    mock.patch.object(sys, "argv", ["agentburn"]), mock.patch.object(appmain, "run", return_value=0):
                for name, value in (("QT_QPA_PLATFORM", qpa), ("QSG_RENDER_LOOP", preset)):
                    os.environ.pop(name, None)
                    if value:
                        os.environ[name] = value
                self.assertEqual(appmain.main(), 0)
                self.assertEqual(os.environ.get("QSG_RENDER_LOOP"), loop, (platform, qpa, preset))


class SingleInstance(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "pipe de la session : pas isolable dans un test")
    def test_launch_losing_the_lock_waits_for_the_winner_then_exits(self):
        # Deux lancements au même instant : le gagnant tient le verrou mais n'écoute pas encore ; le perdant
        # ne devient pas une 2e instance (2e icône, CLI en double), il passe la main dès que le serveur écoute.
        gui()
        with tempfile.TemporaryDirectory() as tmp:
            rt = Path(tmp) / "rt"
            rt.mkdir(mode=0o700)
            name = str(rt / "AgentBurn.sock")
            lock = QLockFile(name + ".lock")
            self.assertTrue(lock.tryLock(0))
            env = {**os.environ, "XDG_RUNTIME_DIR": str(rt), "QT_QPA_PLATFORM": "offscreen", "QT_QPA_PLATFORMTHEME": "none",
                   "AGENT_BURN_DATA": tmp,
                   "AGENT_BURN_FAKE_DIR": str(FIXTURES), "AGENT_BURN_BIN": str(APP / "tests" / "fake-agent-burn"),
                   **{v: f"{tmp}/{v}" for v in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME")}}
            loser = subprocess.Popen([sys.executable, "-m", "agentburn"], cwd=APP, env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.addCleanup(lambda: loser.poll() is None and (loser.kill(), loser.wait()))
            wait_for(lambda: False, 1.5)   # le perdant a déjà sondé une fois, en vain
            server, got = QLocalServer(), []
            server.newConnection.connect(lambda: got.append(server.nextPendingConnection()))
            self.assertTrue(server.listen(name), server.errorString())
            self.assertTrue(wait_for(lambda: loser.poll() is not None, 20), "toujours lancé : 2e instance")
            self.assertEqual(loser.returncode, 0)
            self.assertTrue(wait_for(lambda: len(got) == 1, 2))
            server.close()


class WindowSize(unittest.TestCase):
    def test_never_below_the_minimum_unless_the_screen_is_smaller(self):
        dash = main_root().property("dashboard")
        declared = dash.minimumSize()
        self.assertEqual(declared, QSize(900, 600))
        self.addCleanup(dash.setMinimumSize, declared)
        # Écran 1080p, 1366×768 à 100 %, 1366×768 à 125 % (barre de 40 px), 1280×720 à 150 %.
        for area, size, minimum in ((QRect(0, 0, 1920, 1040), QSize(1200, 800), QSize(900, 600)),
                                    (QRect(0, 0, 1366, 728), QSize(1200, 680), QSize(900, 600)),
                                    (QRect(0, 0, 1093, 574), QSize(1045, 526), QSize(900, 526)),
                                    (QRect(1920, 0, 853, 440), QSize(805, 392), QSize(805, 392))):
            dash.setMinimumSize(declared)
            appmain.fit(dash, 1200, 800, area)
            self.assertEqual((dash.size(), dash.minimumSize()), (size, minimum), area)
            # Centrée, tout entière dans l'écran, jamais plus petite que son minimum.
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
        for w in (self.dash, self.prefs):   # fenêtres de ce test détruites ensuite sans rappeler l'app
            self.addCleanup(w.visibleChanged.disconnect)

    def quits(self):
        wait_for(lambda: False, 0.7)   # après les 500 ms de l'aller-retour de Burn.openDashboard
        return self.app.quit.called

    def test_dashboard_closed_before_settings_still_quits_without_close_to_tray(self):
        self.cfg.closeToTray = False
        self.dash.show()
        self.prefs.show()
        self.dash.hide()
        self.assertFalse(self.quits())   # réglages encore ouverts
        self.prefs.hide()
        self.assertTrue(self.quits())

    def test_reopened_dashboard_drops_the_intent(self):
        self.cfg.closeToTray = False
        self.prefs.show()
        self.dash.show()
        self.dash.hide()
        self.dash.show()   # Burn.openDashboard : referme puis rouvre
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
        app = gui()  # noqa: F841 (QPixmap l'exige)
        # warn sombre, warn clair, good clair (clair en HSL mais noir plus contrasté : 4,78 contre 4,40).
        for tone, ink in (("#ff9f0a", Qt.black), ("#c93400", Qt.white), ("#248a3d", Qt.black)):
            img = pixmap(16, 25, QColor(tone)).toImage()
            px = [img.pixelColor(x, y) for x in range(16) for y in range(16)]
            self.assertIn(QColor(tone), px, tone)    # pastille opaque
            self.assertIn(QColor(ink), px, tone)     # chiffres les plus contrastés
        img = pixmap(16, -1, QColor("#98989f")).toImage()
        self.assertIn(QColor("#98989f"), [img.pixelColor(x, y) for x in range(16) for y in range(16)])   # flamme pleine


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
        self.assertEqual(runtime.assemble(), d)   # même contenu → même dossier, rien de recopié

    def test_rename_refused_uses_assembled_copy(self):
        # Windows : renommage refusé tant que l'antivirus tient un fichier qu'on vient d'écrire. Cache vide
        # sur toute plateforme (XDG_CACHE_HOME ne joue pas sous Windows).
        with tempfile.TemporaryDirectory() as cache, mock.patch.object(paths, "cache_dir", return_value=Path(cache)), \
                mock.patch.object(Path, "rename", side_effect=PermissionError(13, "accès refusé")) as rename:
            d = runtime.assemble()
            self.assertTrue(rename.called)
            self.assertEqual([p.name for p in Path(cache).iterdir()], [d.name])   # la copie temporaire, seule
            self.assertTrue((d / "qmldir").is_file())
            self.assertTrue((d / "BurnPopover.qml").is_file())

    def test_tampered_cache_rebuilt(self):
        with tempfile.TemporaryDirectory() as cache, mock.patch.object(paths, "cache_dir", return_value=Path(cache)):
            d = runtime.assemble()
            good = (d / "Burn.qml").read_bytes()
            (d / "Burn.qml").write_bytes(good + b"\n// modifie\n")
            self.assertEqual(runtime.assemble(), d)
            self.assertEqual((d / "Burn.qml").read_bytes(), good)
            (d / "Extra.qml").write_text("import QtQuick\nItem {}\n")   # fichier en plus : reconstruit aussi
            (d / "qmldir").unlink()
            self.assertEqual(runtime.assemble(), d)
            self.assertFalse((d / "Extra.qml").exists())
            self.assertTrue((d / "qmldir").is_file())

    def test_inline_components_not_named_like_a_qt_type(self):
        # PySide type un objet QML par son nom de classe : un composant inline nommé comme un type Qt (Section,
        # enum QDateTimeEdit.Section) prend ce type quand Python l'atteint, lu hors limites, et segfault.
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
        self.assertEqual(flick.property("contentHeight") - flick.height(), 50)   # le reste défile
        # Hors écran : un seul écran, sans barre des tâches ; icône dans son coin bas droit.
        a = QGuiApplication.primaryScreen().availableGeometry()
        open_popover(pop, QRect(a.x() + a.width() - 20, a.y() + a.height() - 20, 10, 10))
        self.assertEqual(pop.property("maxHeight"), a.height() - 2 * 16)
        self.assertGreaterEqual(pop.y() + pad, a.y() + 16)
        self.assertLessEqual(pop.y() + pop.height() - pad, a.y() + a.height() - 16)
        del pop, component

    def test_short_screen_keyboard_scrolls_the_card(self):
        # 1366×768 à 125 % : la carte défile. Page suivante, Fin, Début, et Tab amène le contrôle à l'écran.
        env = qml_env()
        component = QQmlComponent(env["engine"], QUrl.fromLocalFile(str(env["qml"] / "PopoverWindow.qml")))
        pop = component.create()
        self.addCleanup(lambda: (pop.setVisible(False), component))   # composant gardé : il détruirait la fenêtre
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
        reg = {}   # winreg factice : chemin de clé → {valeur: données}

        class Key(dict):
            __enter__ = lambda self: self
            __exit__ = lambda self, *exc: None

        def value(key, name):   # winreg lève FileNotFoundError pour une valeur absente
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
            reg[pw.APPROVED][pw.NAME] = bytes([3]) + bytes(11)   # désactivée dans le Gestionnaire des tâches
            self.assertFalse(pw.autostart())
            pw.set_autostart(True)
            self.assertTrue(pw.autostart())
            self.assertNotIn(pw.NAME, reg[pw.APPROVED])
            pw.set_autostart(False)
            self.assertFalse(pw.autostart())
            pw.set_autostart(True)
            reg[pw.APPROVED][pw.NAME] = b""   # REG_BINARY vide : pas une désactivation (plus d'IndexError)
            self.assertTrue(pw.autostart())


if __name__ == "__main__":
    unittest.main()
