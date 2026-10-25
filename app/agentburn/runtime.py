# Dossier QML d'exécution : QML partagés (shared/, ceux de la barre Quickshell aussi) + QML de
# l'app de bureau + qmldir. Nommé d'après son contenu : l'app, un selftest ou une version de dev
# lancés en même temps ne se marchent pas dessus, et rien n'est recopié d'un lancement à l'autre.
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
    """(QML partagés, QML de l'app) : embarqués par PyInstaller, sinon lus dans le dépôt."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "shared", Path(sys._MEIPASS) / "qml"
    here = Path(__file__).resolve()
    shared = here.parents[2] / "shared"   # <dépôt>/app/agentburn/runtime.py
    if not (shared / "Burn.qml").is_file():
        raise SystemExit(f"{shared / 'Burn.qml'} introuvable")
    return shared, here.parents[1] / "qml"


def intact(d, content):
    """Copie en cache identique au contenu attendu, octet pour octet, sans fichier en plus."""
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
    # Relu à chaque lancement : un fichier modifié dans le cache (ou mis en quarantaine) ne s'exécute pas.
    if intact(dst, content):
        return dst
    cache.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="qml-", dir=cache))
    for rel, data in content.items():
        (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp / rel).write_bytes(data)
    if dst.exists():   # altéré ou incomplet : reconstruit
        shutil.rmtree(dst, ignore_errors=True)
    try:
        tmp.rename(dst)
    except OSError:
        # Renommage refusé (fichier juste écrit encore ouvert par l'antivirus ou l'indexeur), ou copie
        # altérée impossible à effacer : la nôtre, sauf si une autre instance vient d'en poser une saine.
        if not intact(dst, content):
            return tmp
        shutil.rmtree(tmp, ignore_errors=True)
    return dst
