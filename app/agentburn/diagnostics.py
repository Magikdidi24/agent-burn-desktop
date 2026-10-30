# QML singleton "Desktop": versions (app, CLI, build), platform, directories; opens logs, data and
# licenses; diagnostics text to copy. Never any environment variables or file contents
# in this text, and secrets are redacted in it as in the log.
import datetime
import json
import logging
import os
import re
import sys
from pathlib import Path

import shiboken6
from PySide6.QtCore import Property, QObject, QProcess, QSysInfo, QTimer, QUrl, Signal, Slot, qVersion
from PySide6.QtGui import QDesktopServices, QGuiApplication
from PySide6.QtQml import QQmlEngine, QQmlExpression

from agentburn import __version__, logs, shim

log = logging.getLogger("agentburn")
BUILD_KEYS = ("appVersion", "cliRev", "cliVersion", "target", "builtAt")
PROBE_MS = 10000   # agent-burn --version stuck: killed after this timeout
# Burn state read in the Main.qml context, serialized to JSON: no conversion of JS values by PySide.
_BURN = """JSON.stringify({ data: Burn.stateText(Burn.dataState), updatedAt: Burn.updatedAt, errors: Burn.recentErrors,
    providers: Array.from(new Set(Burn.knownProviders.concat(Burn.agents)))
        .map(a => Object.assign({ name: Burn.agentName(a) }, Burn.providerState(a))) })"""


