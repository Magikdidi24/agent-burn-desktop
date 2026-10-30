# macOS-specific calls, imported only on macOS: start at login through the user's LaunchAgent (launchd reads it at
# the next login; only that plist is written or removed), idle time from CoreGraphics.
import ctypes
import functools
import os
import plistlib
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

ID = "io.github.magikdidi24.AgentBurn"   # LaunchAgent label, same as the bundle identifier


def _file():
    return Path.home() / "Library" / "LaunchAgents" / f"{ID}.plist"


@functools.cache
def _last_input():
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    f = cg.CGEventSourceSecondsSinceLastEventType
    f.restype, f.argtypes = ctypes.c_double, (ctypes.c_int32, ctypes.c_uint32)
    return f


def idle_seconds():
    # Input of this login session (kCGEventSourceStateCombinedSessionState), of any type (kCGAnyInputEventType):
    # like GetLastInputInfo on Windows, and no permission needed.
    return _last_input()(0, 0xFFFFFFFF)


def autostart():
    try:
        job = plistlib.loads(_file().read_bytes())
    except (OSError, ValueError, ExpatError):   # missing or unreadable: launchd would not load it either
        return False
    return isinstance(job, dict) and job.get("Disabled") is not True


def set_autostart(on):
    f = _file()
    if not on:
        f.unlink(missing_ok=True)
        return
    exe = sys.executable   # Contents/MacOS/AgentBurn of the .app
    # Quarantined app opened where it was unzipped: macOS runs it from a random read-only copy, gone after a restart.
    if "/AppTranslocation/" in exe:
        raise OSError(f"{exe!r}: app run from a temporary copy, move it to Applications first")
    try:
        # Interactive: an app, not a background job that launchd throttles.
        data = plistlib.dumps({"Label": ID, "ProgramArguments": [exe], "RunAtLoad": True, "ProcessType": "Interactive"})
    except ValueError as e:   # control character in the path, refused by XML
        raise OSError(f"{exe!r}: {e}") from e
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, f)
