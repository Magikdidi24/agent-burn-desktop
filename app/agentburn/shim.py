# The QML shared with the Quickshell module runs here unchanged: this module recreates the small
# subset of Quickshell 0.3.2 they (and their test suite) use, with the same semantics.
# Process signal order observed under qs: streamFinished → exited (running already false) →
# runningChanged; missing binary: a single runningChanged, without started.
# Beyond qs: children launched in the data directory with child_environment(), each run
# logged on the "agentburn.cli" logger (handlers set by the app, stderr tail at DEBUG),
# runs in progress awaited on close (wait_for_runs).
import logging
import os
import sys
import time
from pathlib import Path

import shiboken6
from PySide6.QtCore import (ClassInfo, Property, QIODevice, QObject, QProcess, QProcessEnvironment, QSaveFile, QTimer,
                            QUrl, Signal, Slot)
from PySide6.QtGui import QDesktopServices
from PySide6.QtQml import ListProperty, QJSValue, qmlRegisterSingletonInstance, qmlRegisterType

log = logging.getLogger("agentburn.cli")
_runs = set()   # QProcess objects in progress, awaited by wait_for_runs()
_closing = False   # wait_for_runs() called: the app is closing, no more runs launched

# CLI settings that change its JSON or its stderr: only the explicit environment of Burn.qml sets them.
_CLI_VARS = ("AGENT_BURN_QUOTA_ONLY", "AGENT_BURN_FORCE_REFRESH", "LOG_LEVEL")
# Set by PyInstaller for the frozen app (with _PYI_* and LD_LIBRARY_PATH): kde-open, launched by xdg-open,
# would otherwise load the bundle's Qt plugins.
_BUNDLE_VARS = ("QT_PLUGIN_PATH", "QML2_IMPORT_PATH", "QML_IMPORT_PATH")
# Set by the app for itself (__main__: QSG_RENDER_LOOP): neither the CLI nor xdg-open inherits them.
APP_VARS = set()


def child_environment():
    """Environment of launched processes (CLI, xdg-open): the system's, without the frozen bundle's leaks or
    the inherited CLI settings; on Windows HOME = USERPROFILE (the CLI reads HOME before USERPROFILE, Claude
    Code and Codex write under USERPROFILE)."""
    env = QProcessEnvironment.systemEnvironment()
    if getattr(sys, "frozen", False):
        for name in env.keys():
            if name.startswith("_PYI_"):
                env.remove(name)
        for name in _BUNDLE_VARS:
            env.remove(name)
        if env.contains("LD_LIBRARY_PATH_ORIG"):   # value from before the bootloader
            env.insert("LD_LIBRARY_PATH", env.value("LD_LIBRARY_PATH_ORIG"))
            env.remove("LD_LIBRARY_PATH_ORIG")
        else:
            env.remove("LD_LIBRARY_PATH")
    for name in _CLI_VARS + tuple(APP_VARS):
        env.remove(name)
    if sys.platform == "win32" and env.contains("USERPROFILE"):
        env.insert("HOME", env.value("USERPROFILE"))
    return env


