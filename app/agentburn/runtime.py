# Dossier QML d'exécution : QML partagés du module Quickshell (jamais dupliqués dans git) + QML de
# l'app Windows + qmldir. Nommé d'après son contenu : l'app, un selftest ou une version de dev
# lancés en même temps ne se marchent pas dessus, et rien n'est recopié d'un lancement à l'autre.
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

from PySide6.QtCore import QStandardPaths

SHARED = ("Burn.qml", "BurnPopover.qml", "BurnDashboardView.qml", "BurnQuotaChart.qml", "BurnBarChart.qml")
SINGLETONS = ("Burn", "Colors")


def sources():
    """(QML partagés, QML de l'app) : embarqués par PyInstaller, sinon lus dans le dépôt."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "shared", Path(sys._MEIPASS) / "qml"
    here = Path(__file__).resolve()
    for p in here.parents:
        if (p / "config" / "quickshell" / "Burn.qml").is_file():
            return p / "config" / "quickshell", here.parents[1] / "qml"
    raise SystemExit(f"config/quickshell/Burn.qml introuvable au-dessus de {here}")


def assemble():
    shared, own = sources()
    files = [(shared / f, f) for f in SHARED]
    files += [(p, f"assets/burn/{p.name}") for p in sorted((shared / "assets" / "burn").iterdir()) if p.is_file()]
    files += [(p, p.relative_to(own).as_posix()) for p in sorted(own.rglob("*")) if p.is_file()]
    digest = hashlib.sha1()
    for src, rel in files:
        digest.update(rel.encode() + b"\0" + src.read_bytes())
    cache = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation))
    dst = cache / f"qml-{digest.hexdigest()[:12]}"
    if (dst / "qmldir").is_file():
        return dst
    cache.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="qml-", dir=cache))
    for src, rel in files:
        (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, tmp / rel)
    (tmp / "qmldir").write_text("".join(
        f"{'singleton ' if p.stem in SINGLETONS else ''}{p.stem} 1.0 {p.name}\n" for p in sorted(tmp.glob("*.qml"))))
    try:
        tmp.rename(dst)
    except OSError:
        # Renommage refusé (fichier juste écrit encore ouvert par l'antivirus ou l'indexeur) : même contenu.
        if not (dst / "qmldir").is_file():
            return tmp
        shutil.rmtree(tmp, ignore_errors=True)   # une autre instance l'a assemblé juste avant
    return dst
