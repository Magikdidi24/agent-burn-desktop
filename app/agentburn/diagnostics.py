# Singleton QML « Desktop » : versions (app, CLI, build), plateforme, dossiers ; ouvre journaux, données et
# licences ; texte de diagnostic à copier. Jamais de variables d'environnement ni de contenu de fichier
# dans ce texte, et les secrets y sont masqués comme dans le journal.
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
PROBE_MS = 10000   # agent-burn --version bloqué : tué au bout de ce délai
# État de Burn lu dans le contexte de Main.qml, sérialisé en JSON : aucune conversion de valeurs JS par PySide.
_BURN = """JSON.stringify({ data: Burn.stateText(Burn.dataState), updatedAt: Burn.updatedAt, errors: Burn.recentErrors,
    providers: Array.from(new Set(Burn.knownProviders.concat(Burn.agents)))
        .map(a => Object.assign({ name: Burn.agentName(a) }, Burn.providerState(a))) })"""


def build_info():
    """Gelé : build-info.json posé à côté de l'exe par le build ; dev : CLI épinglé dans install.sh."""
    info = {"appVersion": __version__, "target": "dev"}
    if getattr(sys, "frozen", False):
        try:
            found = json.loads((Path(sys.executable).parent / "build-info.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("build-info.json illisible : %s", e)
            found = {}
        info = {"appVersion": __version__, **(found if isinstance(found, dict) else {})}
    else:
        sh = next((p / "install.sh" for p in Path(__file__).resolve().parents if (p / "install.sh").is_file()), None)
        text = sh.read_text(encoding="utf-8") if sh else ""
        for key, pattern in (("cliRev", r'(?m)^AB_REV=(\w+)'), ("cliVersion", r'(?m)^AB_VER="([^"]+)"')):
            m = re.search(pattern, text)
            info[key] = m[1] if m else ""
    return {k: str(info.get(k, "")) for k in BUILD_KEYS}


def open_path(path):
    """Dossier ouvert dans le gestionnaire de fichiers. Linux : xdg-open avec l'environnement nettoyé du shim
    (QDesktopServices lui passerait celui du bundle gelé)."""
    if sys.platform == "win32":
        ok = QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
    else:
        p = QProcess()
        p.setProgram("xdg-open")
        p.setArguments([str(path)])
        p.setProcessEnvironment(shim.child_environment())
        ok = p.startDetached()
    if not ok:
        log.warning("%s : ouverture impossible", path)


def _time(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).astimezone().strftime("%Y-%m-%d %H:%M:%S") if ms else "jamais"


class Desktop(QObject):
    changed = Signal()   # cliVersion, trayAvailable, screens

    def __init__(self, bin, data_dir, settings_file, log_dir, cache_dir):
        super().__init__()
        self._bin = str(bin)
        self._dirs = {"data": str(data_dir), "config": str(Path(settings_file).parent), "log": str(log_dir),
                      "cache": str(cache_dir)}
        self._cli = ""        # "" : version pas encore lue
        self._probe = None
        self._tray = False    # icône posée dans une zone de notification
        self._root = None
        self._build = build_info()
        exe = Path(sys.executable).parent / "licenses"
        self._licenses = exe if getattr(sys, "frozen", False) and exe.is_dir() else None
        app = QGuiApplication.instance()
        app.screenAdded.connect(lambda *_: self.changed.emit())
        app.screenRemoved.connect(lambda *_: self.changed.emit())

    def attach(self, root):
        """Racine Main.qml : son contexte donne accès à Burn pour le diagnostic."""
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
        f"{s.name() or 'écran'} {s.size().width()}×{s.size().height()} ×{s.devicePixelRatio():g}" for s in QGuiApplication.screens()),
        notify=changed)
    dataDir = Property(str, lambda self: self._dirs["data"], constant=True)
    configDir = Property(str, lambda self: self._dirs["config"], constant=True)
    logDir = Property(str, lambda self: self._dirs["log"], constant=True)
    cacheDir = Property(str, lambda self: self._dirs["cache"], constant=True)
    licensesAvailable = Property(bool, lambda self: self._licenses is not None, constant=True)

    @Slot()
    def probeCli(self):
        """agent-burn --version en tâche de fond (jamais d'attente dans l'interface) ; relancé à l'ouverture
        des réglages, après une réinstallation du CLI par exemple."""
        if self._probe:
            return
        p = self._probe = QProcess(self)
        p.setProcessEnvironment(shim.child_environment())
        p.setWorkingDirectory(self._dirs["data"])   # comme les runs de Burn : pas de ./.agent-burn/ lu
        hung = []

        def done(code=0, status=None, failed=False):
            # Ignoré si l'un des deux est détruit (process tué à la fermeture de l'app).
            if not (shiboken6.isValid(self) and shiboken6.isValid(p)) or self._probe is not p:
                return
            self._probe = None
            out = bytes(p.readAllStandardOutput()).decode("utf-8", "replace").strip()
            text = ("introuvable" if failed else f"sans réponse ({PROBE_MS // 1000} s)" if hung
                    else out or "illisible" if code == 0 and status == QProcess.ExitStatus.NormalExit
                    else f"en échec (code {code})")
            p.deleteLater()
            if text != self._cli:
                self._cli = text
                self.changed.emit()

        p.finished.connect(done)
        p.errorOccurred.connect(lambda e: e == QProcess.ProcessError.FailedToStart and done(failed=True))
        QTimer.singleShot(PROBE_MS, p, lambda: (hung.append(True), p.kill()))   # finished suit, avec arrêt forcé
        p.start(self._bin, ["--version"])

    def facts(self):
        """(intitulé, valeur) du diagnostic, aussi la ligne de démarrage du journal."""
        b = self._build
        return [("Agent Burn", f"{__version__} ({b['target'] or 'build'}{', ' + b['builtAt'] if b['builtAt'] else ''})"),
                ("CLI épinglé", f"{b['cliVersion'] or '—'}, révision {b['cliRev'][:12] or '—'}"),
                ("CLI", f"{self._bin} ({self._cli or 'version non lue'})"),
                ("Système", self.os),
                ("Qt", f"{qVersion()}, plateforme {self.platformName}"),
                ("Bureau", f"{self.desktopEnv or '—'}, session {self.sessionType or '—'}"),
                ("Écrans", self.screens or "aucun"),
                ("Zone de notification", "oui" if self._tray else "non"),
                ("Données", self._dirs["data"]), ("Réglages", self._dirs["config"]),
                ("Journaux", self._dirs["log"]), ("Cache", self._dirs["cache"])]

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
        lines = [f"{k} : {v}" for k, v in self.facts()]
        burn = self._burn()
        if burn is None:
            lines.append("Données agent-burn : non lues")
        else:
            lines.append(f"Données agent-burn : {burn['data']}, mises à jour {_time(burn['updatedAt'])}")
            for p in burn["providers"]:
                lines.append(f"{p['name']} : {p['label']}. {p['detail']}" + (f" Relevé {_time(p['at'])}." if p["at"] else "")
                             + (f" Erreur : {p['error']}" if p["error"] else ""))
            lines.append("Dernières erreurs :" + ("" if burn["errors"] else " aucune"))
            lines += [f"  {_time(e['t'])} {e['source']} : {e['msg']}" for e in reversed(burn["errors"])]
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
