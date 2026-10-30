# Tests of start at login on macOS (LaunchAgent in a temporary home, on any system): write, read, Disabled and
# unreadable plists, removal of our file only, temporary (translocated) or unusable path refused; idle time
# from CoreGraphics on a Mac.
#   cd app && python -m unittest discover -s tests -v
import math
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agentburn import platform_mac as pm  # noqa: E402

EXE = "/Applications/Agent Burn.app/Contents/MacOS/AgentBurn"


class Autostart(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for p in (mock.patch.object(pm.Path, "home", return_value=Path(self.dir.name)),
                  mock.patch.object(sys, "executable", EXE)):
            p.start()
            self.addCleanup(p.stop)
        self.file = Path(self.dir.name) / "Library" / "LaunchAgents" / "io.github.magikdidi24.AgentBurn.plist"

    def test_write_read_remove_only_ours(self):
        other = self.file.with_name("com.example.other.plist")
        other.parent.mkdir(parents=True)
        other.write_bytes(plistlib.dumps({"Label": "com.example.other", "ProgramArguments": ["/bin/true"]}))
        self.assertFalse(pm.autostart())
        pm.set_autostart(True)
        self.assertTrue(pm.autostart())
        # launchd starts the bundle's exe at login, as an app (not throttled), once.
        self.assertEqual(plistlib.loads(self.file.read_bytes()),
                         {"Label": "io.github.magikdidi24.AgentBurn", "ProgramArguments": [EXE], "RunAtLoad": True,
                          "ProcessType": "Interactive"})
        self.assertEqual(sorted(p.name for p in self.file.parent.iterdir()), sorted([self.file.name, other.name]))
        pm.set_autostart(False)
        self.assertFalse(self.file.exists())
        self.assertFalse(pm.autostart())
        self.assertTrue(other.exists())
        pm.set_autostart(False)   # already removed: no error

    def test_disabled_or_unreadable_means_off_and_enabling_rewrites(self):
        self.file.parent.mkdir(parents=True)
        for data in (plistlib.dumps({"Label": "io.github.magikdidi24.AgentBurn", "Disabled": True}), b"",
                     b"garbage", b"<?xml version='1.0'?><plist", plistlib.dumps(["not", "a", "job"])):
            self.file.write_bytes(data)
            self.assertFalse(pm.autostart(), data)
            pm.set_autostart(True)
            self.assertTrue(pm.autostart(), data)

    def test_temporary_or_unusable_path_refused_nothing_written(self):
        # Quarantined app opened from Downloads: macOS runs a copy that is gone after a restart. A control
        # character cannot go into the XML plist.
        for exe in ("/private/var/folders/ab/T/AppTranslocation/0A1B/d/Agent Burn.app/Contents/MacOS/AgentBurn",
                    "/Applications/A\x01B.app/Contents/MacOS/AgentBurn"):
            with mock.patch.object(sys, "executable", exe), self.assertRaises(OSError, msg=repr(exe)):
                pm.set_autostart(True)
            self.assertFalse(self.file.exists(), repr(exe))
            self.assertFalse(pm.autostart())


class Idle(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "CoreGraphics: macOS")
    def test_seconds_since_the_last_input(self):
        seconds = pm.idle_seconds()
        self.assertTrue(math.isfinite(seconds) and seconds >= 0, seconds)


if __name__ == "__main__":
    unittest.main()
