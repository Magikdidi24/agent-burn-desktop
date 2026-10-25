# Tests de la fenêtre Paramètres créée hors écran avec le vrai dossier QML d'exécution : aucun avertissement
# QML sur ses 4 sections, contrôles atteints au clavier (Tab), réglages modifiés par les contrôles, Échap.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import js, main_root, qml_env, wait_for  # noqa: E402

from PySide6.QtCore import QtMsgType, Qt, QUrl, qInstallMessageHandler  # noqa: E402
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
            seen.append(self.win.activeFocusItem().metaObject().className())
            QTest.keyClick(self.win, Qt.Key.Key_Tab)
        for kind in ("ComboBox", "RadioButton", "Switch"):
            self.assertTrue(any(kind in name for name in seen), (kind, seen))
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
