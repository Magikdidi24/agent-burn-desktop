# Les QML partagés avec le module Quickshell tournent ici tels quels : ce module recrée le petit
# sous-ensemble de Quickshell 0.3.2 qu'ils utilisent (et leur suite de tests), même sémantique.
# Ordre des signaux de Process relevé sous qs : streamFinished → exited (running déjà faux) →
# runningChanged ; binaire absent : un seul runningChanged, sans started.
import os
import sys
from pathlib import Path

import shiboken6
from PySide6.QtCore import (ClassInfo, Property, QIODevice, QObject, QProcess, QProcessEnvironment, QSaveFile, QTimer,
                            QUrl, Signal, Slot)
from PySide6.QtGui import QDesktopServices
from PySide6.QtQml import ListProperty, QJSValue, qmlRegisterSingletonInstance, qmlRegisterType


@ClassInfo(DefaultProperty="children")
class Scope(QObject):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._children = []

    def _append(self, child):
        self._children.append(child)

    children = ListProperty(QObject, _append)


class Singleton(Scope):
    pass


class QuickshellGlobal(QObject):
    def __init__(self, data_dir, shell_dir):
        super().__init__()
        Path(data_dir).mkdir(parents=True, exist_ok=True)
        self._data = Path(data_dir).as_posix()
        self._shell = Path(shell_dir).as_posix()

    @Slot(str, result=QJSValue)
    def env(self, name):
        value = os.environ.get(name)
        return QJSValue(QJSValue.SpecialValue.NullValue) if value is None else QJSValue(value)

    dataDir = Property(str, lambda self: self._data, constant=True)
    shellDir = Property(str, lambda self: self._shell, constant=True)

    @Slot(str, result=str)
    def dataPath(self, path):
        return self._data + "/" + path

    @Slot(list)
    def execDetached(self, command):
        # « xdg-open » des QML Linux : le système ouvre le dossier ou l'URL (Explorateur sous Windows).
        if command[0] == "xdg-open":
            QDesktopServices.openUrl(QUrl.fromUserInput(command[1]))
        else:
            QProcess.startDetached(command[0], command[1:])


class StdioCollector(QObject):
    dataChanged = Signal()
    streamFinished = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._text = ""

    text = Property(str, lambda self: self._text, notify=dataChanged)


class Process(QObject):
    runningChanged = Signal()
    started = Signal()
    exited = Signal(int, int, arguments=["exitCode", "exitStatus"])

    def __init__(self, parent=None):
        super().__init__(parent)
        self._process = None
        self._command = []
        self._environment = {}
        self._stdout = None

    def _set_running(self, running):
        if not running:
            if self._process:
                self._process.terminate()
            return
        if self._process or not self._command:
            return
        p = self._process = QProcess(self)
        env = QProcessEnvironment.systemEnvironment()   # environnement courant + celui demandé (null = retiré)
        for name, value in self._environment.items():
            if value is None:
                env.remove(name)
            else:
                env.insert(name, str(value))
        p.setProcessEnvironment(env)
        # Fonctions anonymes, pas de méthodes liées : PySide ajouterait des slots à l'objet, en conflit
        # avec les propriétés que le QML lui déclare (component Cli: Process { property … }) → signaux
        # perdus. Ignorées une fois l'un des deux détruit (fermeture de l'app pendant un run).
        def relay(handler):
            return lambda *args: shiboken6.isValid(self) and shiboken6.isValid(p) and handler(*args)

        p.started.connect(relay(self._started))
        p.finished.connect(relay(self._finished))
        p.errorOccurred.connect(relay(self._error))
        p.start(self._command[0], self._command[1:])

    running = Property(bool, lambda self: self._process is not None, _set_running, notify=runningChanged)
    command = Property(list, lambda self: self._command, lambda self, v: setattr(self, "_command", list(v)))
    environment = Property(dict, lambda self: self._environment, lambda self, v: setattr(self, "_environment", dict(v)))
    stdout = Property(QObject, lambda self: self._stdout, lambda self, v: setattr(self, "_stdout", v))

    # shortcut : exec() pendant un run ne relance rien à sa fin (jamais fait par les QML partagés).
    @Slot(dict)
    def exec(self, context):
        self._set_running(False)
        if "command" in context:
            self.command = context["command"]
        if "environment" in context:
            self.environment = context["environment"]
        self._set_running(True)

    # shortcut : tout signal tue le process (seul signal(9) sert, et Windows n'a pas de signaux).
    @Slot(int)
    def signal(self, _signal):
        if self._process:
            self._process.kill()

    def _started(self):
        self.runningChanged.emit()
        self.started.emit()

    def _finished(self, code, status):
        p, self._process = self._process, None
        p.deleteLater()
        if self._stdout:
            self._stdout._text = bytes(p.readAllStandardOutput()).decode("utf-8", "replace")
            self._stdout.dataChanged.emit()
            self._stdout.streamFinished.emit()
        self.exited.emit(code, status.value)
        self.runningChanged.emit()

    def _error(self, error):
        if error == QProcess.ProcessError.FailedToStart:
            self._process.deleteLater()
            self._process = None
            self.runningChanged.emit()


