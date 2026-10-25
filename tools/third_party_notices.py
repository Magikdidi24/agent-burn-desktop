#!/usr/bin/env python3
# THIRD-PARTY-NOTICES.txt of the bundled agent-burn CLI: each crate compiled into the binary ("normal"
# dependencies from the agent-burn package, resolved by cargo metadata from Cargo.lock), its license, its
# repository, then the license texts shipped in the crates (MIT, BSD, ISC… require a copy). Run by
# linux/build.sh and build.ps1 after the CLI build (crate sources already in the cargo registry).
#   python third_party_notices.py SOURCE OUTPUT [--target TRIPLE]
import argparse
import json
import re
import subprocess
from pathlib import Path

LICENSE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|copyright|notice)")
RULE = "=" * 80


def crates(meta, root="agent-burn"):
    """Third-party packages reached from root through normal dependencies: no build.rs, no tests."""
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    start = next(i for i in meta["workspace_members"] if packages[i]["name"] == root)
    seen, todo = {start}, [start]
    while todo:
        for dep in nodes[todo.pop()]["deps"]:
            if dep["pkg"] not in seen and any(k["kind"] is None for k in dep["dep_kinds"]):
                seen.add(dep["pkg"])
                todo.append(dep["pkg"])
    # null source: a crate of the upstream repo itself, covered by its LICENSE
    return sorted((packages[i] for i in seen if packages[i]["source"]), key=lambda p: (p["name"], p["version"]))


def texts(package):
    """[(file, text)] of the licenses shipped in the crate."""
    folder = Path(package["manifest_path"]).parent
    files = {f for f in folder.iterdir() if f.is_file() and LICENSE_FILE.match(f.name)}
    if package.get("license_file"):
        files.add(folder / package["license_file"])
    return [(f.name, f.read_text(encoding="utf-8", errors="replace").strip()) for f in sorted(files) if f.is_file()]


def render(packages):
    out = ["Third-party components of the agent-burn CLI (bin/agent-burn): Rust crates compiled into the binary.",
           "The CLI itself (MIT, ryoppippi and Melvynx): see LICENSE-agent-burn.txt.", ""]
    shared = {}   # text → crates that ship it: an identical text is copied only once
    for p in packages:
        found = texts(p)
        license = p.get("license") or (f"see {p['license_file']}" if p.get("license_file") else "not declared")
        repo = p.get("repository") or p.get("homepage") or f"https://crates.io/crates/{p['name']}"
        out += [f"{p['name']} {p['version']}", f"  License: {license}", f"  Repository: {repo}"]
        if not found:
            out.append("  License text: not in the crate, see the repository")
        out.append("")
        for name, text in found:
            shared.setdefault(text, []).append(f"{p['name']} {p['version']} ({name})")
    out += [RULE, "License texts", RULE]
    for text, users in shared.items():
        out += ["", RULE, "Shipped by: " + ", ".join(users), "-" * 80, text]
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Third-party notices of the agent-burn CLI (Rust crates)")
    parser.add_argument("source", type=Path, help="checkout of github.com/Melvynx/agent-burn (rust/Cargo.lock)")
    parser.add_argument("output", type=Path, help="THIRD-PARTY-NOTICES.txt to write")
    parser.add_argument("--target", help="compiled triple: drops the crates of other platforms")
    args = parser.parse_args()
    workspace = args.source / "rust" if (args.source / "rust" / "Cargo.lock").is_file() else args.source
    cmd = ["cargo", "metadata", "--format-version", "1", "--locked"]
    if args.target:
        cmd += ["--filter-platform", args.target]
    # explicit utf-8: on Windows, text=True would decode as cp1252 (accented authors, descriptions)
    meta = json.loads(subprocess.run(cmd, cwd=workspace, check=True, stdout=subprocess.PIPE, encoding="utf-8").stdout)
    args.output.write_text(render(crates(meta)), encoding="utf-8")


if __name__ == "__main__":
    main()
