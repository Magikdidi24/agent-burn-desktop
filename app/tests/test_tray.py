# Tray icon tests on the real Main.qml (offscreen windows, fake CLI): menu labels and order,
# effect of each action, autostart check mark, status lines, update item, clicks, icon recreated when a
# system tray appears, popover left to the compositor on Wayland.
#   cd app && python -m unittest discover -s tests -v
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import APP, js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QPoint, QRect  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQuick import QQuickWindow  # noqa: E402
from PySide6.QtWidgets import QSystemTrayIcon  # noqa: E402

from agentburn import settings, tray, updater  # noqa: E402

ACTIONS = ["Update to Agent Burn 9.9.9", "Open popover", "Open dashboard", "Refresh", "Start at login", "Settings…",
           "Logs", "About", "Quit"]
R = QSystemTrayIcon.ActivationReason


class TrayIcon(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = main_root()
        js(cls.root, "Burn.refresh(false)")
        assert wait_for(lambda: js(cls.root, "Burn.summary !== null && !Burn.loading"), 30), "fake CLI report"
        cls.pop, cls.dash, cls.prefs = (cls.root.property(n) for n in ("popover", "dashboard", "settingsWindow"))

    def make(self, system=None):
        self.state = {"on": False}
        self.system = system or types.SimpleNamespace(autostart=lambda: self.state["on"],
                                                      set_autostart=lambda on: self.state.update(on=on))
        self.cfg = settings.Settings(None, self.system)
        self.upd = updater.Updater("dev", APP, self.cfg)   # dev: never a request; an update shown as found
        self.offer("available")
        self.quit = mock.patch.object(tray.QApplication, "quit").start()
        self.addCleanup(mock.patch.stopall)
        t = tray.Tray(self.root, self.cfg, qml_env()["desktop"], self.upd)
        t.timer.stop()   # system tray checked again: tested separately
        self.addCleanup(self.hide_all)
        return t

    def offer(self, state, version="9.9.9"):
        self.upd._state, self.upd._version = state, version
        self.upd.changed.emit()

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
        # Fixtures: Claude week 25% left, the tightest first.
        self.assertRegex(shown[0].text(), r"^Claude Code · Week: 25% left · resets in ")

    def test_every_action_has_an_effect(self):
        t = self.make()
        desktop = qml_env()["desktop"]
        a = self.actions(t)
        effects = {
            "Update to Agent Burn 9.9.9": lambda: updated.called,
            "Open popover": lambda: self.pop.isVisible(),
            "Open dashboard": lambda: js(self.root, "Burn.dashboardOpen"),
            "Refresh": lambda: js(self.root, "Burn.updatedAt") > before,
            "Start at login": lambda: self.state["on"],
            "Settings…": lambda: self.prefs.isVisible() and self.prefs.property("section") == 0,
            "Logs": lambda: opened.called,
            "About": lambda: self.prefs.isVisible() and self.prefs.property("section") == 3,
            "Quit": lambda: self.quit.called,
        }
        self.assertEqual(sorted(effects), sorted(a))   # no action without a test, none extra
        with mock.patch.object(desktop, "openLogs") as opened, mock.patch.object(self.upd, "update") as updated:
            for label, done in effects.items():
                self.hide_all()
                before = js(self.root, "Burn.updatedAt")
                self.assertFalse(done(), label)
                a[label].trigger()
                self.assertTrue(wait_for(done, 5), label)

    def test_autostart_item_follows_the_platform(self):
        t = self.make()
        self.assertTrue(t.boot.isEnabled())
        self.state["on"] = True   # changed elsewhere (installer, desktop)
        t.menu.aboutToShow.emit()
        self.assertTrue(t.boot.isChecked())
        t.boot.trigger()   # unchecks
        self.assertFalse(self.state["on"])
        dev = tray.Tray(self.root, settings.Settings(None, None), qml_env()["desktop"], qml_env()["updater"])
        dev.timer.stop()
        self.assertFalse(dev.boot.isEnabled())   # dev: no installed exe

    def test_update_announced_once_per_version(self):
        with mock.patch.object(tray.QSystemTrayIcon, "showMessage") as shown:
            self.make()   # found before the icon existed
            self.offer("current")
            self.offer("available")
            self.assertEqual(shown.call_count, 1)
            self.offer("available", "10.0.0")
        self.assertEqual([c.args[0] for c in shown.call_args_list],
                         ["Agent Burn 9.9.9 is available", "Agent Burn 10.0.0 is available"])

    def test_update_item_only_while_an_update_is_available(self):
        t = self.make()
        self.assertTrue(t.upgrade.isVisible())
        for state in ("", "checking", "current", "downloading", "installing", "error"):
            self.offer(state)
            self.assertFalse(t.upgrade.isVisible(), state)
        self.offer("available", "10.0.0")
        self.assertEqual((t.upgrade.isVisible(), t.upgrade.text()), (True, "Update to Agent Burn 10.0.0"))

    def test_status_lines_without_data(self):
        t = self.make()
        js(self.root, "Burn.summary = null; Burn.account = null")
        shown = [a.text() for a in t.lines if a.isVisible()]
        self.assertEqual(shown, ["Data unavailable"])
        # CLI failed: the cause is in Settings (on Wayland, these lines are all the icon shows).
        js(self.root, "Burn.error = 'agent-burn failed (code 1): Permission denied'")
        shown = [a.text() for a in t.lines if a.isVisible()]
        self.assertEqual(shown, ["Data unavailable: CLI failed (see Settings › Diagnostics)"])
        self.assertEqual(t.icon.toolTip(), "Agent Burn — Unavailable · CLI failed (see Settings › Diagnostics)")
        js(self.root, "Burn.error = ''; Burn.refresh(false)")   # data restored for the next tests
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
        with self.assertLogs("agentburn.tray", "DEBUG") as logs:   # detailed log: icon clicks
            t.clicked(R.MiddleClick)
        self.assertEqual(logs.output, ["DEBUG:agentburn.tray:icon: MiddleClick"])
        self.assertTrue(wait_for(lambda: js(self.root, "Burn.updatedAt") > before, 20))
        t.clicked(R.Context)   # menu: nothing else
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
            # xcb: the icon created without a host stays on XEmbed; Wayland: it registered by itself.
            self.assertIs(t.icon is first, platform == "wayland", platform)
            self.assertTrue(t.icon.isVisible())
            self.assertIs(t.icon.contextMenu(), t.menu)
            self.assertTrue(t.docked)
            self.assertTrue(desktop.trayAvailable)
            self.assertTrue(t.timer.isActive())   # still tracked: a host can disappear
            desktop.setTrayAvailable(False)

    def test_recheck_keeps_waiting_for_a_late_tray(self):
        # Panel or AppIndicator extension enabled after 2 min: the icon registers with it, the app must know.
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
        # Panel stopped: closing the last window quits (no invisible process); once it is back, so is the icon.
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
        # Pointer at 0,0 on Wayland: the popover's screen, not the pointer's; followed if it changes.
        self.make()
        screen = types.SimpleNamespace(availableGeometry=lambda: QRect(0, 0, 1280, 720))
        with mock.patch.object(tray.QGuiApplication, "platformName", return_value="wayland"), \
                mock.patch.object(QQuickWindow, "screen", return_value=screen):
            tray.open_popover(self.pop, None)
            self.assertEqual(self.pop.property("maxHeight"), 720 - 2 * tray.GAP)
            self.pop.setVisible(True)
            screen.availableGeometry = lambda: QRect(1280, 0, 2560, 1400)   # placed on the other screen
            self.pop.screenChanged.emit(QGuiApplication.primaryScreen())
            self.assertEqual(self.pop.property("maxHeight"), 1400 - 2 * tray.GAP)


if __name__ == "__main__":
    unittest.main()
