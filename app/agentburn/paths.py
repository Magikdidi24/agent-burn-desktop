# Directories of the desktop app, the only place that knows them per platform. Windows: %APPDATA%\AgentBurn
# (history already there) and %LOCALAPPDATA%\AgentBurn. Linux: XDG, under agent-burn-desktop to stay
# apart from the CLI's own ~/.cache/agent-burn and ~/.config/agent-burn. macOS: ~/Library, under AgentBurn
# (the CLI's cache is ~/Library/Caches/agent-burn).
import getpass
import os
import sys
from pathlib import Path

from PySide6.QtCore import QStandardPaths

LINUX = "agent-burn-desktop"


def xdg(var, default):
    """XDG base directory; a relative value is invalid per the spec, so it is ignored."""
    value = os.environ.get(var, "")
    return Path(value) if os.path.isabs(value) else Path.home() / default


def data_dir():
    if os.environ.get("AGENT_BURN_DATA"):
        return Path(os.environ["AGENT_BURN_DATA"])
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "AgentBurn"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "AgentBurn"
    return xdg("XDG_DATA_HOME", ".local/share") / LINUX


def settings_file():
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "AgentBurn" / "settings.json"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "AgentBurn" / "settings.json"
    return xdg("XDG_CONFIG_HOME", ".config") / LINUX / "settings.json"


def log_dir():
    if sys.platform == "win32":
        return Path(os.environ["LOCALAPPDATA"]) / "AgentBurn" / "logs"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Logs" / "AgentBurn"
    return xdg("XDG_STATE_HOME", ".local/state") / LINUX / "logs"


def cache_dir():
    if sys.platform == "win32":   # %LOCALAPPDATA%\AgentBurn\cache, as before
        return Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation))
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "AgentBurn"
    return xdg("XDG_CACHE_HOME", ".cache") / LINUX


def instance_name():
    """Single-instance server. Unix: socket with a full path in the runtime directory (0700, not
    /tmp where another account can take the name). Windows: named pipe, global namespace, hence
    the user and the session in the name. macOS has no runtime directory: the cache, private through
    ~/Library (0700), rather than $TMPDIR, where macOS deletes files left untouched for days. A path longer
    than sun_path (104 bytes there) makes listen() fail, logged: the lock still keeps a single instance."""
    if sys.platform == "win32":
        from agentburn import platform_win
        return f"AgentBurn-{getpass.getuser()}-{platform_win.session_id()}"
    if sys.platform == "darwin":
        return str(cache_dir() / "AgentBurn.sock")
    return QStandardPaths.writableLocation(QStandardPaths.StandardLocation.RuntimeLocation) + "/AgentBurn.sock"
