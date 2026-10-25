# Tests des réglages : défauts (clic de l'icône selon la plateforme), valeurs invalides, fichier illisible
# (copie .bak), aller-retour sur disque, réinitialisation, démarrage auto par le module de la plateforme.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import gui  # noqa: E402

from agentburn import settings  # noqa: E402
from agentburn.settings import Settings  # noqa: E402


class Defaults(unittest.TestCase):
    def setUp(self):
        gui()

    def test_defaults_and_tray_click_per_platform(self):
        s = Settings(None)
        self.assertEqual((s.refreshMinutes, s.theme, s.closeToTray, s.debugLogging), (5, "system", True, False))
        self.assertFalse(s.recovered)
        for platform, click in (("wayland", "dashboard"), ("xcb", "popover"), ("windows", "popover")):
            with mock.patch.object(settings.QGuiApplication, "platformName", return_value=platform):
                self.assertEqual(Settings(None).trayClick, click, platform)

    def test_in_memory_without_system_autostart(self):
        s = Settings(None)
        self.assertFalse(s.autostartAvailable)
        self.assertFalse(s.autostart)
        s.autostart = True   # sans effet, sans erreur
        self.assertFalse(s.autostart)


class File(unittest.TestCase):
    def setUp(self):
        gui()
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "agent-burn-desktop" / "settings.json"

    def write(self, raw):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_bytes(raw)

    def test_roundtrip_atomic_and_change_signal(self):
        s = Settings(self.path)
        changes = []
        s.changed.connect(lambda: changes.append(1))
        s.refreshMinutes = 15
        s.theme = "light"
        s.closeToTray = False
        s.trayClick = "dashboard"
        s.debugLogging = True
        self.assertEqual(len(changes), 5)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8")),
                         {"refreshMinutes": 15, "theme": "light", "closeToTray": False, "trayClick": "dashboard",
                          "debugLogging": True})
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ["settings.json"])   # aucun reste temporaire
        t = Settings(self.path)
        self.assertEqual((t.refreshMinutes, t.theme, t.closeToTray, t.trayClick, t.debugLogging),
                         (15, "light", False, "dashboard", True))
        self.assertFalse(t.recovered)

    def test_invalid_values_and_unknown_keys_fall_back_and_are_logged(self):
        self.write(json.dumps({"refreshMinutes": 7, "theme": "bleu", "closeToTray": "oui", "trayClick": 1,
                               "debugLogging": 1, "inconnu": 3}).encode())
        with self.assertLogs("agentburn.settings", "WARNING") as logs:
            s = Settings(self.path)
        self.assertEqual((s.refreshMinutes, s.theme, s.closeToTray, s.debugLogging), (5, "system", True, False))
        self.assertEqual(len(logs.records), 6)
        self.assertFalse(s.recovered)   # fichier lisible : pas de copie .bak
        s.theme = "dark"
        self.assertNotIn("inconnu", json.loads(self.path.read_text(encoding="utf-8")))

    def test_bool_is_not_a_number_of_minutes(self):
        self.write(b'{"refreshMinutes": true, "debugLogging": 0}')
        with self.assertLogs("agentburn.settings", "WARNING"):
            s = Settings(self.path)
        self.assertEqual((s.refreshMinutes, s.debugLogging), (5, False))

    def test_unreadable_file_copied_to_bak_then_defaults(self):
        for raw in (b"{pas du json", b"[1, 2]", b'{"theme": "\xff"}'):
            self.write(raw)
            with self.assertLogs("agentburn.settings", "WARNING"):
                s = Settings(self.path)
            self.assertTrue(s.recovered, raw)
            self.assertEqual(s.theme, "system")
            self.assertEqual(self.path.with_name("settings.json.bak").read_bytes(), raw)
            self.assertEqual(self.path.read_bytes(), raw)   # rien d'écrasé avant un changement

    def test_rejected_value_keeps_the_old_one(self):
        s = Settings(self.path)
        changes = []
        s.changed.connect(lambda: changes.append(1))
        with self.assertLogs("agentburn.settings", "WARNING"):
            s.setProperty("refreshMinutes", 7)
            s.setProperty("theme", "rose")
        self.assertEqual((s.refreshMinutes, s.theme), (5, "system"))
        self.assertEqual(len(changes), 2)   # le contrôle QML se recale
        self.assertFalse(self.path.exists())

    def test_reset(self):
        self.write(b"{corrompu")
        with self.assertLogs("agentburn.settings", "WARNING"):
            s = Settings(self.path)
        s.refreshMinutes = 30
        changes = []
        s.changed.connect(lambda: changes.append(1))
        s.reset()
        self.assertEqual(changes, [1])
        self.assertFalse(s.recovered)
        self.assertEqual(s.refreshMinutes, 5)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["refreshMinutes"], 5)

    def test_autostart_goes_through_the_platform(self):
        state = {"on": False}
        system = types.SimpleNamespace(autostart=lambda: state["on"], set_autostart=lambda on: state.update(on=on))
        s = Settings(self.path, system)
        self.assertTrue(s.autostartAvailable)
        s.autostart = True
        self.assertTrue(state["on"])
        self.assertTrue(s.autostart)
        self.assertNotIn("autostart", json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else {})
        state["on"] = False   # changé ailleurs (installeur, bureau) : relu
        self.assertFalse(s.autostart)

    def test_autostart_failure_is_logged_not_raised(self):
        def refuse(on):
            raise PermissionError(13, "refusé")
        s = Settings(self.path, types.SimpleNamespace(autostart=lambda: False, set_autostart=refuse))
        with self.assertLogs("agentburn.settings", "WARNING"):
            s.autostart = True
        self.assertFalse(s.autostart)


if __name__ == "__main__":
    unittest.main()
