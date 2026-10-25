#!/usr/bin/env python3
# THIRD-PARTY-NOTICES.txt du CLI agent-burn embarqué : chaque crate compilé dans le binaire (dépendances
# « normales » depuis le paquet agent-burn, résolues par cargo metadata d'après Cargo.lock), sa licence, son
# dépôt, puis les textes de licence livrés dans les crates (MIT, BSD, ISC… exigent leur copie). Lancé par
# linux/build.sh et build.ps1 après la compilation du CLI (sources des crates déjà dans le registre cargo).
#   python third_party_notices.py SOURCE SORTIE [--target TRIPLE]
import argparse
import json
import re
import subprocess
from pathlib import Path

LICENSE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|copyright|notice)")
RULE = "=" * 80


def crates(meta, root="agent-burn"):
    """Paquets tiers atteints depuis root par des dépendances normales : ni build.rs, ni tests."""
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    start = next(i for i in meta["workspace_members"] if packages[i]["name"] == root)
    seen, todo = {start}, [start]
    while todo:
        for dep in nodes[todo.pop()]["deps"]:
            if dep["pkg"] not in seen and any(k["kind"] is None for k in dep["dep_kinds"]):
                seen.add(dep["pkg"])
                todo.append(dep["pkg"])
    # source nulle : crate du dépôt amont lui-même, couvert par sa LICENSE
    return sorted((packages[i] for i in seen if packages[i]["source"]), key=lambda p: (p["name"], p["version"]))


def texts(package):
    """[(fichier, texte)] des licences livrées dans le crate."""
    folder = Path(package["manifest_path"]).parent
    files = {f for f in folder.iterdir() if f.is_file() and LICENSE_FILE.match(f.name)}
    if package.get("license_file"):
        files.add(folder / package["license_file"])
    return [(f.name, f.read_text(encoding="utf-8", errors="replace").strip()) for f in sorted(files) if f.is_file()]


def render(packages):
    out = ["Composants tiers du CLI agent-burn (bin/agent-burn) : crates Rust compilés dans le binaire.",
           "Le CLI lui-même (MIT, ryoppippi et Melvynx) : voir LICENSE-agent-burn.txt.", ""]
    shared = {}   # texte → crates qui le livrent : un texte identique n'est copié qu'une fois
    for p in packages:
        found = texts(p)
        license = p.get("license") or (f"voir {p['license_file']}" if p.get("license_file") else "non déclarée")
        repo = p.get("repository") or p.get("homepage") or f"https://crates.io/crates/{p['name']}"
        out += [f"{p['name']} {p['version']}", f"  Licence : {license}", f"  Dépôt : {repo}"]
        if not found:
            out.append("  Texte de licence : absent du crate, voir le dépôt")
        out.append("")
        for name, text in found:
            shared.setdefault(text, []).append(f"{p['name']} {p['version']} ({name})")
    out += [RULE, "Textes de licence", RULE]
    for text, users in shared.items():
        out += ["", RULE, "Livré par : " + ", ".join(users), "-" * 80, text]
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Notices tierces du CLI agent-burn (crates Rust)")
    parser.add_argument("source", type=Path, help="checkout de github.com/Melvynx/agent-burn (rust/Cargo.lock)")
    parser.add_argument("output", type=Path, help="THIRD-PARTY-NOTICES.txt à écrire")
    parser.add_argument("--target", help="triple compilé : écarte les crates des autres plateformes")
    args = parser.parse_args()
    workspace = args.source / "rust" if (args.source / "rust" / "Cargo.lock").is_file() else args.source
    cmd = ["cargo", "metadata", "--format-version", "1", "--locked"]
    if args.target:
        cmd += ["--filter-platform", args.target]
    # utf-8 explicite : sous Windows, text=True décoderait en cp1252 (auteurs, descriptions accentués)
    meta = json.loads(subprocess.run(cmd, cwd=workspace, check=True, stdout=subprocess.PIPE, encoding="utf-8").stdout)
    args.output.write_text(render(crates(meta)), encoding="utf-8")


if __name__ == "__main__":
    main()
