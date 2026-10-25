# Windows-specific calls (ctypes, winreg), imported only on Windows: idle time, dark title
# bar, launch at startup, foreground handed over to the instance already running, current session.
import ctypes
import sys
import winreg
from ctypes import wintypes

RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"
# Disabled from Task Manager or Settings, the Run entry stays but Windows writes a REG_BINARY
# with an odd 1st byte here and no longer launches it.
APPROVED = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
NAME = "AgentBurn"   # same value as the installer


class _LastInput(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]


def idle_seconds():
    info = _LastInput(ctypes.sizeof(_LastInput), 0)
    ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info))
    return ((ctypes.windll.kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF) / 1000   # 32-bit counters


def dark_title_bar(hwnd, dark):
    value = ctypes.c_int(int(dark))
    ctypes.windll.dwmapi.DwmSetWindowAttribute(wintypes.HWND(hwnd), 20,   # DWMWA_USE_IMMERSIVE_DARK_MODE
                                               ctypes.byref(value), ctypes.sizeof(value))


def autostart():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN) as key:
            winreg.QueryValueEx(key, NAME)
    except OSError:
        return False
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, APPROVED) as key:
            data = winreg.QueryValueEx(key, NAME)[0]
    except OSError:   # missing: enabled
        return True
    return not (isinstance(data, bytes) and data[:1] and data[0] & 1)   # empty or of another type: not disabled


def _delete(path):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, NAME)
    except FileNotFoundError:
        pass


def set_autostart(on):
    if on:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, NAME, 0, winreg.REG_SZ, f'"{sys.executable}"')
        _delete(APPROVED)   # also re-enables an entry disabled by Windows
    else:
        _delete(RUN)


def allow_foreground():
    ctypes.windll.user32.AllowSetForegroundWindow(-1)   # ASFW_ANY


def session_id():
    sid = wintypes.DWORD()
    ctypes.windll.kernel32.ProcessIdToSessionId(ctypes.windll.kernel32.GetCurrentProcessId(), ctypes.byref(sid))
    return sid.value
