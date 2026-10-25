#!/usr/bin/env python3
"""Suivi du dépôt amont github.com/Melvynx/agent-burn (app Mac + CLI) depuis la révision épinglée
dans install.sh (AB_REV) : ce qu'il reste à porter dans ce repo, et le bump du CLI.

  agent-burn-upstream [status] [--fetch] [--json]  commits AB_REV..main amont, regroupés, et fichiers à revoir
  agent-burn-upstream diff QuotaChart.swift        diff amont d'un fichier (nom ou chemin) depuis AB_REV
  agent-burn-upstream update [REV|latest]          compile le CLI de REV, vérifie son JSON, l'installe et l'épingle

--fetch (avec chaque commande) met d'abord à jour la copie de l'amont. Anciennes formes, toujours valides :
--diff FICHIER, --bump [REV].
"""
import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

URL = os.environ.get("AGENT_BURN_UPSTREAM_URL") or "https://github.com/Melvynx/agent-burn"
CACHE = Path(os.environ.get("AGENT_BURN_UPSTREAM_CACHE") or Path.home() / ".cache/agent-burn-upstream")
REPO = CACHE / "repo"
ROOT = Path(__file__).resolve().parents[3]   # <repo>/config/quickshell/scripts/ce-fichier
INSTALL_SH = Path(os.environ.get("AGENT_BURN_INSTALL_SH") or ROOT / "install.sh").resolve()
ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}   # lancé en fond par qs : jamais de demande d'identifiants

QS, WIN = "config/quickshell/", "desktop/agent-burn/app/"
BURN, POP, DASH = QS + "Burn.qml", QS + "BurnPopover.qml", QS + "BurnDashboardView.qml"
# App Mac (Sources/AgentBurn/<nom>.swift) → fichiers de ce repo qui la portent ; [] = non porté.
PORT = {
    "QuotaChart": [QS + "BurnQuotaChart.qml"], "CodexLimitUsageChart": [QS + "BurnQuotaChart.qml"],
    "NativeUsageView": [DASH],
    # MenuPopover : OverviewView = onglet Général, HarnessView = onglet d'un agent (ses titres : pace() de Burn.qml).
    **dict.fromkeys(["OverviewView", "CompactHarnessView", "QuotaFreshnessView"], [POP]),
    "HarnessView": [POP, BURN],
    # MenuPopover + DashboardView ; QuotaSummary sert aux deux ; RefreshFooter, StatusBadge… sont dans Theme.
    **dict.fromkeys(["AppViews", "UsageDetails"], [POP, DASH]),
    "ClaudeAccountView": [POP, DASH, BURN],   # ClaudeAccount et claudeVerdict : Burn.qml
    "Theme": [POP, DASH, WIN + "qml/Colors.qml"],
    # MenuBarLabel (pill, icône de notification) et fenêtre du dashboard.
    "AgentBurnApp": [QS + "BurnPill.qml", QS + "BurnDashboard.qml", WIN + "agentburn/tray.py",
                     WIN + "qml/DashboardWindow.qml"],
    **dict.fromkeys(["UsageStore", "QuotaFreshness", "QuotaJournal", "QuotaHistory", "QuotaCollector", "MetricsArchive",
                     "UsageJournal", "Usage", "ClaudeAccountFile", "CLIClient", "ReportCache"], [BURN]),
    "CursorAccountView": [],
}
GROUPS = {"mac": "App Mac", "cli": "CLI", "docs": "Docs", "ci": "CI/infra", "other": "Autres"}
# Clés lues dans les rapports par Burn.qml (setSummary, merge, windows, quotaProc) et par les vues (popover,
# dashboard), « [] » = chaque élément. En --offline, claudeAccount(Status) et le relevé AGENT_BURN_QUOTA_ONLY
# (observedAt, sessionWindow) sont absents, les fenêtres et economics valent null : une valeur null arrête la
# descente, la clé est signalée non vérifiable.
KEYS = {
    "summary": ["agents[].agent", "agents[].totalCost", "agents[].daily[].date", "agents[].daily[].cost",
                "agents[].daily[].tokens", "agents[].models[].model", "daily[].date", "daily[].cost", "daily[].tokens",
                "models[].model", "models[].totalTokens", "models[].totalCost", "models[].percentage",
                "subscription.agents[].agent", "subscription.agents[].plan", "subscription.agents[].pricePerMonth",
                "subscription.agents[].shortWindow.usedPercent", "subscription.agents[].window.usedPercent",
                "subscription.agents[].window.elapsedMinutes"],
    "harness claude": ["window.usedPercent", "window.elapsedPercent", "window.windowMinutes", "economics",
                       "spendMix[].key", "spendMix[].label", "spendMix[].costPercent", "spendMix[].tokens",
                       "spendMix[].costUSD"],
}
EMPTY = {"pinned": "", "pinnedVersion": "", "head": "", "headDate": "", "ahead": 0, "tags": {"cli": [], "mac": []},
         "categories": {"mac": 0, "cli": 0, "docs": 0, "other": 0}, "toPort": [], "compareUrl": "", "fetchedAt": "",
         "error": ""}


