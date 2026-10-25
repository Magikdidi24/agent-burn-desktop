# Tests de l'app de bureau : faux CLI, position et hauteur du popover, icône, dossier QML d'exécution
# (cache vérifié), démarrage avec Windows (registre factice). qml_env() sert aussi aux autres modules.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import atexit
import datetime
import json
import os
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

from PySide6.QtCore import QCoreApplication, QEventLoop, QPoint, QRect, QSize, Qt, QUrl  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine, QQmlExpression, qmlRegisterSingletonInstance  # noqa: E402
from PySide6.QtQuick import QQuickItem, QQuickWindow  # noqa: E402,F401 (QQuickWindow : type des fenêtres QML côté Python)
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
        # Boucle à fil de Qt 6.12 : plantages dans QtWaylandClient à l'affichage d'une fenêtre.
        for platform, preset, loop in (("linux", None, "basic"), ("linux", "threaded", "threaded"), ("win32", None, None)):
            with mock.patch.dict(os.environ), mock.patch.object(sys, "platform", platform), \
                    mock.patch.object(sys, "argv", ["agentburn"]), mock.patch.object(appmain, "run", return_value=0):
                os.environ.pop("QSG_RENDER_LOOP", None)
                if preset:
                    os.environ["QSG_RENDER_LOOP"] = preset
                self.assertEqual(appmain.main(), 0)
                self.assertEqual(os.environ.get("QSG_RENDER_LOOP"), loop, platform)


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
        shared = APP.parents[2] / "config" / "quickshell"
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
