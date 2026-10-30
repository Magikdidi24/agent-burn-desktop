# In-app update, frozen Windows and macOS builds only (build-info.json target windows-x64, windows-arm64 or
# macos-arm64); elsewhere (Linux, dev runs) nothing runs and nothing is requested. The latest GitHub release is
# checked a minute after launch, then every 24 h, or on request. Installed Windows app: the release's installer is
# downloaded to the cache, checked against the release's SHA256SUMS, run silently, and the app quits; the installer
# starts it again (/relaunch=1, installer.iss). macOS bundle this user can replace: the release's zip, checked the
# same way, is unpacked in the cache and checked, the app quits, HELPER swaps the bundles and opens the new one.
# Portable zip, or a bundle that cannot be replaced: the release page opens. Network data is validated before use.
import hashlib
import json
import logging
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unicodedata
from pathlib import Path

from PySide6.QtCore import Property, QCoreApplication, QObject, QProcess, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QDesktopServices
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkReply, QNetworkRequest

from agentburn import __version__, paths, shim

log = logging.getLogger("agentburn.update")
API = "https://api.github.com/repos/Magikdidi24/agent-burn-desktop"
SITE = "https://github.com/Magikdidi24/agent-burn-desktop"   # release pages and downloads
# build-info.json targets (build scripts) and the release file that updates each one ({}: version)
ASSETS = {"windows-x64": "AgentBurn-Setup-{}-x64.exe", "windows-arm64": "AgentBurn-Setup-{}-arm64.exe",
          "macos-arm64": "AgentBurn-{}-macos-arm64.zip"}
TAG = re.compile(r"desktop-v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})")   # [0-9]: \d takes any script's digits
SUM = re.compile(r"([0-9a-fA-F]{64}) [ *](.+)")   # sha256sum line, text or binary mode
FIRST_MS, EVERY_MS = 60_000, 24 * 3_600_000
TIMEOUT_MS = 30_000   # no data for that long: request given up
MAX_JSON, MAX_SUMS, MAX_SETUP = 1 << 20, 64 << 10, 256 << 20   # the installer is about 40 MB
SETUP = "AgentBurn-Setup.exe"   # in the cache, replaced by each download
ZIP = "AgentBurn-update.zip"   # macOS, the same way; deleted once unpacked
ARGS = ["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/relaunch=1"]
BUNDLE, BUNDLE_ID = "Agent Burn.app", "io.github.magikdidi24.AgentBurn"   # what the macOS zip holds (HELPER too)
# macOS, started detached just before the app quits. $1: its PID, $2: its bundle, $3: the cache folder where the
# new bundle was unpacked. Paths come only as arguments, never in the text.
HELPER = """\
pid=$1 app=$2 work=$3
n=0
while kill -0 "$pid" 2>/dev/null; do   # the app quitting: CLI runs awaited, 5 s at most
    n=$((n + 1))
    [ "$n" -le 300 ] || { rm -rf "$work"; exit 1; }   # still there after a minute: nothing replaced
    sleep 0.2
done
if mv "$app" "$work/old.app"; then
    if ! mv "$work/Agent Burn.app" "$app"; then   # the old bundle back
        rm -rf "$app"   # what a copy to another disk left, if anything
        mv "$work/old.app" "$app" || exit 1   # failing that, it stays in the cache
    fi
    rm -rf "$work"
elif [ ! -e "$work/old.app" ]; then   # there: half a copy to another disk, kept in case
    rm -rf "$work"
fi
open "$app"
"""


def clean(text, limit=200):
    """Network text safe to show or log: no control or format characters (line breaks, escapes, bidi
    overrides), bounded length."""
    return "".join(c for c in str(text) if unicodedata.category(c)[0] != "C")[:limit]


def parse(release, asset, site, portable):
    """What a "latest release" answer offers this build (asset: its ASSETS value): None if nothing newer (drafts
    and pre-releases ignored), otherwise {version, page} (portable) or {version, name, setup, size, sums}
    (installer: file name, addresses and size). ValueError: not a release this app can use."""
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
    found = {a["name"]: a for a in assets if isinstance(a, dict) and isinstance(a.get("name"), str)} \
        if isinstance(assets, list) else {}
    offer = {"version": version, "name": asset.format(version)}
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


