# In-app update, frozen Windows builds only (build-info.json target windows-x64 or windows-arm64); elsewhere
# (Linux, dev runs) nothing runs and nothing is requested. The latest GitHub release is checked a minute after
# launch, then every 24 h, or on request. Installed app: the release's installer is downloaded to the cache,
# checked against the release's SHA256SUMS, run silently, and the app quits; the installer starts it again
# (/relaunch=1, installer.iss). Portable zip: the release page opens. Network data is validated before use.
import hashlib
import json
import logging
import os
import re
import unicodedata
from pathlib import Path

from PySide6.QtCore import Property, QCoreApplication, QObject, QProcess, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkReply, QNetworkRequest

from agentburn import __version__, paths, shim

log = logging.getLogger("agentburn.update")
API = "https://api.github.com/repos/Magikdidi24/agent-burn-desktop"
SITE = "https://github.com/Magikdidi24/agent-burn-desktop"   # release pages and downloads
ARCHS = {"windows-x64": "x64", "windows-arm64": "arm64"}   # build-info.json targets, written by build.ps1 only
TAG = re.compile(r"desktop-v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})")   # [0-9]: \d takes any script's digits
SUM = re.compile(r"([0-9a-fA-F]{64}) [ *](.+)")   # sha256sum line, text or binary mode
FIRST_MS, EVERY_MS = 60_000, 24 * 3_600_000
TIMEOUT_MS = 30_000   # no data for that long: request given up
MAX_JSON, MAX_SUMS, MAX_SETUP = 1 << 20, 64 << 10, 256 << 20   # the installer is about 40 MB
SETUP = "AgentBurn-Setup.exe"   # in the cache, replaced by each download
ARGS = ["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/relaunch=1"]


def clean(text, limit=200):
    """Network text safe to show or log: no control or format characters (line breaks, escapes, bidi
    overrides), bounded length."""
    return "".join(c for c in str(text) if unicodedata.category(c)[0] != "C")[:limit]


def parse(release, arch, site, portable):
    """What a "latest release" answer offers this build: None if nothing newer (drafts and pre-releases
    ignored), otherwise {version, page} (portable) or {version, name, setup, size, sums} (installer: file
    name, addresses and size). ValueError: not a release this app can use."""
    if not isinstance(release, dict):
        raise ValueError("unreadable answer")
    if release.get("draft") or release.get("prerelease"):
        return None
    tag = release.get("tag_name")
    m = TAG.fullmatch(tag) if isinstance(tag, str) else None
    if not m:
        raise ValueError(f"unexpected release tag {clean(tag, 40)!r}")
    if tuple(map(int, m.groups())) <= tuple(map(int, __version__.split("."))):
        return None
    version = tag.removeprefix("desktop-v")
    if portable:
        page = f"{site}/releases/tag/{tag}"
        if release.get("html_url") != page:
            raise ValueError("release page outside the repository")
        return {"version": version, "page": page}
    assets = release.get("assets")
    found = {a.get("name"): a for a in assets if isinstance(a, dict)} if isinstance(assets, list) else {}
    offer = {"version": version, "name": f"AgentBurn-Setup-{version}-{arch}.exe"}
    for key, name, limit in (("setup", offer["name"], MAX_SETUP), ("sums", "SHA256SUMS", MAX_SUMS)):
        a = found.get(name)
        if a is None:
            raise ValueError(f"{name} missing from the release")
        # The exact address, not only its prefix: ".../desktop-vX.Y.Z/../../" would leave the repository.
        if a.get("browser_download_url") != f"{site}/releases/download/{tag}/{name}":
            raise ValueError(f"{name}: download address outside the repository")
        if type(a.get("size")) is not int or not 0 < a["size"] <= limit:
            raise ValueError(f"{name}: unexpected size")
        offer[key] = a["browser_download_url"]
    offer["size"] = found[offer["name"]]["size"]   # the download stops beyond it
    return offer


def _discard(path):
    try:
        path.unlink(missing_ok=True)
    except OSError as e:   # held by an antivirus…: the next download replaces it
        log.warning("update: %s not deleted: %s", path, e)


def checksum(text, name):
    """The SHA-256 that a SHA256SUMS text gives name, None if it has none or several."""
    sums = {m[1].lower() for m in map(SUM.fullmatch, text.splitlines()) if m and m[2] == name}
    return sums.pop() if len(sums) == 1 else None


