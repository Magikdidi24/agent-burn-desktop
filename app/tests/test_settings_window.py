# Tests de la fenêtre Paramètres créée hors écran avec le vrai dossier QML d'exécution : aucun avertissement
# QML sur ses 4 sections, contrôles atteints au clavier (Tab), réglages modifiés par les contrôles, Échap.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QtMsgType, QRectF, Qt, QUrl, qInstallMessageHandler  # noqa: E402
from PySide6.QtGui import QColor  # noqa: E402
from PySide6.QtQml import QQmlComponent  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402

# Bruit de la plateforme hors écran, sans rapport avec le QML.
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
        """Éléments visibles de ce type, par l'arbre visuel (délégués des Repeater compris)."""
        out, todo = [], [self.win.contentItem()]
        while todo:
            item = todo.pop()
            todo += item.childItems()
            if item.inherits(cls) and item.isVisible():
                out.append(item)
        return out

    def region(self, item):
        """Capture de la fenêtre réduite à item, 4 px de marge (anneau tracé sur ses bords)."""
        r = item.mapRectToScene(QRectF(0, 0, item.width(), item.height())).toRect().adjusted(-4, -4, 4, 4)
        return self.win.grabWindow().copy(r)

    def changed_pixels(self, a, b):
        return sum(a.pixel(x, y) != b.pixel(x, y) for x in range(a.width()) for y in range(a.height()))

    def test_keyboard_focus_visible_on_tabs_and_options(self):
        # Fusion ne dessine rien sur un onglet focalisé au clavier et recolore à peine le cercle d'une option :
        # un vrai cadre change des centaines de pixels.
        for theme in ("light", "dark"):
            self.cfg.theme = theme
            self.open("general")
            tabs = {i.property("text"): i for i in self.items("QQuickTabButton")}
            options = {i.property("text"): i for i in self.items("QQuickRadioButton")}
            for item, other in ((tabs["Fournisseurs"], tabs["Général"]), (options["Clair"], options["Système"])):
                other.forceActiveFocus(Qt.FocusReason.OtherFocusReason)   # focus ailleurs, donné à la souris
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
            row = [QColor(img.pixel(x, img.height() - 6)) for x in range(8, img.width() - 8)]   # bas de l'onglet
            self.assertEqual(all(c == accent for c in row), tab.property("text") == "Diagnostic", tab.property("text"))

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
        js(self.root, "Burn.note('quota', 'Rapport illisible renvoyé par agent-burn.')")   # liste d'erreurs non vide
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
        # Thème « Sombre » au clavier : focus puis Espace.
        dark = next(i for i in self.items("QQuickRadioButton") if i.property("text") == "Sombre")
        dark.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertTrue(wait_for(lambda: self.cfg.theme == "dark", 2))
        self.assertTrue(js(self.root, "Colors.dark"))
        # Rafraîchissement : ComboBox au clavier (flèche bas = valeur suivante).
        combo.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Down)
        self.assertTrue(wait_for(lambda: self.cfg.refreshMinutes == 15, 2))
        self.assertEqual(js(self.root, "Burn.refreshInterval"), 15 * 60000)

    def test_opening_a_section_focuses_its_tab_not_a_hidden_control(self):
        # Menu de l'icône (« À propos ») pendant que le focus est sur un interrupteur de Général.
        self.open("general")
        switch = next(i for i in self.items("QQuickSwitch") if "zone de notification" in i.property("text"))
        switch.forceActiveFocus()
        before = self.cfg.closeToTray
        self.open("about")
        focused = self.win.activeFocusItem()
        self.assertTrue(focused.inherits("QQuickTabButton"), focused.metaObject().className())
        self.assertEqual(focused.property("text"), "À propos")
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.closeToTray, before)

    def test_enter_activates_like_space(self):
        self.open("general")
        before = self.cfg.closeToTray
        switch = next(i for i in self.items("QQuickSwitch") if "zone de notification" in i.property("text"))
        switch.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(self.cfg.closeToTray, not before)
        dark = next(i for i in self.items("QQuickRadioButton") if i.property("text") == "Sombre")
        dark.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Enter)   # pavé numérique
        self.assertEqual(self.cfg.theme, "dark")
        tab = next(i for i in self.items("QQuickTabButton") if i.property("text") == "Diagnostic")
        tab.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(self.win.property("section"), 2)
        self.settle()
        copy = next(i for i in self.items("QQuickButton") if i.property("text") == "Copier le diagnostic")
        copy.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Return)
        self.assertEqual(copy.property("text"), "Copié dans le presse-papiers")
        self.assertEqual(self.messages, [])

    def test_arrows_move_within_a_row_of_options(self):
        self.open("general")
        options = {i.property("text"): i for i in self.items("QQuickRadioButton")}
        options["Système"].forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Right)
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("light", "Clair"))
        QTest.keyClick(self.win, Qt.Key.Key_Right)
        QTest.keyClick(self.win, Qt.Key.Key_Right)   # bout de la rangée : rien de plus
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("dark", "Sombre"))
        QTest.keyClick(self.win, Qt.Key.Key_Left)
        self.assertEqual((self.cfg.theme, self.win.activeFocusItem().property("text")), ("light", "Clair"))
        self.assertTrue(self.win.activeFocusItem().property("visualFocus"))
        options["Dashboard"].forceActiveFocus(Qt.FocusReason.TabFocusReason)   # autre rangée, sans déborder
        QTest.keyClick(self.win, Qt.Key.Key_Left)
        self.assertEqual((self.cfg.trayClick, self.cfg.theme), ("popover", "light"))
        self.assertEqual(self.messages, [])

    def test_unavailable_autostart_switch_looks_disabled(self):
        self.open("general")   # dev : pas d'exe installé, interrupteur inactif
        switch = next(i for i in self.items("QQuickSwitch") if i.property("text") == "Lancer à l'ouverture de session")
        self.assertFalse(switch.isEnabled())
        self.assertLess(switch.opacity(), 1)

    def test_reset_asks_for_a_second_press(self):
        self.cfg.theme = "dark"
        self.open("diagnostic")
        reset = next(i for i in self.items("QQuickButton") if i.property("text") == "Réinitialiser les paramètres")
        reset.forceActiveFocus(Qt.FocusReason.TabFocusReason)
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.theme, "dark")   # rien d'effacé au premier appui
        self.assertEqual(reset.property("text"), "Confirmer la réinitialisation")
        QTest.keyClick(self.win, Qt.Key.Key_Space)
        self.assertEqual(self.cfg.theme, "system")
        self.assertEqual(reset.property("text"), "Réinitialiser les paramètres")

    def fields(self):
        return {f.property("label"): f.property("value") for f in self.items("QQuickRowLayout") if f.property("label")}

    def test_report_field_gives_the_cli_error(self):
        error = "agent-burn a échoué (code 1) : Permission denied (os error 13)"
        js(self.root, f"Burn.error = '{error}'")
        self.addCleanup(js, self.root, "Burn.error = ''")
        self.open("providers")
        self.assertTrue(self.fields()["Rapport"].endswith("\n" + error), self.fields()["Rapport"])

    def test_theme_light_drives_colors(self):
        self.cfg.theme = "light"
        self.assertFalse(js(self.root, "Colors.dark"))
        self.cfg.theme = "dark"
        self.assertTrue(js(self.root, "Colors.dark"))

    def test_secondary_text_readable_in_both_themes(self):
        # Texte secondaire (Colors.muted) à 4,5:1 au moins sur le fond et sur les cartes (groupes des réglages).
        for theme in ("light", "dark"):
            self.cfg.theme = theme
            for surface in ("Colors.background", "card"):   # card : propriété de la fenêtre
                ratio = js(self.win, f"Colors.contrast(Colors.muted, {surface})")
                self.assertGreaterEqual(ratio, 4.5, (theme, surface))

    def test_escape_closes_but_first_closes_an_open_list(self):
        self.open("general")
        combo = self.items("QQuickComboBox")[0]
        opened = lambda: js(combo, "popup.visible")   # noqa: E731 (QQuickPopup sans conversion PySide)
        combo.forceActiveFocus()
        QTest.keyClick(self.win, Qt.Key.Key_Space)   # Espace ouvre la liste
        self.assertTrue(wait_for(opened, 2))
        QTest.keyClick(self.win, Qt.Key.Key_Escape)
        self.assertTrue(wait_for(lambda: not opened(), 2))
        self.assertTrue(self.win.isVisible())
        QTest.keyClick(self.win, Qt.Key.Key_Escape)
        self.assertTrue(wait_for(lambda: not self.win.isVisible(), 2))


if __name__ == "__main__":
    unittest.main()
