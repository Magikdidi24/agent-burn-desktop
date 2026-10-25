# Start at login on Linux: the user's XDG autostart file. Hidden=true or
# X-GNOME-Autostart-enabled=false (set by the desktop's tool) mean disabled; only that file is
# written or removed.
import os
import re
import sys

from agentburn import paths

ID = "io.github.magikdidi24.AgentBurn"


def _file():
    return paths.xdg("XDG_CONFIG_HOME", ".config") / "autostart" / f"{ID}.desktop"


def quote(arg):
    """Argument of the Exec key (Desktop Entry spec): in double quotes, " ` $ \\ escaped; then the escaping
    of string values (\\ doubled, applied before the quoting on read) and % doubled (field codes)."""
    quoted = '"' + re.sub(r'(["`$\\])', r"\\\1", arg) + '"'
    return quoted.replace("\\", "\\\\").replace("%", "%%")


def autostart():
    try:
        text = _file().read_text(encoding="utf-8")
    except OSError:   # missing or unreadable
        return False
    return not re.search(r"(?m)^(?:Hidden\s*=\s*true|X-GNOME-Autostart-enabled\s*=\s*false)\s*$", text)


def set_autostart(on):
    f = _file()
    if not on:
        f.unlink(missing_ok=True)
        return
    # The AppImage itself: the frozen exe it contains is mounted elsewhere at every launch.
    exe = os.environ.get("APPIMAGE") or sys.executable
    # Line break: keys added to the entry (an Exec chosen by a directory name); % or \: entry
    # rejected by GLib or systemd, even though it would look enabled. Rejection logged by Settings.
    if re.search(r"[\x00-\x1f\x7f%\\]", exe):
        raise OSError(f"{exe!r}: path unusable in a .desktop entry")
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text("[Desktop Entry]\nType=Application\nName=Agent Burn\n"
                   f"Exec={quote(exe)}\nX-GNOME-Autostart-enabled=true\n", encoding="utf-8")
    os.replace(tmp, f)
