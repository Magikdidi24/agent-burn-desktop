# Réglages de l'app de bureau, singleton QML « Settings » : JSON réécrit (atomique) à chaque changement,
# validé à la lecture (type ou valeur hors liste → défaut, clé inconnue retirée). Le lancement à
# l'ouverture de session n'y est pas : lu et écrit dans le système (registre Windows, autostart XDG).
import json
import logging

from PySide6.QtCore import Property, QIODevice, QObject, QSaveFile, Signal, Slot
from PySide6.QtGui import QGuiApplication

log = logging.getLogger("agentburn.settings")

CHOICES = {"refreshMinutes": (1, 5, 15, 30), "theme": ("system", "light", "dark"), "closeToTray": (True, False),
           "trayClick": ("popover", "dashboard"), "debugLogging": (False, True)}


def defaults():
    # Sous Wayland le compositeur ignore la position du popover (centré, loin de l'icône) : dashboard.
    return {"refreshMinutes": 5, "theme": "system", "closeToTray": True,
            "trayClick": "dashboard" if QGuiApplication.platformName() == "wayland" else "popover",
            "debugLogging": False}


def valid(name, value):
    return type(value) is type(CHOICES[name][0]) and value in CHOICES[name]   # type exact : True n'est pas 1


def _write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    f = QSaveFile(str(path))   # fichier temporaire renommé : jamais de JSON à moitié écrit
    if not (f.open(QIODevice.OpenModeFlag.WriteOnly) and f.write(data) == len(data) and f.commit()):
        raise OSError(f.errorString())


def _setting(name, kind, notify):
    return Property(kind, lambda self: self._values[name], lambda self, v: self._set(name, v), notify=notify)


class Settings(QObject):
    changed = Signal()

    def __init__(self, path, system=None):
        """path None : réglages en mémoire (selftest) ; system : module autostart()/set_autostart(), None en dev."""
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
            log.warning("réglages illisibles (%s) : valeurs par défaut", e)
            return values
        try:
            data = json.loads(raw.decode("utf-8-sig"))   # BOM du Bloc-notes ou de PowerShell 5 accepté
            if not isinstance(data, dict):
                raise ValueError("pas un objet JSON")
        except (ValueError, RecursionError) as e:   # JSON ou UTF-8 invalide, imbrication extrême
            self._recovered = True
            try:
                _write(self._path.with_name(self._path.name + ".bak"), raw)
                log.warning("réglages illisibles (%s) : copie en %s.bak, valeurs par défaut", e, self._path.name)
            except OSError as err:
                log.warning("réglages illisibles (%s), copie .bak impossible (%s) : valeurs par défaut", e, err)
            return values
        for name, value in data.items():
            if name not in values:
                log.warning("réglage inconnu ignoré : %s", name)
            elif not valid(name, value):
                log.warning("réglage %s invalide (%r) : %r par défaut", name, value, values[name])
            else:
                values[name] = value
        return values

    def _save(self):
        if self._path is None:
            return
        try:
            _write(self._path, json.dumps(self._values, indent=2).encode("utf-8"))
            log.debug("réglages enregistrés dans %s", self._path)
        except OSError as e:
            log.warning("réglages non enregistrés (%s) : %s", self._path, e)

    def _set(self, name, value):
        if not valid(name, value):
            log.warning("réglage %s refusé : %r", name, value)
        elif value != self._values[name]:
            self._values[name] = value
            self._save()
        self.changed.emit()   # aussi après un refus : le contrôle QML se recale sur la valeur gardée

    refreshMinutes = _setting("refreshMinutes", int, changed)
    theme = _setting("theme", str, changed)
    closeToTray = _setting("closeToTray", bool, changed)
    trayClick = _setting("trayClick", str, changed)
    debugLogging = _setting("debugLogging", bool, changed)

    def _autostart(self):
        try:
            return bool(self._system and self._system.autostart())
        except OSError as e:
            log.warning("lancement à l'ouverture de session illisible : %s", e)
            return False

    def _set_autostart(self, on):
        if self._system:
            try:
                self._system.set_autostart(bool(on))
            except OSError as e:
                log.warning("lancement à l'ouverture de session non modifié : %s", e)
        self.changed.emit()

    autostart = Property(bool, _autostart, _set_autostart, notify=changed)
    autostartAvailable = Property(bool, lambda self: self._system is not None, constant=True)
    recovered = Property(bool, lambda self: self._recovered, notify=changed)   # fichier illisible au démarrage

    @Slot()
    def reset(self):
        self._values = defaults()
        self._recovered = False
        self._save()
        self.changed.emit()