def extract(archive, folder):
    """macOS: the release zip unpacked into folder by ditto, which keeps the bundle's symlinks, permissions and
    signature (zipfile does not). OSError or subprocess.SubprocessError on failure."""
    env = shim.child_environment()
    r = subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(folder)], capture_output=True,
                       timeout=120, env={k: env.value(k) for k in env.keys()})
    if r.returncode:
        raise OSError(f"ditto: {r.stderr.decode(errors='replace').strip() or r.returncode}")


class Updater(QObject):
    """QML singleton "Updater" (desktop app). mode: "installer" (updates itself), "portable" (release page) or ""
    (not supported: no request); state: "" (not checked yet), checking, current, available, downloading,
    installing or error (message)."""
    changed = Signal()

    def __init__(self, target, app_dir, settings):
        """target: build-info.json's; app_dir: folder of the exe (Windows: Inno's unins000.exe there, installed;
        macOS: the bundle's Contents/MacOS); settings: Settings, for start at login."""
        super().__init__()
        self._asset = ASSETS.get(target)
        # macOS: the bundle is replaced whole, so this user must be able to write to it and to its folder (not a
        # disk image, App Translocation's read-only copy or /Applications for a standard account).
        bundle = Path(app_dir).parent.parent
        self._bundle = bundle if self._asset and target.startswith("macos-") and bundle.suffix == ".app" \
            and os.access(bundle, os.W_OK) and os.access(bundle.parent, os.W_OK) else None
        installed = self._bundle or (Path(app_dir) / "unins000.exe").is_file()
        self._mode = "" if not self._asset else "installer" if installed else "portable"
        self._settings = settings
        self._state, self._version, self._progress, self._message = "", "", 0, ""
        self._offer = None
        base = os.environ.get("AGENT_BURN_UPDATE_URL", "").rstrip("/")   # tests: a local server instead of GitHub
        # This machine only: a variable set behind the user's back cannot point "Update now" at another installer.
        if base and QUrl(base).host() not in ("127.0.0.1", "localhost", "::1"):
            if self._mode:
                log.warning("AGENT_BURN_UPDATE_URL ignored, not on this machine: %s", clean(base))
            base = ""
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
            offer = parse(json.loads(data), self._asset, self._site, self._mode == "portable")
        # JSON and UTF-8 errors are ValueErrors; TypeError: an answer shaped oddly must not leave "checking" stuck.
        except (ValueError, TypeError, RecursionError) as e:
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
        path = paths.cache_dir() / (ZIP if self._bundle else SETUP)
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
                    what = "zip" if self._bundle else "installer"
                    error = "" if hashlib.file_digest(f, "sha256").hexdigest() == expected \
                        else f"the {what} does not match its SHA-256 sum, nothing was installed"
        except OSError as e:
            error = str(e)
        if error:
            _discard(path)
            self._fail(f"Download failed: {error}")
            return
        if self._bundle:
            self._replace(path)
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

    def _replace(self, path):
        """macOS: the checked zip unpacked into a new folder of the cache, its bundle checked, then HELPER started
        and the app quit: HELPER puts the new bundle in place of this one and opens it."""
        work = None
        try:
            work = Path(tempfile.mkdtemp(prefix="update-", dir=path.parent))
            extract(path, work)
            with open(work / BUNDLE / "Contents" / "Info.plist", "rb") as f:
                info = plistlib.load(f)
            # This app, at exactly the version offered: not some other file or release swapped in by mistake.
            if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID \
                    or info.get("CFBundleShortVersionString") != self._offer["version"]:
                raise ValueError(f"the zip does not hold Agent Burn {self._offer['version']}, nothing was installed")
        # Whatever the zip holds (no Info.plist, bad XML, extreme nesting…): reported, never stuck in "downloading".
        except Exception as e:
            if work:
                shutil.rmtree(work, ignore_errors=True)
            self._fail(f"Download failed: {e}")
            return
        finally:
            _discard(path)   # unpacked or not, no longer needed
        p = QProcess()
        p.setProgram("/bin/sh")
        p.setArguments(["-c", HELPER, "sh", str(os.getpid()), str(self._bundle), str(work)])
        p.setProcessEnvironment(shim.child_environment())
        if not p.startDetached():
            shutil.rmtree(work, ignore_errors=True)
            self._fail("Could not start the update")
            return
        log.info("update: %s replaced by Agent Burn %s once the app has quit", self._bundle, self._offer["version"])
        self._show("installing")
        QCoreApplication.quit()