class Updater(QObject):
    """QML singleton "Updater" (desktop app). mode: "installer", "portable" or "" (not supported: no request);
    state: "" (not checked yet), checking, current, available, downloading, installing or error (message)."""
    changed = Signal()

    def __init__(self, target, app_dir, settings):
        """target: build-info.json's; app_dir: folder of the exe (Inno's unins000.exe there: installed);
        settings: Settings, for start at login."""
        super().__init__()
        self._arch = ARCHS.get(target)
        self._mode = "" if not self._arch else "installer" if (Path(app_dir) / "unins000.exe").is_file() else "portable"
        self._settings = settings
        self._state, self._version, self._progress, self._message = "", "", 0, ""
        self._offer = None
        base = os.environ.get("AGENT_BURN_UPDATE_URL", "").rstrip("/")   # tests: a local server instead of GitHub
        self._api, self._site = (base, base) if base else (API, SITE)
        if base and self._mode:
            log.warning("AGENT_BURN_UPDATE_URL set: updates read from %s", base)
        self._net = QNetworkAccessManager(self) if self._mode else None
        self._timer = QTimer(self, interval=FIRST_MS, timeout=lambda: (self._timer.setInterval(EVERY_MS), self.check()))

    mode = Property(str, lambda self: self._mode, notify=changed)
    state = Property(str, lambda self: self._state, notify=changed)
    version = Property(str, lambda self: self._version, notify=changed)
    progress = Property(int, lambda self: self._progress, notify=changed)   # download, in %
    message = Property(str, lambda self: self._message, notify=changed)

    def start(self):
        """Automatic checks (tray mode): a minute after launch, then every 24 h."""
        if self._mode:
            self._timer.start()

    def _show(self, state, progress=0, message=""):
        self._state, self._progress, self._message = state, progress, clean(message)
        self.changed.emit()

    def _fail(self, message):
        log.warning("update: %s", clean(message))
        self._show("error", message=message)

    def _get(self, url, limit, done, file=None, accept=None):
        """GET url; done(data, error) at the end: data (bytes, b"" when written to file) or an error text.
        Given up beyond limit bytes."""
        req = QNetworkRequest(QUrl(url))
        req.setHeader(QNetworkRequest.KnownHeaders.UserAgentHeader, f"AgentBurn/{__version__}")
        if accept:
            req.setRawHeader(b"Accept", accept)
        req.setTransferTimeout(TIMEOUT_MS)
        reply = self._net.get(req)
        chunks, size, problem = [], 0, []

        def read():
            nonlocal size
            data = bytes(reply.readAll())
            size += len(data)
            if size > limit:
                problem.append("larger than announced")
                reply.abort()   # finished follows
            elif file is None:
                chunks.append(data)
            elif data:
                try:
                    file.write(data)
                except OSError as e:   # disk full…
                    problem.append(str(e))
                    reply.abort()
                    return
                if size * 100 // limit != self._progress:
                    self._show("downloading", size * 100 // limit)

        def finished():
            if not problem:
                read()   # what readyRead left
            reply.deleteLater()
            status = reply.attribute(QNetworkRequest.Attribute.HttpStatusCodeAttribute)
            if problem or reply.error() != QNetworkReply.NetworkError.NoError:
                done(None, problem[0] if problem else f"HTTP {status}" if status else clean(reply.errorString()))
            else:
                done(b"".join(chunks), "")

        reply.readyRead.connect(read)
        reply.finished.connect(finished)

    @Slot()
    def check(self):
        """Latest release, one request at a time."""
        if not self._mode or self._state in ("checking", "downloading", "installing"):
            return
        self._show("checking")
        self._get(self._api + "/releases/latest", MAX_JSON, self._checked, accept=b"application/vnd.github+json")

    def _checked(self, data, error):
        try:
            if error:
                raise ValueError(error)
            offer = parse(json.loads(data), self._arch, self._site, self._mode == "portable")
        except (ValueError, RecursionError) as e:   # JSON and UTF-8 errors are ValueErrors
            self._fail(f"Update check failed: {e}")
            return
        self._offer, self._version = offer, offer["version"] if offer else ""
        log.info("update: %s", f"Agent Burn {self._version} available" if offer else f"up to date ({__version__})")
        self._show("available" if offer else "current")

    @Slot()
    def update(self):
        """Portable zip: the release page opens. Installed app: download, check, install, quit."""
        if not self._mode or self._state != "available":
            return
        if self._mode == "portable":
            if not QDesktopServices.openUrl(QUrl(self._offer["page"])):
                log.warning("update: %s: cannot open", self._offer["page"])
            return
        self._show("downloading")
        self._get(self._offer["sums"], MAX_SUMS, self._got_sums)

    def _got_sums(self, data, error):
        expected = checksum(data.decode("utf-8", "replace"), self._offer["name"]) if data else None
        if not expected:
            self._fail(f"Download failed: {error or 'no single SHA-256 sum for ' + self._offer['name']}")
            return
        path = paths.cache_dir() / SETUP
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            file = open(path, "wb")
        except OSError as e:
            self._fail(f"Download failed: {e}")
            return
        self._get(self._offer["setup"], self._offer["size"],
                  lambda _, error: self._got_setup(path, file, expected, error), file)

    def _got_setup(self, path, file, expected, error):
        try:
            file.close()
            if not error:
                with open(path, "rb") as f:   # the file as it is on disk, the one that will run
                    error = "" if hashlib.file_digest(f, "sha256").hexdigest() == expected \
                        else "the installer does not match its SHA-256 sum, nothing was installed"
        except OSError as e:
            error = str(e)
        if error:
            _discard(path)
            self._fail(f"Download failed: {error}")
            return
        # Inno restores the tasks of the previous installation: its "autostart" would turn start at login back
        # on. No quotes around !autostart: QProcess would escape them.
        args = ARGS + ([] if self._settings.property("autostart") else ["/MERGETASKS=!autostart"])
        p = QProcess()
        p.setProgram(str(path))
        p.setArguments(args)
        p.setProcessEnvironment(shim.child_environment())   # passed on to the relaunched app: no _PYI_* of ours
        if not p.startDetached():
            _discard(path)
            self._fail("Could not start the installer")
            return
        log.info("update: %s %s started, quitting", path, " ".join(args))
        self._show("installing")
        QCoreApplication.quit()   # the usual way out: CLI runs waited for, single-instance lock released
