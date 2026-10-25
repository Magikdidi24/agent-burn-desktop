# Tests of the Settings window created offscreen with the real runtime QML directory: no QML warning
# on its 4 sections, controls reached by keyboard (Tab), settings changed by the controls, Escape.
#   cd app && python -m unittest discover -s tests -v
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QtMsgType, QRectF, Qt, QUrl, qInstallMessageHandler  # noqa: E402
from PySide6.QtGui import QColor  # noqa: E402
from PySide6.QtQml import QQmlComponent  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402

from agentburn import diagnostics  # noqa: E402

# Noise from the offscreen platform, unrelated to the QML.
PLATFORM = ("This plugin does not support",)


class SettingsWindow(unittest.TestCase):
    def setUp(self):
        self.root = main_root()
        self.win = self.root.property("settingsWindow")
        self.cfg = qml_env()["settings"]
        self.addCleanup(self.cfg.reset)
        self.addCleanup(self.win.close)
        self.messages = []
        qInstallMessageHandler(lambda kind, context, message: kind != QtMsgType.QtDebugMsg
                               and not message.startswith(PLATFORM) and self.messages.append(message))
        self.addCleanup(qInstallMessageHandler, None)

    def open(self, section):
        js(self.root, f"openSettings('{section}')")
        self.assertTrue(wait_for(self.win.isVisible, 5))
        self.settle()

    def settle(self):
        wait_for(lambda: False, 0.3)

    def items(self, cls):
        """Visible items of this type, through the visual tree (Repeater delegates included)."""
        out, todo = [], [self.win.contentItem()]
        while todo:
            item = todo.pop()
            todo += item.childItems()
            if item.inherits(cls) and item.isVisible():
                out.append(item)
        return out

    def region(self, item):
        """Capture of the window cropped to item, 4 px margin (the ring is drawn on its edges)."""
        r = item.mapRectToScene(QRectF(0, 0, item.width(), item.height())).toRect().adjusted(-4, -4, 4, 4)
        return self.win.grabWindow().copy(r)

    def changed_pixels(self, a, b):
        return sum(a.pixel(x, y) != b.pixel(x, y) for x in range(a.width()) for y in range(a.height()))

    def test_keyboard_focus_visible_on_tabs_and_options(self):
        # Fusion draws nothing on a keyboard-focused tab and barely recolors the circle of an option:
        # a real frame changes hundreds of pixels.
        for theme in ("light", "dark"):
            self.cfg.theme = theme
            self.open("general")
            tabs = {i.property("text"): i for i in self.items("QQuickTabButton")}
            options = {i.property("text"): i for i in self.items("QQuickRadioButton")}
            for item, other in ((tabs["Providers"], tabs["General"]), (options["Light"], options["System"])):
                other.forceActiveFocus(Qt.FocusReason.OtherFocusReason)   # focus elsewhere, given by the mouse
                self.settle()
                plain = self.region(item)
                item.forceActiveFocus(Qt.FocusReason.TabFocusReason)
                self.settle()
                self.assertTrue(item.property("visualFocus"))
                self.assertGreater(self.changed_pixels(plain, self.region(item)), 150, (theme, item.property("text")))

    def test_current_tab_underlined_in_accent(self):
        self.open("diagnostic")
        accent = QColor(js(self.root, "Colors.accent.toString()"))
        for tab in self.items("QQuickTabButton"):
            img = self.region(tab)
            row = [QColor(img.pixel(x, img.height() - 6)) for x in range(8, img.width() - 8)]   # bottom of the tab
            self.assertEqual(all(c == accent for c in row), tab.property("text") == "Diagnostics", tab.property("text"))

    def test_component_alone_loads_without_errors(self):
        env = qml_env()
        component = QQmlComponent(env["engine"], QUrl.fromLocalFile(str(env["qml"] / "SettingsWindow.qml")))
        win = component.create()
        self.assertIsNotNone(win, [e.toString() for e in component.errors()])
        win.setProperty("visible", True)
        self.settle()
        win.close()
        del win, component
        self.assertEqual(self.messages, [])

    def test_every_section_renders_without_qml_warnings(self):
        js(self.root, "Burn.note('quota', 'agent-burn returned an unreadable report.')")   # non-empty error list
        for i, section in enumerate(("general", "providers", "diagnostic", "about")):
            self.open(section)
            self.assertEqual(self.win.property("section"), i)
            self.assertFalse(self.win.grabWindow().isNull(), section)
        self.assertEqual(self.messages, [])

    def test_keyboard_reaches_the_controls_and_changes_settings(self):
        self.open("general")
        combo = self.items("QQuickComboBox")[0]
        combo.forceActiveFocus()
        seen = []
        for _ in range(12):
            seen.append({kind for kind in ("ComboBox", "RadioButton", "Switch")
                         if self.win.activeFocusItem().inherits("QQuick" + kind)})
            QTest.keyClick(self.win, Qt.Key.Key_Tab)
        for kind in ("ComboBox", "RadioButton", "Switch"):
            self.assertTrue(any(kind in kinds for kinds in seen), (kind, seen))
        # "Dark" theme by keyboard: focus then Space.
        dark = next(i for i in self.items("QQuickRadioButton") if i.property("text") == "Dark")
        dark.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertTrue(wait_for(lambda: self.cfg.theme == "dark", 2))
        self.assertTrue(js(self.root, "Colors.dark"))
        # Refresh: ComboBox by keyboard (down arrow = next value).
        combo.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Down)
        self.assertTrue(wait_for(lambda: self.cfg.refreshMinutes == 15, 2))
        self.assertEqual(js(self.root, "Burn.refreshInterval"), 15 * 60000)

    def test_opening_a_section_focuses_its_tab_not_a_hidden_control(self):
        # Tray icon menu ("About") while the focus is on a General switch.
        self.open("general")
        switch = next(i for i in self.items("QQuickSwitch") if "system tray" in i.property("text"))
        switch.forceActiveFocus()
        before = self.cfg.closeToTray
        self.open("about")
        focused = self.win.activeFocusItem()
        self.assertTrue(focused.inherits("QQuickTabButton"), focused.metaObject().className())
        self.assertEqual(focused.property("text"), "About")
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.closeToTray, before)

    def test_enter_activates_like_space(self):
        self.open("general")
        before = self.cfg.closeToTray
        switch = next(i for i in self.items("QQuickSwitch") if "system tray" in i.property("text"))
        switch.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(self.cfg.closeToTray, not before)
        dark = next(i for i in self.items("QQuickRadioButton") if i.property("text") == "Dark")
        dark.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Enter)   # numeric keypad
        self.assertEqual(self.cfg.theme, "dark")
        tab = next(i for i in self.items("QQuickTabButton") if i.property("text") == "Diagnostics")
        tab.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(self.win.property("section"), 2)
        self.settle()
        copy = next(i for i in self.items("QQuickButton") if i.property("text") == "Copy diagnostics")
        copy.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(copy.property("text"), "Copied to clipboard")
        self.assertEqual(self.messages, [])

    def test_arrows_move_within_a_row_of_options(self):
        self.open("general")
        options = {i.property("text"): i for i in self.items("QQuickRadioButton")}
        options["System"].forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Right)
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("light", "Light"))
        QTest.keyClick(self.win, Qt.Key.Key_Right)
        QTest.keyClick(self.win, Qt.Key.Key_Right)   # end of the row: nothing more
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("dark", "Dark"))
        QTest.keyClick(self.win, Qt.Key.Key_Left)
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("light", "Light"))
        self.assertTrue(self.win.activeFocusItem().property("visualFocus"))
        options["Dashboard"].forceActiveFocus(Qt.FocusReason.TabFocusReason)   # another row, without spilling over
        QTest.keyClick(self.win, Qt.Key.Key_Left)
        self.assertEqual((self.cfg.trayClick, self.cfg.theme), ("popover", "light"))
        self.assertEqual(self.messages, [])

    def test_unavailable_autostart_switch_looks_disabled(self):
        self.open("general")   # dev: no installed exe, switch disabled
        switch = next(i for i in self.items("QQuickSwitch") if i.property("text") == "Start at login")
        self.assertFalse(switch.isEnabled())
        self.assertLess(switch.opacity(), 1)

    def test_reset_asks_for_a_second_press(self):
        self.cfg.theme = "dark"
        self.open("diagnostic")
        reset = next(i for i in self.items("QQuickButton") if i.property("text") == "Reset settings")
        reset.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.theme, "dark")   # nothing erased on the first press
        self.assertEqual(reset.property("text"), "Confirm reset")
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.theme, "system")
        self.assertEqual(reset.property("text"), "Reset settings")

    def fields(self):
        return {f.property("label"): f.property("value") for f in self.items("QQuickRowLayout") if f.property("label")}

    def test_report_field_gives_the_cli_error(self):
        error = "agent-burn failed (code 1): Permission denied (os error 13)"
        js(self.root, f"Burn.error = '{error}'")
        self.addCleanup(js, self.root, "Burn.error = ''")
        self.open("providers")
        self.assertTrue(self.fields()["Report"].endswith("\n" + error), self.fields()["Report"])

    def test_display_field_in_plain_words(self):
        for platform, desktop, session, shown in (("wayland", "KDE", "wayland", "Wayland (KDE)"),
                                                  ("xcb", "GNOME", "wayland", "X11 (GNOME, Wayland session)"),
                                                  ("windows", "", "", "Windows")):
            with mock.patch.object(diagnostics.QGuiApplication, "platformName", return_value=platform), \
                    mock.patch.dict(os.environ, {"XDG_CURRENT_DESKTOP": desktop, "XDG_SESSION_TYPE": session}):
                self.open("diagnostic")
                self.assertEqual(self.fields()["Display"], shown)
                self.win.close()

    def test_paths_wrap_anywhere(self):
        # Windows path: its only break between words follows "C:", left alone at the end of a line.
        self.open("diagnostic")
        rows = {f.property("label"): f for f in self.items("QQuickRowLayout") if f.property("label")}
        for label in ("Data", "Settings", "Logs", "Cache"):
            value = next(i for i in rows[label].childItems() if i.property("text") == rows[label].property("value"))
            self.assertTrue(js(value, "wrapMode === Text.WrapAnywhere"), label)

    def test_theme_light_drives_colors(self):
        self.cfg.theme = "light"
        self.assertFalse(js(self.root, "Colors.dark"))
        self.cfg.theme = "dark"
        self.assertTrue(js(self.root, "Colors.dark"))

    def test_secondary_text_readable_in_both_themes(self):
        # Secondary text (Colors.muted) at least 4.5:1 on the background and on the cards (settings groups).
        for theme in ("light", "dark"):
            self.cfg.theme = theme
            for surface in ("Colors.background", "card"):   # card: property of the window
                ratio = js(self.win, f"Colors.contrast(Colors.muted, {surface})")
                self.assertGreaterEqual(ratio, 4.5, (theme, surface))

    def test_escape_closes_but_first_closes_an_open_list(self):
        self.open("general")
        combo = self.items("QQuickComboBox")[0]
        opened = lambda: js(combo, "popup.visible")   # noqa: E731 (QQuickPopup has no PySide conversion)
        combo.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Space)   # Space opens the list
        self.assertTrue(wait_for(opened, 2))
        QTest.keyClick(self.win, Qt.Key.Key_Escape)
        self.assertTrue(wait_for(lambda: not opened(), 2))
        self.assertTrue(self.win.isVisible())
        QTest.keyClick(self.win, Qt.Key.Key_Escape)
        self.assertTrue(wait_for(lambda: not self.win.isVisible(), 2))


if __name__ == "__main__":
    unittest.main()