class Fail(Exception):
    pass


def run(*cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300, env=ENV)
    if r.returncode:
        raise Fail((r.stderr.strip() or f"{cmd[0]} : code {r.returncode}").splitlines()[0])
    return r.stdout


def git(*args):
    return run("git", "-C", str(REPO), "-c", "core.quotePath=off", *args)


def category(path):
    if path.startswith("apps/macos/"):
        return "mac"
    if path.startswith("rust/"):
        return "cli"
    if path.startswith("docs/") or path.endswith(".md"):
        return "docs"
    if path.startswith((".github/", "scripts/", "nix/", "packages/")) or "/" not in path:
        return "ci"   # fichiers racine : flake, justfile, package.json…
    return "other"


def mac_targets(path):
    """Fichiers du repo à revoir pour un fichier de l'app Mac ; None = à évaluer."""
    m = re.fullmatch(r"apps/macos/Sources/AgentBurn/(\w+)\.swift", path)
    if m:
        return PORT.get(m[1])
    if "/Resources/Brands/" in path:
        return [QS + "assets/burn/"]
    if path.endswith("/AppIcon.icns"):
        return ["desktop/agent-burn/assets/agent-burn.ico"]
    return None


def cli_zone(path):
    name = path.rsplit("/", 1)[-1]
    if "pricing" in name or name in ("cost.rs", "fast.rs", "fast-multiplier-overrides.json"):
        return "tarifs"
    # summary, harness et relevé (adapter/all), compte Claude (claude/limits.rs) : le JSON que lit Burn.qml
    if "/src/adapter/all/" in path or path.endswith(("/adapter/claude/limits.rs", "/agent-burn/src/output.rs",
                                                     "/agent-burn/src/types.rs")):
        return "sortie JSON"
    m = re.search(r"/src/adapter/(\w+)/", path)
    return "adapter/" + m[1] if m else "autre"


def short(path):
    return path.removeprefix("apps/macos/").removeprefix("Sources/AgentBurn/")


def read_pin():
    """Texte d'install.sh (source de vérité), AB_REV et version d'AB_VER."""
    text = INSTALL_SH.read_text()
    rev = re.findall(r"^AB_REV=([0-9a-f]{7,40})$", text, re.M)
    ver = re.findall(r'^AB_VER="agent-burn ([^"]+)"$', text, re.M)
    if len(rev) != 1 or len(ver) != 1:
        raise Fail(f'{INSTALL_SH} : il faut une ligne AB_REV=<sha> et une ligne AB_VER="agent-burn <version>"')
    return text, rev[0], ver[0]


def fetched_at():
    f = REPO / ".git/FETCH_HEAD"
    return datetime.fromtimestamp(f.stat().st_mtime).astimezone().isoformat(timespec="seconds") if f.exists() else ""


def fetch():
    """Met le cache à jour ; renvoie un avertissement quand le réseau manque (rapport depuis le cache)."""
    try:
        if not (REPO / ".git").is_dir():
            tmp = CACHE / "repo.tmp"   # clone interrompu : jamais de cache à moitié écrit
            shutil.rmtree(tmp, ignore_errors=True)
            CACHE.mkdir(parents=True, exist_ok=True)
            run("git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", URL, str(tmp))
            tmp.rename(REPO)
        git("fetch", "--quiet", "--tags", "--force", "origin")
    except (Fail, subprocess.TimeoutExpired) as e:
        if not (REPO / ".git").is_dir():
            raise Fail(f"amont injoignable et pas encore de copie locale ({e})") from None
        return f"hors ligne, rapport depuis le cache ({e})"
    return ""


