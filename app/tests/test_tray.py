# Tests de l'icône de notification sur le vrai Main.qml (fenêtres hors écran, faux CLI) : libellés et ordre du
# menu, effet de chaque action, coche du démarrage auto, lignes d'état, clics, icône recréée quand une zone
# de notification apparaît, popover laissé au compositeur sous Wayland.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QPoint, QRect  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQuick import QQuickWindow  # noqa: E402
from PySide6.QtWidgets import QSystemTrayIcon  # noqa: E402

from agentburn import settings, tray  # noqa: E402

ACTIONS = ["Ouvrir l'aperçu", "Ouvrir le dashboard", "Rafraîchir", "Lancer à l'ouverture de session", "Paramètres…",
           "Journaux", "À propos", "Quitter"]
R = QSystemTrayIcon.ActivationReason


class TrayIcon(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = main_root()
        js(cls.root, "Burn.refresh(false)")
        assert wait_for(lambda: js(cls.root, "Burn.summary !== null && !Burn.loading"), 30), "rapport du faux CLI"
        cls.pop, cls.dash, cls.prefs = (cls.root.property(n) for n in ("popover", "dashboard", "settingsWindow"))

    def make(self, system=None):
        self.state = {"on": False}
        self.system = system or types.SimpleNamespace(autostart=lambda: self.state["on"],
                                                      set_autostart=lambda on: self.state.update(on=on))
        self.cfg = settings.Settings(None, self.system)
        self.quit = mock.patch.object(tray.QApplication, "quit").start()
        self.addCleanup(mock.patch.stopall)
        t = tray.Tray(self.root, self.cfg, qml_env()["desktop"])
        t.timer.stop()   # zone de notification revérifiée : testée à part
        self.addCleanup(self.hide_all)
        return t

    def hide_all(self):
        js(self.root, "Burn.dashboardOpen = false")
        self.pop.setVisible(False)
        self.prefs.close()
        wait_for(lambda: not js(self.root, "Burn.loading"), 20)

    def actions(self, t):
        return {a.text(): a for a in t.menu.actions() if not a.isSeparator() and a not in t.lines}

    def test_menu_labels_order_and_status_lines(self):
        t = self.make()
        labels = [a.text() for a in t.menu.actions() if not a.isSeparator()]
        self.assertEqual(labels[tray.LINES:], ACTIONS)
        shown = [a for a in t.lines if a.isVisible()]
        self.assertTrue(1 <= len(shown) <= tray.LINES)
        self.assertTrue(all(not a.isEnabled() for a in t.lines))
        # Fixtures : semaine Claude 25 % restant, la plus serrée en tête.
        self.assertRegex(shown[0].text(), r"^Claude Code · Semaine : 25 % restant · réinit\. dans ")

    def test_every_action_has_an_effect(self):
        t = self.make()
        desktop = qml_env()["desktop"]
        a = self.actions(t)
        effects = {
            "Ouvrir l'aperçu": lambda: self.pop.isVisible(),
            "Ouvrir le dashboard": lambda: js(self.root, "Burn.dashboardOpen"),
            "Rafraîchir": lambda: js(self.root, "Burn.updatedAt") > before,
            "Lancer à l'ouverture de session": lambda: self.state["on"],
            "Paramètres…": lambda: self.prefs.isVisible() and self.prefs.property("section") == 0,
            "Journaux": lambda: opened.called,
            "À propos": lambda: self.prefs.isVisible() and self.prefs.property("section") == 3,
            "Quitter": lambda: self.quit.called,
        }
        self.assertEqual(sorted(effects), sorted(a))   # aucune action sans test, aucune de trop
        with mock.patch.object(desktop, "openLogs") as opened:
            for label, done in effects.items():
                self.hide_all()
                before = js(self.root, "Burn.updatedAt")
                self.assertFalse(done(), label)
                a[label].trigger()
                self.assertTrue(wait_for(done, 5), label)

    def test_autostart_item_follows_the_platform(self):
        t = self.make()
        self.assertTrue(t.boot.isEnabled())
        self.state["on"] = True   # changé ailleurs (installeur, bureau)
        t.menu.aboutToShow.emit()
        self.assertTrue(t.boot.isChecked())
        t.boot.trigger()   # décoche
        self.assertFalse(self.state["on"])
        dev = tray.Tray(self.root, settings.Settings(None, None), qml_env()["desktop"])
        dev.timer.stop()
        self.assertFalse(dev.boot.isEnabled())   # dev : pas d'exe installé

    def test_status_lines_without_data(self):
        t = self.make()
        js(self.root, "Burn.summary = null; Burn.account = null")
        shown = [a.text() for a in t.lines if a.isVisible()]
        self.assertEqual(shown, ["Données indisponibles"])
        # CLI en échec : la cause est dans Paramètres (sous Wayland, ces lignes sont tout ce que montre l'icône).
        js(self.root, "Burn.error = 'agent-burn a échoué (code 1) : Permission denied'")
        shown = [a.text() for a in t.lines if a.isVisible()]
        self.assertEqual(shown, ["Données indisponibles : échec du CLI (voir Paramètres › Diagnostic)"])
        self.assertEqual(t.icon.toolTip(), "Agent Burn — Indisponible · échec du CLI (voir Paramètres › Diagnostic)")
        js(self.root, "Burn.error = ''; Burn.refresh(false)")   # données rétablies pour la suite
        self.assertTrue(wait_for(lambda: js(self.root, "Burn.summary !== null"), 20))

    def test_clicks(self):
        t = self.make()
        self.cfg.trayClick = "popover"
        t.clicked(R.Trigger)
        self.assertTrue(wait_for(self.pop.isVisible, 5))
        self.hide_all()
        self.cfg.trayClick = "dashboard"
        t.clicked(R.Trigger)
        self.assertTrue(wait_for(lambda: js(self.root, "Burn.dashboardOpen"), 5))
        self.hide_all()
        self.cfg.trayClick = "popover"
        t.clicked(R.DoubleClick)
        self.assertTrue(wait_for(lambda: js(self.root, "Burn.dashboardOpen"), 5))
        self.hide_all()
        before = js(self.root, "Burn.updatedAt")
        with self.assertLogs("agentburn.tray", "DEBUG") as logs:   # journal détaillé : clics de l'icône
            t.clicked(R.MiddleClick)
        self.assertEqual(logs.output, ["DEBUG:agentburn.tray:icône : MiddleClick"])
        self.assertTrue(wait_for(lambda: js(self.root, "Burn.updatedAt") > before, 20))
        t.clicked(R.Context)   # menu : rien d'autre
        self.assertFalse(self.pop.isVisible())

    def test_icon_recreated_on_xcb_when_a_tray_host_appears(self):
        desktop = qml_env()["desktop"]
        for platform in ("xcb", "wayland"):
            with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=False):
                t = self.make()
                t.timer.start()
                self.assertFalse(t.docked)
                self.assertFalse(desktop.trayAvailable)
                first = t.icon
                t.recheck()
                self.assertIs(t.icon, first)
            with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=True), \
                    mock.patch.object(tray.QGuiApplication, "platformName", return_value=platform):
                t.recheck()
            # xcb : l'icône créée sans hôte reste sur XEmbed ; Wayland : elle s'est enregistrée seule.
            self.assertIs(t.icon is first, platform == "wayland", platform)
            self.assertTrue(t.icon.isVisible())
            self.assertIs(t.icon.contextMenu(), t.menu)
            self.assertTrue(t.docked)
            self.assertTrue(desktop.trayAvailable)
            self.assertTrue(t.timer.isActive())   # suivie encore : un hôte peut disparaître
            desktop.setTrayAvailable(False)

    def test_recheck_keeps_waiting_for_a_late_tray(self):
        # Panneau ou extension AppIndicator activés après 2 min : l'icône s'y enregistre, l'app doit le savoir.
        desktop = qml_env()["desktop"]
        with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=False):
            t = self.make()
            t.timer.start()
            for _ in range(40):   # 200 s
                t.recheck()
            self.assertTrue(t.timer.isActive())
            self.assertFalse(t.docked)
        with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=True):
            t.recheck()
        self.assertTrue(t.docked)
        self.assertTrue(desktop.trayAvailable)
        desktop.setTrayAvailable(False)

    def test_vanished_host_tracked_then_icon_redocked_on_xcb(self):
        # Panneau arrêté : fermer la dernière fenêtre quitte (pas de process invisible) ; revenu, l'icône aussi.
        desktop = qml_env()["desktop"]
        with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=True):
            t = self.make()
        self.assertTrue(desktop.trayAvailable)
        first = t.icon
        with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=False):
            t.recheck()
        self.assertFalse(t.docked)
        self.assertFalse(desktop.trayAvailable)
        with mock.patch.object(QSystemTrayIcon, "isSystemTrayAvailable", return_value=True), \
                mock.patch.object(tray.QGuiApplication, "platformName", return_value="xcb"):
            t.recheck()
        self.assertTrue(t.docked)
        self.assertTrue(desktop.trayAvailable)
        self.assertIsNot(t.icon, first)
        desktop.setTrayAvailable(False)

    def test_wayland_popover_left_to_the_compositor(self):
        self.pop.setPosition(QPoint(7, 9))
        self.pop.setProperty("maxHeight", 0)
        with mock.patch.object(tray.QGuiApplication, "platformName", return_value="wayland"):
            tray.open_popover(self.pop, None)
        self.assertEqual(self.pop.position(), QPoint(7, 9))
        self.assertGreater(self.pop.property("maxHeight"), 0)

    def test_wayland_popover_height_follows_its_own_screen(self):
        # Pointeur à 0,0 sous Wayland : l'écran du popover, pas celui du pointeur ; suivi s'il en change.
        self.make()
        screen = types.SimpleNamespace(availableGeometry=lambda: QRect(0, 0, 1280, 720))
        with mock.patch.object(tray.QGuiApplication, "platformName", return_value="wayland"), \
                mock.patch.object(QQuickWindow, "screen", return_value=screen):
            tray.open_popover(self.pop, None)
            self.assertEqual(self.pop.property("maxHeight"), 720 - 2 * tray.GAP)
            self.pop.setVisible(True)
            screen.availableGeometry = lambda: QRect(1280, 0, 2560, 1400)   # posé sur l'autre écran
            self.pop.screenChanged.emit(QGuiApplication.primaryScreen())
            self.assertEqual(self.pop.property("maxHeight"), 1400 - 2 * tray.GAP)


if __name__ == "__main__":
    unittest.main()
