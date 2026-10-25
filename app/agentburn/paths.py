# Dossiers de l'app de bureau, seul endroit qui les connaît par plateforme. Windows : %APPDATA%\AgentBurn
# (historique déjà là) et %LOCALAPPDATA%\AgentBurn. Linux : XDG, sous agent-burn-desktop pour rester à
# part des ~/.cache/agent-burn et ~/.config/agent-burn du CLI lui-même.
import getpass
import os
import sys
from pathlib import Path

from PySide6.QtCore import QStandardPaths

LINUX = "agent-burn-desktop"


def xdg(var, default):
    """Dossier de base XDG ; une valeur relative est invalide selon la spec, donc ignorée."""
    value = os.environ.get(var, "")
    return Path(value) if os.path.isabs(value) else Path.home() / default


def data_dir():
    if os.environ.get("AGENT_BURN_DATA"):
        return Path(os.environ["AGENT_BURN_DATA"])
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "AgentBurn"
    return xdg("XDG_DATA_HOME", ".local/share") / LINUX


def settings_file():
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "AgentBurn" / "settings.json"
    return xdg("XDG_CONFIG_HOME", ".config") / LINUX / "settings.json"


def log_dir():
    if sys.platform == "win32":
        return Path(os.environ["LOCALAPPDATA"]) / "AgentBurn" / "logs"
    return xdg("XDG_STATE_HOME", ".local/state") / LINUX / "logs"


def cache_dir():
    if sys.platform == "win32":   # %LOCALAPPDATA%\AgentBurn\cache, comme avant
        return Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation))
    return xdg("XDG_CACHE_HOME", ".cache") / LINUX


def instance_name():
    """Serveur d'instance unique. Unix : socket au chemin complet dans le dossier d'exécution (0700, pas
    /tmp où un autre compte peut prendre le nom). Windows : pipe nommé, espace de noms global, d'où
    l'utilisateur et la session dans le nom."""
    if sys.platform == "win32":
        from agentburn import platform_win
        return f"AgentBurn-{getpass.getuser()}-{platform_win.session_id()}"
    return QStandardPaths.writableLocation(QStandardPaths.StandardLocation.RuntimeLocation) + "/AgentBurn.sock"
