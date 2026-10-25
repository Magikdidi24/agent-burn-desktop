# Tests du lancement à l'ouverture de session sous Linux (autostart XDG, XDG_CONFIG_HOME temporaire) :
# écriture, lecture, Hidden=true et X-GNOME-Autostart-enabled=false, retrait de notre seul fichier,
# guillemets de la clé Exec, chemin inutilisable (saut de ligne, %, \) refusé.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agentburn import platform_linux as pl  # noqa: E402


class Autostart(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patch = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.dir.name})
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop("APPIMAGE", None)
        # Chemin Linux même quand la suite tourne sous Windows (CI) : les \ de python.exe y sont refusés.
        exe = mock.patch.object(sys, "executable", "/opt/agent-burn-desktop/agent-burn-desktop")
        exe.start()
        self.addCleanup(exe.stop)
        self.file = Path(self.dir.name) / "autostart" / "io.github.magikdidi24.AgentBurn.desktop"

    def entry(self):
        return dict(line.split("=", 1) for line in self.file.read_text(encoding="utf-8").splitlines()[1:])

    def test_write_read_remove_only_ours(self):
        other = Path(self.dir.name) / "autostart" / "autre.desktop"
        other.parent.mkdir(parents=True)
        other.write_text("[Desktop Entry]\nType=Application\nName=Autre\nExec=autre\n")
        self.assertFalse(pl.autostart())
        with mock.patch.object(sys, "executable", "/opt/agent-burn/AgentBurn"):
            pl.set_autostart(True)
        self.assertTrue(pl.autostart())
        self.assertEqual(self.file.read_text(encoding="utf-8").splitlines()[0], "[Desktop Entry]")
        e = self.entry()
        self.assertEqual((e["Type"], e["Name"], e["X-GNOME-Autostart-enabled"]), ("Application", "Agent Burn", "true"))
        self.assertEqual(e["Exec"], '"/opt/agent-burn/AgentBurn"')
        self.assertEqual(sorted(p.name for p in self.file.parent.iterdir()), sorted([self.file.name, other.name]))
        pl.set_autostart(False)
        self.assertFalse(self.file.exists())
        self.assertFalse(pl.autostart())
        self.assertTrue(other.exists())
        pl.set_autostart(False)   # déjà retiré : sans erreur

    def test_hidden_true_means_off_and_enabling_rewrites(self):
        self.file.parent.mkdir(parents=True)
        self.file.write_text("[Desktop Entry]\nType=Application\nName=Agent Burn\nExec=x\nHidden = true\n")
        self.assertFalse(pl.autostart())
        pl.set_autostart(True)
        self.assertTrue(pl.autostart())
        self.assertNotIn("Hidden", self.file.read_text(encoding="utf-8"))

    def test_disabled_by_gnome_tools_means_off(self):
        # Applications au démarrage (GNOME), Cinnamon, MATE : la clé passe à false, le fichier reste.
        self.file.parent.mkdir(parents=True)
        self.file.write_text("[Desktop Entry]\nType=Application\nName=Agent Burn\nExec=x\nX-GNOME-Autostart-enabled=false\n")
        self.assertFalse(pl.autostart())
        pl.set_autostart(True)
        self.assertTrue(pl.autostart())

    def test_appimage_preferred_to_the_mounted_executable(self):
        with mock.patch.dict(os.environ, {"APPIMAGE": "/home/me/Applications/Agent Burn.AppImage"}), \
                mock.patch.object(sys, "executable", "/tmp/.mount_AgentBxyz/usr/bin/AgentBurn"):
            pl.set_autostart(True)
        self.assertEqual(self.entry()["Exec"], '"/home/me/Applications/Agent Burn.AppImage"')

    def test_unusable_path_refused_nothing_written(self):
        # Dossier nommé pour injecter une 2e clé Exec ; % et \ cassent l'entrée sous GLib et systemd.
        for exe in ("/opt/AgentBurn\nExec=sh -c 'touch PWNED'\nX=/AgentBurn", "/opt/a\tb/AgentBurn", "/x/100%/AgentBurn",
                    "/x/a\\b/AgentBurn"):
            with mock.patch.object(sys, "executable", exe), self.assertRaises(OSError, msg=repr(exe)):
                pl.set_autostart(True)
            self.assertFalse(self.file.exists(), repr(exe))
            self.assertFalse(pl.autostart())

    def test_exec_quoting(self):
        # Spec : guillemets, \ devant " ` $ \ ; puis \ doublé (valeur string, relue avant les guillemets) et %
        # doublé. Un \ littéral devient donc 4 barres dans le fichier.
        for path, value in (("/opt/a b/AgentBurn", '"/opt/a b/AgentBurn"'), ('/x/"q"/a', r'"/x/\\"q\\"/a"'),
                            ("/x/$HOME/a", r'"/x/\\$HOME/a"'), ("/x/`id`/a", r'"/x/\\`id\\`/a"'),
                            ("/x/100%/a", '"/x/100%%/a"'), (r"/x/a\b", r'"/x/a\\\\b"'), ("/x/é ü", '"/x/é ü"')):
            self.assertEqual(pl.quote(path), value, path)


if __name__ == "__main__":
    unittest.main()
