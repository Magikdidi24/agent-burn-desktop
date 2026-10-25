# Runtime QML directory: shared QML (shared/, also used by the Quickshell bar) + QML of the
# desktop app + qmldir. Named after its content: the app, a selftest or a dev version launched
# at the same time don't step on each other, and nothing is copied again from one launch to the next.
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

from agentburn import paths

SHARED = ("Burn.qml", "BurnPopover.qml", "BurnDashboardView.qml", "BurnQuotaChart.qml", "BurnBarChart.qml",
          "BurnButton.qml")
SINGLETONS = ("Burn", "Colors")


def sources():
    """(shared QML, app QML): bundled by PyInstaller, otherwise read from the repository."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "shared", Path(sys._MEIPASS) / "qml"
    here = Path(__file__).resolve()
    shared = here.parents[2] / "shared"   # <repo>/app/agentburn/runtime.py
    if not (shared / "Burn.qml").is_file():
        raise SystemExit(f"{shared / 'Burn.qml'} not found")
    return shared, here.parents[1] / "qml"


def intact(d, content):
    """Cached copy identical to the expected content, byte for byte, with no extra file."""
    try:
        return (sorted(p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file()) == sorted(content)
                and all((d / rel).read_bytes() == data for rel, data in content.items()))
    except OSError:
        return False


def assemble():
    shared, own = sources()
    files = [(shared / f, f) for f in SHARED]
    files += [(p, f"assets/burn/{p.name}") for p in sorted((shared / "assets" / "burn").iterdir()) if p.is_file()]
    files += [(p, p.relative_to(own).as_posix()) for p in sorted(own.rglob("*")) if p.is_file()]
    digest = hashlib.sha1()
    content = {}
    for src, rel in files:
        content[rel] = src.read_bytes()
        digest.update(rel.encode() + b"\0" + content[rel])
    content["qmldir"] = "".join(f"{'singleton ' if rel[:-4] in SINGLETONS else ''}{rel[:-4]} 1.0 {rel}\n"
                                for rel in sorted(content) if "/" not in rel and rel.endswith(".qml")).encode()
    cache = paths.cache_dir()
    dst = cache / f"qml-{digest.hexdigest()[:12]}"
    # Checked again at every launch: a file changed in the cache (or quarantined) does not run.
    if intact(dst, content):
        return dst
    cache.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="qml-", dir=cache))
    for rel, data in content.items():
        (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp / rel).write_bytes(data)
    if dst.exists():   # tampered with or incomplete: rebuilt
        shutil.rmtree(dst, ignore_errors=True)
    try:
        tmp.rename(dst)
    except OSError:
        # Rename refused (file just written still open in the antivirus or the indexer), or tampered copy
        # that cannot be deleted: ours, unless another instance has just put a sound one in place.
        if not intact(dst, content):
            return tmp
        shutil.rmtree(tmp, ignore_errors=True)
    return dst
