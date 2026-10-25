# Lancement à l'ouverture de session sous Linux : fichier autostart XDG de l'utilisateur. Hidden=true ou
# X-GNOME-Autostart-enabled=false (posés par l'outil du bureau) valent désactivé ; seul ce fichier-là est
# écrit ou retiré.
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
    return not re.search(r"(?m)^(?:Hidden\s*=\s*true|X-GNOME-Autostart-enabled\s*=\s*false)\s*$", text)


def set_autostart(on):
    f = _file()
    if not on:
        f.unlink(missing_ok=True)
        return
    # L'AppImage elle-même : l'exe gelé qu'elle contient est monté ailleurs à chaque lancement.
    exe = os.environ.get("APPIMAGE") or sys.executable
    # Saut de ligne : clés ajoutées à l'entrée (un Exec choisi par le nom d'un dossier) ; % ou \ : entrée
    # refusée par GLib ou systemd, alors même qu'elle paraîtrait active. Refus journalisé par Settings.
    if re.search(r"[\x00-\x1f\x7f%\\]", exe):
        raise OSError(f"{exe!r} : chemin inutilisable dans une entrée .desktop")
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text("[Desktop Entry]\nType=Application\nName=Agent Burn\n"
                   f"Exec={quote(exe)}\nX-GNOME-Autostart-enabled=true\n", encoding="utf-8")
    os.replace(tmp, f)