def build_info():
    """Frozen: build-info.json placed in the bundle by the build (next to the exe; macOS: Contents/Resources,
    linked from Contents/Frameworks); dev: pinned CLI in cli.env."""
    info = {"appVersion": __version__, "target": "dev"}
    if getattr(sys, "frozen", False):
        try:
            found = json.loads((Path(sys._MEIPASS) / "build-info.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("build-info.json unreadable: %s", e)
            found = {}
        info = {"appVersion": __version__, **(found if isinstance(found, dict) else {})}
    else:
        pin = next((p / "cli.env" for p in Path(__file__).resolve().parents if (p / "cli.env").is_file()), None)
        text = pin.read_text(encoding="utf-8") if pin else ""
        for key, pattern in (("cliRev", r'(?m)^AB_REV=(\w+)'), ("cliVersion", r'(?m)^AB_VER="([^"]+)"')):
            m = re.search(pattern, text)
            info[key] = m[1] if m else ""
    return {k: str(info.get(k, "")) for k in BUILD_KEYS}


def open_path(path):
    """Directory opened in the file manager. Linux: xdg-open with the environment cleaned by the shim
    (QDesktopServices would pass it the frozen bundle's one); Windows and macOS: by the system."""
    if sys.platform in ("win32", "darwin"):
        ok = QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
    else:
        p = QProcess()
        p.setProgram("xdg-open")
        p.setArguments([str(path)])
        p.setProcessEnvironment(shim.child_environment())
        ok = p.startDetached()
    if not ok:
        log.warning("%s: cannot open", path)


def _time(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).astimezone().strftime("%Y-%m-%d %H:%M:%S") if ms else "never"


class Desktop(QObject):
    changed = Signal()   # cliVersion, trayAvailable, screens

    def __init__(self, bin, data_dir, settings_file, log_dir, cache_dir):
        super().__init__()
        self._bin = str(bin)
        # settings_file None: settings in memory (selftest), no real directory to name.
        config = "in memory" if settings_file is None else str(Path(settings_file).parent)
        self._dirs = {"data": str(data_dir), "config": config, "log": str(log_dir), "cache": str(cache_dir)}
        self._cli = ""        # "": version not read yet
        self._probe = None
        self._tray = False    # icon placed in a system tray
        self._root = None
        self._build = build_info()
        bundled = getattr(sys, "frozen", False) and Path(sys._MEIPASS) / "licenses"
        self._licenses = bundled if bundled and bundled.is_dir() else None
        app = QGuiApplication.instance()
        app.screenAdded.connect(lambda *_: self.changed.emit())
        app.screenRemoved.connect(lambda *_: self.changed.emit())

    def attach(self, root):
        """Main.qml root: its context gives access to Burn for the diagnostics."""
        self._root = root

    def setTrayAvailable(self, on):
        if on != self._tray:
            self._tray = on
            self.changed.emit()

    appVersion = Property(str, lambda self: __version__, constant=True)
    platformName = Property(str, lambda self: QGuiApplication.platformName(), constant=True)
    desktopEnv = Property(str, lambda self: os.environ.get("XDG_CURRENT_DESKTOP", ""), constant=True)
    sessionType = Property(str, lambda self: os.environ.get("XDG_SESSION_TYPE", ""), constant=True)
    os = Property(str, lambda self: f"{QSysInfo.prettyProductName()} · {QSysInfo.kernelType()} "
                                    f"{QSysInfo.kernelVersion()} · {QSysInfo.currentCpuArchitecture()}", constant=True)
    buildInfo = Property("QVariantMap", lambda self: self._build, constant=True)
    cliPath = Property(str, lambda self: self._bin, constant=True)
    cliVersion = Property(str, lambda self: self._cli, notify=changed)
    trayAvailable = Property(bool, lambda self: self._tray, notify=changed)
    screens = Property(str, lambda self: ", ".join(
        f"{s.name() or 'screen'} {s.size().width()}×{s.size().height()} ×{s.devicePixelRatio():g}"
        for s in QGuiApplication.screens()),
        notify=changed)
    dataDir = Property(str, lambda self: self._dirs["data"], constant=True)
    configDir = Property(str, lambda self: self._dirs["config"], constant=True)
    logDir = Property(str, lambda self: self._dirs["log"], constant=True)
    cacheDir = Property(str, lambda self: self._dirs["cache"], constant=True)
    licensesAvailable = Property(bool, lambda self: self._licenses is not None, constant=True)

    @Slot()
    def probeCli(self):
        """agent-burn --version in the background (never any waiting in the UI); rerun when the settings
        open, after a CLI reinstall for example."""
        if self._probe:
            return
        p = self._probe = QProcess(self)
        p.setProcessEnvironment(shim.child_environment())
        p.setWorkingDirectory(self._dirs["data"])   # like Burn's runs: no ./.agent-burn/ read
        hung = []

        def done(code=0, status=None, failed=False):
            # Ignored if either one is destroyed (process killed when the app closes).
            if not (shiboken6.isValid(self) and shiboken6.isValid(p)) or self._probe is not p:
                return
            self._probe = None
            out = bytes(p.readAllStandardOutput()).decode("utf-8", "replace").strip()
            text = ("not found" if failed else f"no response ({PROBE_MS // 1000} s)" if hung
                    else out or "unreadable" if code == 0 and status == QProcess.ExitStatus.NormalExit
                    else f"failed (code {code})")
            p.deleteLater()
            if text != self._cli:
                self._cli = text
                self.changed.emit()

        p.finished.connect(done)
        p.errorOccurred.connect(lambda e: e == QProcess.ProcessError.FailedToStart and done(failed=True))
        QTimer.singleShot(PROBE_MS, p, lambda: (hung.append(True), p.kill()))   # finished follows, after the kill
        p.start(self._bin, ["--version"])

    def facts(self):
        """(label, value) pairs of the diagnostics, also the startup line of the log."""
        b = self._build
        return [("Agent Burn", f"{__version__} ({b['target'] or 'build'}{', ' + b['builtAt'] if b['builtAt'] else ''})"),
                ("Pinned CLI", f"{b['cliVersion'] or '—'}, revision {b['cliRev'][:12] or '—'}"),
                ("CLI", f"{self._bin} ({self._cli or ('being read' if self._probe else 'version not read')})"),
                ("System", self.os),
                ("Qt", f"{qVersion()}, platform {self.platformName}"),
                ("Desktop", f"{self.desktopEnv or '—'}, session {self.sessionType or '—'}"),
                ("Screens", self.screens or "none"),
                ("System tray", "yes" if self._tray else "no"),
                ("Data", self._dirs["data"]), ("Settings", self._dirs["config"]),
                ("Logs", self._dirs["log"]), ("Cache", self._dirs["cache"])]

    def _burn(self):
        if self._root is None:
            return None
        value = QQmlExpression(QQmlEngine.contextForObject(self._root), self._root, _BURN).evaluate()[0]
        try:
            return json.loads(value)
        except (TypeError, ValueError):
            return None

    @Slot(result=str)
    def diagnosticsText(self):
        lines = [f"{k}: {v}" for k, v in self.facts()]
        burn = self._burn()
        if burn is None:
            lines.append("agent-burn data: not read")
        else:
            lines.append(f"agent-burn data: {burn['data']}, updated {_time(burn['updatedAt'])}")
            for p in burn["providers"]:
                lines.append(f"{p['name']}: {p['label']}. {p['detail']}"
                             + (f" Last reading {_time(p['at'])}." if p["at"] else "")
                             + (f" Error: {p['error']}" if p["error"] else ""))
            lines.append("Recent errors:" + ("" if burn["errors"] else " none"))
            lines += [f"  {_time(e['t'])} {e['source']}: {e['msg']}" for e in reversed(burn["errors"])]
        return logs.redact("\n".join(lines))

    @Slot()
    def copyDiagnostics(self):
        QGuiApplication.clipboard().setText(self.diagnosticsText())

    @Slot()
    def openLogs(self):
        open_path(self._dirs["log"])

    @Slot()
    def openDataDir(self):
        open_path(self._dirs["data"])

    @Slot()
    def openLicenses(self):
        if self._licenses:
            open_path(self._licenses)
