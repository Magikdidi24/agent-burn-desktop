# Lancement à l'ouverture de session sous Linux : fichier autostart XDG de l'utilisateur. Hidden=true
# (posé par l'outil du bureau) vaut désactivé ; seul ce fichier-là est écrit ou retiré.
import os
import re
import sys

from agentburn import paths

ID = "io.github.magikdidi24.AgentBurn"


def _file():
    return paths.xdg("XDG_CONFIG_HOME", ".config") / "autostart" / f"{ID}.desktop"


def quote(arg):
    """Argument de la clé Exec (spec Desktop Entry) : entre guillemets, " ` $ \\ échappés ; puis échappement
    des valeurs string (\\ doublé, appliqué avant les guillemets à la lecture) et % doublé (codes de champ)."""
    quoted = '"' + re.sub(r'(["`$\\])', r"\\\1", arg) + '"'
    return quoted.replace("\\", "\\\\").replace("%", "%%")


def autostart():
    try:
        text = _file().read_text(encoding="utf-8")
    except OSError:   # absent ou illisible
        return False
    return not re.search(r"(?m)^Hidden\s*=\s*true\s*$", text)


def set_autostart(on):
    f = _file()
    if not on:
        f.unlink(missing_ok=True)
        return
    # L'AppImage elle-même : l'exe gelé qu'elle contient est monté ailleurs à chaque lancement.
    exe = os.environ.get("APPIMAGE") or sys.executable
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text("[Desktop Entry]\nType=Application\nName=Agent Burn\n"
                   f"Exec={quote(exe)}\nX-GNOME-Autostart-enabled=true\n", encoding="utf-8")
    os.replace(tmp, f)
