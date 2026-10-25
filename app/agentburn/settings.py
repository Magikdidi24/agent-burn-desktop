# Desktop app settings, QML singleton "Settings": JSON rewritten (atomically) on every change,
# validated on read (wrong type or value not in the list → default, unknown key dropped). Start at
# login is not in it: it is read and written in the system (Windows registry, XDG autostart).
import json
import logging

from PySide6.QtCore import Property, QIODevice, QObject, QSaveFile, Signal, Slot
from PySide6.QtGui import QGuiApplication

log = logging.getLogger("agentburn.settings")

CHOICES = {"refreshMinutes": (1, 5, 15, 30), "theme": ("system", "light", "dark"), "closeToTray": (True, False),
           "trayClick": ("popover", "dashboard"), "debugLogging": (False, True)}


def defaults():
    # On Wayland the compositor ignores the popover position (centered, far from the icon): dashboard.
    return {"refreshMinutes": 5, "theme": "system", "closeToTray": True,
            "trayClick": "dashboard" if QGuiApplication.platformName() == "wayland" else "popover",
            "debugLogging": False}


def valid(name, value):
    return type(value) is type(CHOICES[name][0]) and value in CHOICES[name]   # exact type: True is not 1


def _write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    f = QSaveFile(str(path))   # temporary file renamed: never a half-written JSON
    if not (f.open(QIODevice.OpenModeFlag.WriteOnly) and f.write(data) == len(data) and f.commit()):
        raise OSError(f.errorString())


def _setting(name, kind, notify):
    return Property(kind, lambda self: self._values[name], lambda self, v: self._set(name, v), notify=notify)


class Settings(QObject):
    changed = Signal()

    def __init__(self, path, system=None):
        """path None: settings in memory (selftest); system: autostart()/set_autostart() module, None in dev."""
        super().__init__()
        self._path = path
        self._system = system
        self._recovered = False
        self._values = self._load()

    def _load(self):
        values = defaults()
        if self._path is None:
            return values
        try:
            raw = self._path.read_bytes()
        except FileNotFoundError:
            return values
        except OSError as e:
            log.warning("settings unreadable (%s): using defaults", e)
            return values
        try:
            data = json.loads(raw.decode("utf-8-sig"))   # BOM from Notepad or PowerShell 5 accepted
            if not isinstance(data, dict):
                raise ValueError("not a JSON object")
        except (ValueError, RecursionError) as e:   # invalid JSON or UTF-8, extreme nesting
            self._recovered = True
            try:
                _write(self._path.with_name(self._path.name + ".bak"), raw)
                log.warning("settings unreadable (%s): copied to %s.bak, using defaults", e, self._path.name)
            except OSError as err:
                log.warning("settings unreadable (%s), cannot copy to .bak (%s): using defaults", e, err)
            return values
        for name, value in data.items():
            if name not in values:
                log.warning("unknown setting ignored: %s", name)
            elif not valid(name, value):
                log.warning("invalid setting %s (%r): defaulting to %r", name, value, values[name])
            else:
                values[name] = value
        return values

    def _save(self):
        if self._path is None:
            return
        try:
            _write(self._path, json.dumps(self._values, indent=2).encode("utf-8"))
            log.debug("settings saved to %s", self._path)
        except OSError as e:
            log.warning("settings not saved (%s): %s", self._path, e)

    def _set(self, name, value):
        if not valid(name, value):
            log.warning("setting %s rejected: %r", name, value)
        elif value != self._values[name]:
            self._values[name] = value
            self._save()
        self.changed.emit()   # also after a rejection: the QML control snaps back to the kept value

    refreshMinutes = _setting("refreshMinutes", int, changed)
    theme = _setting("theme", str, changed)
    closeToTray = _setting("closeToTray", bool, changed)
    trayClick = _setting("trayClick", str, changed)
    debugLogging = _setting("debugLogging", bool, changed)

    def _autostart(self):
        try:
            return bool(self._system and self._system.autostart())
        except OSError as e:
            log.warning("start at login unreadable: %s", e)
            return False

    def _set_autostart(self, on):
        if self._system:
            try:
                self._system.set_autostart(bool(on))
            except OSError as e:
                log.warning("start at login not changed: %s", e)
        self.changed.emit()

    autostart = Property(bool, _autostart, _set_autostart, notify=changed)
    autostartAvailable = Property(bool, lambda self: self._system is not None, constant=True)
    recovered = Property(bool, lambda self: self._recovered, notify=changed)   # file unreadable at startup

    @Slot()
    def reset(self):
        self._values = defaults()
        self._recovered = False
        self._save()
        self.changed.emit()
