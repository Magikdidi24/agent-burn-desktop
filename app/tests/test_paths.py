# Tests of the per-platform directories (simulated platform and environment) and of the single instance server name.
#   cd app && python -m unittest discover -s tests -v
import os
import stat
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from PySide6.QtCore import QCoreApplication, QStandardPaths  # noqa: E402

from agentburn import paths  # noqa: E402

X = Path(os.path.abspath("/x"))   # absolute for the host: on Windows, "/x" without a drive no longer is (Python 3.13)
WIN = {"APPDATA": "/w/Roaming", "LOCALAPPDATA": "/w/Local", "XDG_DATA_HOME": str(X / "data"),
       "XDG_CONFIG_HOME": str(X / "config"), "XDG_STATE_HOME": str(X / "state"), "XDG_CACHE_HOME": str(X / "cache")}



class Paths(unittest.TestCase):
    def setUp(self):
        QCoreApplication.setApplicationName("AgentBurn")

    def run_as(self, platform, values, drop=("AGENT_BURN_DATA",)):
        for p in (mock.patch.dict(os.environ, values), mock.patch.object(sys, "platform", platform)):
            p.start()
            self.addCleanup(p.stop)
        for name in drop:   # restored with the rest of the environment
            os.environ.pop(name, None)

    def test_windows_appdata_and_localappdata_never_xdg(self):
        self.run_as("win32", WIN)
        cache = "/w/Local/AgentBurn/cache"
        with mock.patch.object(paths.QStandardPaths, "writableLocation", return_value=cache) as where:
            self.assertEqual(paths.cache_dir(), Path(cache))
        where.assert_called_once_with(QStandardPaths.StandardLocation.CacheLocation)
        self.assertEqual(paths.data_dir(), Path("/w/Roaming/AgentBurn"))   # existing history
        self.assertEqual(paths.settings_file(), Path("/w/Roaming/AgentBurn/settings.json"))
        self.assertEqual(paths.log_dir(), Path("/w/Local/AgentBurn/logs"))

    def test_linux_xdg_dirs_apart_from_the_cli(self):
        self.run_as("linux", WIN)
        self.assertEqual(paths.data_dir(), X / "data" / "agent-burn-desktop")
        self.assertEqual(paths.settings_file(), X / "config" / "agent-burn-desktop" / "settings.json")
        self.assertEqual(paths.log_dir(), X / "state" / "agent-burn-desktop" / "logs")
        self.assertEqual(paths.cache_dir(), X / "cache" / "agent-burn-desktop")

    @unittest.skipIf(sys.platform == "win32", "Path.home() reads USERPROFILE on Windows")
    def test_linux_defaults_without_xdg_or_with_relative_values(self):
        self.run_as("linux", {"HOME": "/home/me", "XDG_DATA_HOME": "relative/data"},
                    drop=("AGENT_BURN_DATA", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"))
        self.assertEqual(paths.data_dir(), Path("/home/me/.local/share/agent-burn-desktop"))
        self.assertEqual(paths.settings_file(), Path("/home/me/.config/agent-burn-desktop/settings.json"))
        self.assertEqual(paths.log_dir(), Path("/home/me/.local/state/agent-burn-desktop/logs"))
        self.assertEqual(paths.cache_dir(), Path("/home/me/.cache/agent-burn-desktop"))

    @unittest.skipIf(sys.platform == "win32", "Path.home() reads USERPROFILE on Windows")
    def test_macos_library_dirs_apart_from_the_cli(self):
        self.run_as("darwin", {"HOME": "/Users/me", "XDG_DATA_HOME": "/x/data"})   # XDG ignored
        self.assertEqual(paths.data_dir(), Path("/Users/me/Library/Application Support/AgentBurn"))
        self.assertEqual(paths.settings_file(), Path("/Users/me/Library/Application Support/AgentBurn/settings.json"))
        self.assertEqual(paths.log_dir(), Path("/Users/me/Library/Logs/AgentBurn"))
        self.assertEqual(paths.cache_dir(), Path("/Users/me/Library/Caches/AgentBurn"))   # the CLI's: …/agent-burn
        self.assertEqual(paths.instance_name(), "/Users/me/Library/Caches/AgentBurn/AgentBurn.sock")

    def test_agent_burn_data_overrides_on_every_platform(self):
        for platform in ("win32", "linux", "darwin"):
            with mock.patch.dict(os.environ, {**WIN, "AGENT_BURN_DATA": "/fixtures/data"}), \
                    mock.patch.object(sys, "platform", platform):
                self.assertEqual(paths.data_dir(), Path("/fixtures/data"), platform)


class InstanceName(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "Unix socket")
    def test_unix_socket_full_path_in_private_dir(self):
        name = paths.instance_name()
        self.assertTrue(os.path.isabs(name), name)
        self.assertNotEqual(Path(name).parent, Path("/tmp"))
        self.assertLess(len(os.fsencode(name)), 104, name)   # sun_path: 104 bytes on macOS, 108 on Linux
        # Linux: the runtime directory; macOS: the cache, under ~/Library.
        private = Path.home() / "Library" if sys.platform == "darwin" else Path(name).parent
        self.assertTrue(Path(name).is_relative_to(private), name)
        mode = stat.S_IMODE(private.stat().st_mode)
        self.assertEqual(mode, 0o700, oct(mode))

    def test_windows_pipe_named_per_user_and_session(self):
        fake = mock.MagicMock()
        fake.session_id.return_value = 3
        with mock.patch.object(sys, "platform", "win32"), mock.patch("getpass.getuser", return_value="sam"), \
                mock.patch.dict(sys.modules, {"agentburn.platform_win": fake}), \
                mock.patch("agentburn.platform_win", fake, create=True):
            self.assertEqual(paths.instance_name(), "AgentBurn-sam-3")


if __name__ == "__main__":
    unittest.main()