def _first_error(text):
    """Useful line of a stderr ("Error: …", otherwise the first non-empty one), truncated as in Burn.qml."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    line = next((x for x in lines if x.startswith("Error: ")), lines[0] if lines else "")
    return line if len(line) <= 160 else line[:159] + "…"


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
        # "xdg-open" of the Linux QML: File Explorer on Windows, Finder or the browser on macOS (opened by the
        # system, not as our child). Linux: xdg-open itself, with child_environment(): QDesktopServices would pass
        # it the frozen bundle's environment.
        if command[0] == "xdg-open" and sys.platform in ("win32", "darwin"):
            QDesktopServices.openUrl(QUrl.fromUserInput(command[1]))
            return
        p = QProcess()
        p.setProgram(command[0])
        p.setArguments(command[1:])
        p.setProcessEnvironment(child_environment())
        p.setWorkingDirectory(self._data)
        if not p.startDetached():
            log.warning("%s: cannot launch", " ".join(command))


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
        self._stderr = None
        self._since = 0.0
        self._pending = False   # running set without command: launched after loading

    def _set_running(self, running):
        # Like qs, which only launches after loading: running: true written before command: waits for it.
        self._pending = running and not self._command
        if self._pending:
            QTimer.singleShot(0, self, lambda: self._pending and self._command and self._set_running(True))
        if not running:
            if self._process:
                self._process.terminate()
            return
        if self._process or not self._command or _closing:   # app closing: a launched run would be killed
            return
        p = self._process = QProcess(self)
        env = child_environment()   # + environment requested by the QML (null = removed)
        for name, value in self._environment.items():
            if value is None:
                env.remove(name)
            else:
                env.insert(name, str(value))
        p.setProcessEnvironment(env)
        if _global is not None:   # working directory without ./.agent-burn/ (config the CLI would read there)
            p.setWorkingDirectory(_global.dataDir)
        # Anonymous functions, not bound methods: PySide would add slots to the object, clashing
        # with the properties the QML declares on it (component Cli: Process { property … }) → lost
        # signals. Ignored once either of the two is destroyed (app closing during a run).
        def relay(handler):
            return lambda *args: shiboken6.isValid(self) and shiboken6.isValid(p) and handler(*args)

        p.started.connect(relay(self._started))
        p.finished.connect(relay(self._finished))
        p.errorOccurred.connect(relay(self._error))
        self._since = time.monotonic()
        _runs.add(p)
        p.start(self._command[0], self._command[1:])

    running = Property(bool, lambda self: self._process is not None, _set_running, notify=runningChanged)
    command = Property(list, lambda self: self._command, lambda self, v: setattr(self, "_command", list(v)))
    environment = Property(dict, lambda self: self._environment, lambda self, v: setattr(self, "_environment", dict(v)))
    stdout = Property(QObject, lambda self: self._stdout, lambda self, v: setattr(self, "_stdout", v))
    stderr = Property(QObject, lambda self: self._stderr, lambda self, v: setattr(self, "_stderr", v))

    # shortcut: exec() during a run relaunches nothing when it ends (never done by the shared QML).
    @Slot(dict)
    def exec(self, context):
        self._set_running(False)
        if "command" in context:
            self.command = context["command"]
        if "environment" in context:
            self.environment = context["environment"]
        self._set_running(True)

    # shortcut: any signal kills the process (only signal(9) is used, and Windows has no signals).
    @Slot(int)
    def signal(self, _signal):
        if self._process:
            self._process.kill()

    def _started(self):
        self.runningChanged.emit()
        self.started.emit()

    def _finished(self, code, status):
        p, self._process = self._process, None
        _runs.discard(p)
        p.deleteLater()
        out = bytes(p.readAllStandardOutput())
        err = bytes(p.readAllStandardError()).decode("utf-8", "replace")
        for collector, text in ((self._stdout, out.decode("utf-8", "replace")), (self._stderr, err)):
            if collector:
                collector._text = text
                collector.dataChanged.emit()
                collector.streamFinished.emit()
        # Arguments (our options and paths) and size only: stdout carries the user's usage.
        crashed = status != QProcess.ExitStatus.NormalExit
        cmd = " ".join(self._command)
        log.info("%s: code %d%s, %.2f s, %d bytes", cmd, code, " (killed)" if crashed else "",
                 time.monotonic() - self._since, len(out))
        if code or crashed:
            log.warning("%s: %s", cmd, _first_error(err) or "empty stderr")
        # Detailed log: stderr tail of each run, redacted by the app's handlers like the rest.
        log.debug("%s: stderr\n%s", cmd, err.strip()[-4000:] or "empty")
        self.exited.emit(code, status.value)
        self.runningChanged.emit()

    def _error(self, error):
        if error == QProcess.ProcessError.FailedToStart:
            log.warning("%s: cannot launch (%s)", " ".join(self._command), self._process.errorString())
            _runs.discard(self._process)
            self._process.deleteLater()
            self._process = None
            self.runningChanged.emit()


def _accepted():
    # qs setting accepted without effect: reads and writes are always synchronous here.
    return Property(bool, lambda self: True, lambda self, v: None)


class FileView(QObject):
    pathChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._text = None   # None: not read yet

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
            except OSError:   # missing or unreadable: empty, like qs
                self._text = ""
        return self._text

    @Slot()
    def reload(self):
        self._text = None

    @Slot(str)
    def setText(self, text):
        Path(self._path).parent.mkdir(parents=True, exist_ok=True)
        f = QSaveFile(self._path)   # temporary file renamed: never a half-written JSON
        if f.open(QIODevice.OpenModeFlag.WriteOnly):
            f.write(text.encode("utf-8"))
            f.commit()
        self._text = text


class IpcHandler(QObject):
    # No IPC outside qs: target kept, functions declared in QML callable from Python.
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
        # Windows and macOS: last input polled every 5 s.
        # shortcut: never idle on Linux, the Linux desktop app keeps taking readings while idle;
        # hook up ext-idle-notify (Wayland) or XScreenSaver (X11) if that usage matters.
        # shortcut: inhibitors ignored on Windows and macOS (video without input = idle, unlike the
        # respectInhibitors of qs), to review if the icon freezes during a video.
        if sys.platform in ("win32", "darwin"):
            self._poll = QTimer(self, interval=5000, timeout=lambda: self._check())   # no bound method: see Process
            self._poll.start()

    timeout = Property(float, lambda self: self._timeout, lambda self, v: setattr(self, "_timeout", v))
    isIdle = Property(bool, lambda self: self._idle, notify=isIdleChanged)

    def _check(self):
        if sys.platform == "win32":
            from agentburn import platform_win as system
        else:
            from agentburn import platform_mac as system
        idle = self._timeout > 0 and system.idle_seconds() >= self._timeout
        if idle != self._idle:
            self._idle = idle
            self.isIdleChanged.emit()


_global = None   # instance of the "Quickshell" singleton, kept alive


def wait_for_runs(timeout_ms):
    """App closing, before destroying the QML engine: waits at most timeout_ms for the CLI runs in progress
    to end (killed, a run may lose the Claude token it just renewed), then launches none, not even
    from their exited. True if all have ended."""
    global _closing
    _closing = True
    end = time.monotonic() + timeout_ms / 1000
    for p in [p for p in _runs if shiboken6.isValid(p)]:
        p.waitForFinished(max(0, int((end - time.monotonic()) * 1000)))
    return not any(shiboken6.isValid(p) for p in _runs)


def register(qml_dir, data_dir):
    """Registers the types under the Quickshell URIs; Quickshell.Widgets comes from qml_dir/widgets."""
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