def report(warning):
    _, pinned, version = read_pin()
    try:
        git("cat-file", "-e", pinned + "^{commit}")
    except Fail:
        raise Fail(f"AB_REV {pinned[:12]} absent de l'amont : historique réécrit, ou copie à rafraîchir (--fetch)") from None
    head, head_date = git("log", "-1", "--format=%H %cI", "origin/main").split()
    commits = []
    # --no-renames : la détection de renommage lirait des blobs absents de la copie (téléchargement, échec
    # hors ligne) ; un renommage liste ainsi l'ancien et le nouveau nom.
    for chunk in git("log", "--no-merges", "--no-renames", "--name-only", "--format=%x00%h%x09%cs%x09%s",
                     f"{pinned}..origin/main").split("\0")[1:]:
        header, *files = chunk.strip("\n").split("\n")
        sha, date, subject = header.split("\t", 2)
        files = [f for f in files if f]
        commits.append({"sha": sha, "date": date, "subject": subject, "files": files,
                        "cats": {category(f) for f in files} or {"other"}})
    tags = {"cli": [], "mac": []}
    for t in git("tag", "--no-merged", pinned, "--sort=version:refname").split():
        if t.startswith(("macos-v", "v")):
            tags["mac" if t.startswith("macos-v") else "cli"].append(t)
    sources = {}   # fichier du repo à revoir → ce qui a changé en amont
    for f in (f for c in commits for f in c["files"]):
        if category(f) == "mac":
            for t in mac_targets(f) or []:
                sources.setdefault(t, set()).add(short(f))
        elif category(f) == "cli" and cli_zone(f) == "sortie JSON":
            sources.setdefault(BURN, set()).add("sortie JSON du CLI")
    count = lambda *cats: sum(1 for c in commits if c["cats"] & set(cats))
    gh = URL.removesuffix(".git") if URL.startswith("https://github.com/") else ""
    r = {"pinned": pinned, "pinnedVersion": version, "head": head, "headDate": head_date, "ahead": len(commits),
         "tags": tags, "categories": {"mac": count("mac"), "cli": count("cli"), "docs": count("docs"),
                                      "other": count("ci", "other")},
         "toPort": sorted(sources), "compareUrl": f"{gh}/compare/{pinned}...{head}" if gh else "",
         "fetchedAt": fetched_at(), "error": warning}
    return r, commits, sources


def text(r, commits, sources):
    out = [f"agent-burn amont : {URL}",
           f"Épinglé : {r['pinned'][:12]} (agent-burn {r['pinnedVersion']}) · amont : {r['head'][:12]} du "
           f"{r['headDate'][:10]}" + (f" · copie du {r['fetchedAt'][:16].replace('T', ' ')}" if r["fetchedAt"] else "")]
    if r["error"]:
        out.append("Attention : " + r["error"])
    n = len(commits)
    out.append(f"\n{n} nouveau{'x' if n > 1 else ''} commit{'s' if n > 1 else ''} depuis ta version :" if n
               else "\nÀ jour : aucun commit amont depuis ta version.")
    for cat, label in GROUPS.items():
        group = [c for c in commits if cat in c["cats"]]
        if group:
            out.append(f"\n{label} ({len(group)})")
        for c in group:
            files = [f for f in c["files"] if category(f) == cat]
            zones = sorted({cli_zone(f) for f in files}) if cat == "cli" else []
            zones = [z + " → vérifier Burn.qml" if z == "sortie JSON" else z for z in zones]
            out.append(f"  {c['sha']}  {c['date']}  {c['subject']}" + (f"  [{', '.join(zones)}]" if zones else ""))
            if cat == "mac":
                for f in files:
                    if "/Sources/" not in f:   # tests, build et release de l'app Mac : rien à porter
                        continue
                    t = mac_targets(f)
                    out.append(f"      {short(f)} → " + ("à évaluer" if t is None else ", ".join(t) or "non porté"))
    tags = [f"{label} {', '.join(r['tags'][k])}" for k, label in (("cli", "CLI"), ("mac", "App Mac")) if r["tags"][k]]
    if tags:
        out.append("\nNouveaux tags : " + " · ".join(tags))
    if sources:
        w = max(map(len, sources))
        out.append("\nFichiers du repo à revoir :")
        out += [f"  {f.ljust(w)}  ← {', '.join(sorted(s))}" for f, s in sorted(sources.items())]
    if n:
        if r["compareUrl"]:
            out.append("\nComparer : " + r["compareUrl"])
        out.append("Diff d'un fichier : agent-burn-upstream diff QuotaChart.swift (nom ou chemin)")
        out.append("Bump du CLI (install.sh, compilation, contrôle du JSON) : agent-burn-upstream update --fetch")
    return "\n".join(out)