def _accepted():
    # Réglage de qs accepté sans effet : ici lectures et écritures sont toujours synchrones.
    return Property(bool, lambda self: True, lambda self, v: None)


class FileView(QObject):
    pathChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._text = None   # None : pas encore lu

    def _set_path(self, path):
        if path != self._path:
            self._path, self._text = path, None
            self.pathChanged.emit()

    path = Property(str, lambda self: self._path, _set_path, notify=pathChanged)
    preload = _accepted()
    blockLoading = _accepted()
    blockWrites = _accepted()
    blockAllReads = _accepted()
    printErrors = _accepted()

    @Slot(result=str)
    def text(self):
        if self._text is None:
            try:
                self._text = Path(self._path).read_bytes().decode("utf-8", "replace")
            except OSError:   # absent ou illisible : vide, comme qs
                self._text = ""
        return self._text

    @Slot()
    def reload(self):
        self._text = None

    @Slot(str)
    def setText(self, text):
        Path(self._path).parent.mkdir(parents=True, exist_ok=True)
        f = QSaveFile(self._path)   # fichier temporaire renommé : jamais de JSON à moitié écrit
        if f.open(QIODevice.OpenModeFlag.WriteOnly):
            f.write(text.encode("utf-8"))
            f.commit()
        self._text = text


class IpcHandler(QObject):
    # Pas d'IPC hors de qs : cible gardée, fonctions déclarées en QML appelables depuis Python.
    def __init__(self, parent=None):
        super().__init__(parent)
        self._target = ""

    target = Property(str, lambda self: self._target, lambda self, v: setattr(self, "_target", v))


class IdleMonitor(QObject):
    isIdleChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._timeout = 0.0
        self._idle = False
        # Windows : dernière saisie sondée toutes les 5 s. Ailleurs (dev Linux) : jamais inactif.
        # shortcut : inhibiteurs ignorés (vidéo sans saisie = inactif, contrairement à respectInhibitors de
        # qs), à revoir si l'icône se fige pendant une vidéo.
        if sys.platform == "win32":
            self._poll = QTimer(self, interval=5000, timeout=lambda: self._check())   # pas de méthode liée : cf. Process
            self._poll.start()

    timeout = Property(float, lambda self: self._timeout, lambda self, v: setattr(self, "_timeout", v))
    isIdle = Property(bool, lambda self: self._idle, notify=isIdleChanged)

    def _check(self):
        from agentburn import platform_win
        idle = self._timeout > 0 and platform_win.idle_seconds() >= self._timeout
        if idle != self._idle:
            self._idle = idle
            self.isIdleChanged.emit()


_global = None   # instance du singleton « Quickshell », gardée en vie


def register(qml_dir, data_dir):
    """Enregistre les types sous les URI de Quickshell ; Quickshell.Widgets vient de qml_dir/widgets."""
    global _global
    for uri, types in (("Quickshell", (Scope, Singleton)),
                       ("Quickshell.Io", (Process, StdioCollector, FileView, IpcHandler)),
                       ("Quickshell.Wayland", (IdleMonitor,))):
        for t in types:
            qmlRegisterType(t, uri, 1, 0, t.__name__)
    _global = QuickshellGlobal(data_dir, qml_dir)
    qmlRegisterSingletonInstance(QuickshellGlobal, "Quickshell", 1, 0, "Quickshell", _global)
    for name in ("IconImage", "ClippingRectangle"):
        qmlRegisterType(QUrl.fromLocalFile(str(Path(qml_dir) / "widgets" / f"{name}.qml")),
                        "Quickshell.Widgets", 1, 0, name)
