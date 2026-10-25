# Tests de l'app Windows : faux CLI, position et hauteur du popover, icône, dossier QML d'exécution,
# démarrage avec Windows (registre factice).
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
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

from PySide6.QtCore import QCoreApplication, QPoint, QRect, QSize, Qt, QUrl  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine  # noqa: E402
from PySide6.QtQuick import QQuickItem  # noqa: E402

from agentburn import runtime, shim  # noqa: E402
from agentburn.tray import open_popover, pixmap, place  # noqa: E402


def gui():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    QCoreApplication.setApplicationName("AgentBurn")
    return QGuiApplication.instance() or QGuiApplication([])


def fake(*args):
    env = {**os.environ, "AGENT_BURN_FAKE_DIR": str(FIXTURES)}
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

    def test_harness_without_fixture_fails(self):
        self.assertNotEqual(fake("harness", "codex", "--json").returncode, 0)

    def test_harness_agent_other_than_claude_or_codex_refused(self):
        # Le nom de fichier vient d'argv : « ../summary-live » servirait un autre JSON.
        for args in (("harness",), ("harness", "../summary-live"), ("harness", "gemini", "--json")):
            r = fake(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertEqual(r.stdout, b"", args)


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
        # Windows : renommage refusé tant que l'antivirus tient un fichier qu'on vient d'écrire.
        QCoreApplication.setApplicationName("AgentBurn")
        with tempfile.TemporaryDirectory() as cache, mock.patch.dict(os.environ, {"XDG_CACHE_HOME": cache}), \
                mock.patch.object(Path, "rename", side_effect=PermissionError(13, "accès refusé")):
            d = runtime.assemble()
            self.assertTrue((d / "qmldir").is_file())
            self.assertTrue((d / "BurnPopover.qml").is_file())


class Popover(unittest.TestCase):
    def test_taller_than_screen_scrolls(self):
        app = gui()  # noqa: F841
        data = tempfile.mkdtemp(prefix="agent-burn-test-")
        self.addCleanup(shutil.rmtree, data, True)
        qml = runtime.assemble()
        shim.register(qml, data)
        engine = QQmlEngine()
        component = QQmlComponent(engine, QUrl.fromLocalFile(str(qml / "PopoverWindow.qml")))
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
        del pop, component, engine


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