def diff(name):
    _, pinned, _ = read_pin()
    files = set(git("ls-tree", "-r", "--name-only", "origin/main").splitlines())
    files |= set(git("ls-tree", "-r", "--name-only", pinned).splitlines())
    paths = sorted(f for f in files if f == name or f.rsplit("/", 1)[-1] in (name, name + ".swift"))
    if not paths:
        raise Fail(f"« {name} » introuvable dans l'amont (nom de fichier ou chemin depuis la racine)")
    return subprocess.run(["git", "-C", str(REPO), "diff", pinned, "origin/main", "--", *paths], env=ENV).returncode


def lacks(node, path):
    """True : une clé de path manque ; None : une valeur null arrête la descente (non vérifiable) ;
    False : présente (liste vide : rien à vérifier plus bas)."""
    if not path:
        return False
    if node is None:
        return None
    key = path[0].removesuffix("[]")
    if not isinstance(node, dict) or key not in node:
        return True
    if not path[0].endswith("[]") or node[key] is None:
        return lacks(node[key], path[1:])
    if not isinstance(node[key], list):
        return True
    found = [lacks(e, path[1:]) for e in node[key]]
    return True if True in found else None if None in found else False


def check(binary, ver):
    """Ce CLI donne-t-il la version attendue et les clés que lisent Burn.qml et les vues ?"""
    call = lambda *a: subprocess.run([str(binary), *a], capture_output=True, text=True, timeout=300)
    got = call("--version").stdout.strip()
    ok = got == ver
    print(f"  --version : {got or '?'}" + ("" if ok else f" ≠ « {ver} » (install.sh recompilerait à chaque lancement)"))
    for cmd, keys in KEYS.items():
        r = call(*cmd.split(), "--value", "--json", "--no-color", "--offline")
        try:
            data = json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError:
            data = None
        found = {k: lacks(data, k.split(".")) for k in keys} if isinstance(data, dict) else None
        missing = None if found is None else [k for k, v in found.items() if v]
        null = [] if found is None else [k for k, v in found.items() if v is None]
        ok = ok and missing == []
        print(f"  {cmd} : " + (f"code {r.returncode}, JSON illisible" if missing is None
                               else "clés manquantes : " + ", ".join(missing) if missing
                               else f"ok ({len(keys) - len(null)} clés)"
                               + (", non vérifiable (null) : " + ", ".join(null) if null else "")))
    print("  Non vérifiable hors ligne : claudeAccount(Status), relevé AGENT_BURN_QUOTA_ONLY"
          " → regarde la pill après le redémarrage de qs.")
    return ok


def bump(rev):
    text, pinned, _ = read_pin()
    ref = "origin/main" if rev in ("latest", "main", "HEAD") else rev   # la branche main locale reste celle du clone
    try:
        sha = git("rev-parse", "--verify", "--quiet", ref + "^{commit}").strip()
    except Fail:
        raise Fail(f"révision « {rev} » inconnue de l'amont (relance avec --fetch ?)") from None
    if sha == pinned:
        print(f"install.sh épingle déjà {sha[:12]} : rien à faire.")
        return 0
    m = re.search(r'^version\s*=\s*"([^"]+)"', git("show", f"{sha}:rust/crates/agent-burn/Cargo.toml"), re.M)
    if not m:
        raise Fail(f"version introuvable dans rust/crates/agent-burn/Cargo.toml de {sha[:12]}")
    ver = "agent-burn " + m[1]
    print(f"Compilation de {ver} ({sha[:12]}) : cargo, ~2 min…", flush=True)
    # Même commande qu'install.sh, mais à part : la barre garde son CLI tant que ce JSON n'est pas vérifié.
    staged = CACHE / "cli/bin/agent-burn"
    if subprocess.run(["cargo", "install", "-q", "--locked", "--force", "--git", URL, "--rev", sha,
                       "agent-burn", "--bin", "agent-burn", "--root", str(CACHE / "cli")]).returncode:
        raise Fail("cargo install a échoué : install.sh et le CLI installé sont inchangés.")
    print("\nContrôle du JSON lu par Burn.qml et les vues (CLI compilé, hors ligne) :")
    if not check(staged, ver):
        print(f"\nIncompatible : rien n'a été changé (install.sh, CLI installé). Adapte d'abord le QML ; CLI compilé"
              f" gardé pour l'examiner : AGENT_BURN_BIN={staged}")
        return 1
    # Renommage atomique : pas de « Text file busy » si la barre lance le CLI à cet instant.
    dst = Path.home() / ".local/bin/agent-burn"
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(staged, dst.with_name("agent-burn.tmp"))
    os.replace(dst.with_name("agent-burn.tmp"), dst)
    new = re.sub(r"^AB_REV=[0-9a-f]{7,40}$", lambda _: "AB_REV=" + sha, text, count=1, flags=re.M)
    new = re.sub(r'^AB_VER="agent-burn [^"]+"$', lambda _: f'AB_VER="{ver}"', new, count=1, flags=re.M)
    shutil.copy2(INSTALL_SH, INSTALL_SH.with_name(INSTALL_SH.name + ".bak"))
    tmp = INSTALL_SH.with_name(INSTALL_SH.name + ".tmp")
    tmp.write_text(new)
    shutil.copymode(INSTALL_SH, tmp)
    os.replace(tmp, INSTALL_SH)   # AB_REV et AB_VER changent ensemble, ou pas du tout
    sys.stdout.writelines(difflib.unified_diff(text.splitlines(True), new.splitlines(True),
                                               "install.sh (avant, copie .bak)", "install.sh"))
    repo = INSTALL_SH.parent
    print(f"\nCompatible : CLI installé ({dst}), install.sh épinglé. Étapes suivantes :\n"
          f"  recapture desktop/agent-burn/tests/fixtures avec ce CLI (selftest et tests de l'app Windows ;\n"
          f"  date de capture dans fake_cli de __main__.py et dans gen.py de la suite burn-suite)\n"
          f"  git -C {repo} add install.sh   (+ les fichiers portés)\n"
          f'  git -C {repo} commit -m "agent-burn : CLI épinglé sur {sha[:12]} ({ver})"\n'
          f"  git -C {repo} push   → la CI Windows recompile le CLI et l'app")
    return 0


def main():
    p = argparse.ArgumentParser(prog="agent-burn-upstream", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", nargs="?", choices=("status", "diff", "update"), help="status par défaut")
    p.add_argument("target", nargs="?", metavar="FICHIER|REV", help="diff : fichier amont ; update : révision (latest)")
    p.add_argument("--fetch", action="store_true", help="met d'abord à jour la copie de l'amont (réseau)")
    p.add_argument("--json", action="store_true", help="rapport en JSON (module Quickshell BurnUpstream)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--diff", metavar="FICHIER", help="= diff FICHIER")
    g.add_argument("--bump", nargs="?", const="latest", metavar="REV", help="= update [REV]")
    a = p.parse_intermixed_args()   # update --fetch v20.0.22 comme update v20.0.22 --fetch
    if a.command and (a.diff or a.bump) or a.target and a.command not in ("diff", "update"):
        p.error("une seule commande : status, diff FICHIER ou update [REV]")
    if a.command == "diff":
        a.diff = a.target or p.error("diff : nom ou chemin du fichier manquant")
    elif a.command == "update":
        a.bump = a.target or "latest"
    try:
        warning = fetch() if a.fetch else ""
        if not (REPO / ".git").is_dir():
            raise Fail("pas encore de copie de l'amont : lance agent-burn-upstream status --fetch")
        if a.diff:
            return diff(a.diff)
        if a.bump:
            if warning:   # hors ligne : « latest » est le main de la copie, peut-être en retard
                print("Attention : " + warning)
            return bump(a.bump)
        r, commits, sources = report(warning)
    except (Fail, OSError, subprocess.SubprocessError) as e:
        if a.json:
            print(json.dumps({**EMPTY, "error": str(e)}))
        else:
            print(f"agent-burn-upstream : {e}", file=sys.stderr)
        return 1
    print(json.dumps(r) if a.json else text(r, commits, sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
