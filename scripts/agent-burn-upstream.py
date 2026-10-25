#!/usr/bin/env python3
"""Tracks the upstream repository github.com/Melvynx/agent-burn (Mac app + CLI) from the revision pinned
in cli.env (AB_REV): what is left to port into this repo, and the CLI bump.

  agent-burn-upstream [status] [--fetch] [--json]  upstream AB_REV..main commits, grouped, and files to review
  agent-burn-upstream diff QuotaChart.swift        upstream diff of a file (name or path) since AB_REV
  agent-burn-upstream update [REV|latest]          builds the CLI at REV, checks its JSON and pins it (cli.env)

--fetch (with any command) updates the upstream copy first. Old forms, still valid:
--diff FILE, --bump [REV].
"""
import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

URL = os.environ.get("AGENT_BURN_UPSTREAM_URL") or "https://github.com/Melvynx/agent-burn"
CACHE = Path(os.environ.get("AGENT_BURN_UPSTREAM_CACHE") or Path.home() / ".cache/agent-burn-upstream")
REPO = CACHE / "repo"
ROOT = Path(__file__).resolve().parents[1]   # <repo>/scripts/this-file
CLI_ENV = Path(os.environ.get("AGENT_BURN_CLI_ENV") or ROOT / "cli.env").resolve()
ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}   # may run in the background: never prompt for credentials

QS, APP = "shared/", "app/"
BURN, POP, DASH = QS + "Burn.qml", QS + "BurnPopover.qml", QS + "BurnDashboardView.qml"
# Mac app (Sources/AgentBurn/<name>.swift) → files of this repo that port it; [] = not ported.
PORT = {
    "QuotaChart": [QS + "BurnQuotaChart.qml"], "CodexLimitUsageChart": [QS + "BurnQuotaChart.qml"],
    "NativeUsageView": [DASH],
    # MenuPopover: OverviewView = General tab, HarnessView = an agent's tab (its titles: pace() in Burn.qml).
    **dict.fromkeys(["OverviewView", "CompactHarnessView", "QuotaFreshnessView"], [POP]),
    "HarnessView": [POP, BURN],
    # MenuPopover + DashboardView; QuotaSummary serves both; RefreshFooter, StatusBadge… are in Theme.
    # AppViews also contains SettingsView (General, Data, Background, Updates, About tabs): SettingsWindow.
    "AppViews": [POP, DASH, APP + "qml/SettingsWindow.qml"],
    "UsageDetails": [POP, DASH],
    "ClaudeAccountView": [POP, DASH, BURN],   # ClaudeAccount and claudeVerdict: Burn.qml
    "Theme": [POP, DASH, APP + "qml/Colors.qml"],
    # "Menu bar only" mode and window logo (__main__.py), appearance setting (Colors.qml).
    "AppAppearance": [APP + "agentburn/__main__.py", APP + "qml/Colors.qml"],
    "LoginItem": [APP + "agentburn/platform_win.py", APP + "agentburn/platform_linux.py"],   # autostart
    "BrandImages": [QS + "assets/burn/"],
    # MenuBarLabel (tray icon) and dashboard window.
    "AgentBurnApp": [APP + "agentburn/tray.py", APP + "qml/DashboardWindow.qml"],
    # QuotaService: the collector's launchd agent; here, Burn.qml's reading while the app runs.
    **dict.fromkeys(["UsageStore", "QuotaFreshness", "QuotaJournal", "QuotaHistory", "QuotaCollector", "QuotaService",
                     "MetricsArchive", "UsageJournal", "Usage", "ClaudeAccountFile", "CLIClient", "ReportCache"], [BURN]),
    "CursorAccountView": [],
    "AppUpdater": [],   # Sparkle: no automatic update, by design (README.md)
}
GROUPS = {"mac": "Mac app", "cli": "CLI", "docs": "Docs", "ci": "CI/infra", "other": "Other"}
# Keys read from the reports by Burn.qml (setSummary, merge, windows, quotaProc) and by the views (popover,
# dashboard), "[]" = each element. Offline check on the fake_home HOME: Claude's windows (live reading) are
# null; a null value or an empty list stops the descent, and the key is reported as not checkable.
# claudeAccount, claudeAccountStatus and the AGENT_BURN_QUOTA_ONLY reading only exist online.
HARNESS = ["economics.apiEquivalentPerMonth", "economics.pricePerMonth", "economics.valueMultiple",
           "economics.subsidyPerMonth", "economics.discountPercent", "spendMix[].key", "spendMix[].label",
           "spendMix[].costPercent", "spendMix[].tokens", "spendMix[].costUSD"]   # dashboard, agent page
KEYS = {
    "summary": ["agents[].agent", "agents[].totalCost", "agents[].daily[].date", "agents[].daily[].cost",
                "agents[].daily[].tokens", "agents[].models[].model", "agents[].models[].totalTokens",
                "agents[].models[].totalCost", "agents[].models[].percentage", "daily[].date", "daily[].cost",
                "daily[].tokens", "models[].model", "models[].totalTokens", "models[].totalCost", "models[].percentage",
                "subscription.agents[].agent", "subscription.agents[].plan", "subscription.agents[].pricePerMonth",
                "subscription.agents[].shortWindow.usedPercent", "subscription.agents[].window.usedPercent",
                "subscription.agents[].window.elapsedMinutes"],
    # window: same structure as the AGENT_BURN_QUOTA_ONLY reading in quotaProc.
    "harness claude": ["window.usedPercent", "window.elapsedPercent", "window.windowMinutes"] + HARNESS,
    "harness codex": HARNESS,
}
# Text from upstream (subjects, file names, git errors, diff), shown by kitty (Report button) or put in the
# JSON: no C0 control left (except \t \n), no DEL or C1, ESC included.
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
# Tags end up in the body of a notification, where markup is interpreted: versions only.
TAG = re.compile(r"(macos-)?v[0-9][0-9A-Za-z.+-]*")
EMPTY = {"pinned": "", "pinnedVersion": "", "head": "", "headDate": "", "ahead": 0, "tags": {"cli": [], "mac": []},
         "categories": {"mac": 0, "cli": 0, "docs": 0, "other": 0}, "toPort": [], "compareUrl": "", "fetchedAt": "",
         "error": ""}


class Fail(Exception):
    pass


def clean(s):
    return CTRL.sub("?", s)


def run(*cmd):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="replace", timeout=300, env=ENV)
    if r.returncode:
        raise Fail(clean((r.stderr.strip() or f"{cmd[0]}: code {r.returncode}").splitlines()[0]))
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
        return "ci"   # root files: flake, justfile, package.json…
    return "other"


def mac_targets(path):
    """Repo files to review for a Mac app file; None = to assess."""
    m = re.fullmatch(r"apps/macos/Sources/AgentBurn/(\w+)\.swift", path)
    if m:
        return PORT.get(m[1])
    if "/Resources/Brands/" in path:
        return [QS + "assets/burn/"]
    if path.endswith("/AppIcon.icns"):
        return ["assets/agent-burn.ico"]
    return None


def cli_zone(path):
    name = path.rsplit("/", 1)[-1]
    if "pricing" in name or name in ("cost.rs", "fast.rs", "fast-multiplier-overrides.json"):
        return "pricing"
    # summary, harness and reading (adapter/all), Claude account (claude/limits.rs): the JSON that Burn.qml reads
    if "/src/adapter/all/" in path or path.endswith(("/adapter/claude/limits.rs", "/agent-burn/src/output.rs",
                                                     "/agent-burn/src/types.rs")):
        return "JSON output"
    m = re.search(r"/src/adapter/(\w+)/", path)
    return "adapter/" + m[1] if m else "other"


def short(path):
    return path.removeprefix("apps/macos/").removeprefix("Sources/AgentBurn/")


def read_pin():
    """cli.env text (source of truth), AB_REV and the version from AB_VER."""
    text = CLI_ENV.read_text()
    rev = re.findall(r"^AB_REV=([0-9a-f]{7,40})$", text, re.M)
    ver = re.findall(r'^AB_VER="agent-burn ([^"]+)"$', text, re.M)
    if len(rev) != 1 or len(ver) != 1:
        raise Fail(f'{CLI_ENV}: needs one AB_REV=<sha> line and one AB_VER="agent-burn <version>" line')
    return text, rev[0], ver[0]


def fetched_at():
    f = REPO / ".git/FETCH_HEAD"
    return datetime.fromtimestamp(f.stat().st_mtime).astimezone().isoformat(timespec="seconds") if f.exists() else ""


def fetch():
    """Updates the cache; returns a warning when the network is unavailable (report from the cache)."""
    try:
        if not (REPO / ".git").is_dir():
            tmp = CACHE / "repo.tmp"   # interrupted clone: never a half-written cache
            shutil.rmtree(tmp, ignore_errors=True)
            CACHE.mkdir(parents=True, exist_ok=True)
            run("git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", URL, str(tmp))
            tmp.rename(REPO)
        git("fetch", "--quiet", "--tags", "--force", "origin")
    except (Fail, subprocess.TimeoutExpired) as e:
        if not (REPO / ".git").is_dir():
            raise Fail(f"upstream unreachable and no local copy yet ({e})") from None
        return f"offline, report from the cache ({e})"
    return ""


def report(warning):
    _, pinned, version = read_pin()
    try:
        git("cat-file", "-e", pinned + "^{commit}")
    except Fail:
        raise Fail(f"AB_REV {pinned[:12]} not found upstream: history rewritten, or the copy needs a refresh"
                   " (--fetch)") from None
    head, head_date = git("log", "-1", "--format=%H %cI", "origin/main").split()
    commits = []
    # --no-renames: rename detection would read blobs missing from the copy (a download, which fails
    # offline); a rename thus lists both the old and the new name.
    for chunk in git("log", "--no-merges", "--no-renames", "--name-only", "--format=%x00%h%x09%cs%x09%s",
                     f"{pinned}..origin/main").split("\0")[1:]:
        header, *files = chunk.strip("\n").split("\n")
        sha, date, subject = header.split("\t", 2)
        files = [clean(f) for f in files if f]   # git already escapes C0 controls in names, not C1
        commits.append({"sha": sha, "date": date, "subject": clean(subject), "files": files,
                        "cats": {category(f) for f in files} or {"other"}})
    tags = {"cli": [], "mac": []}
    for t in git("tag", "--no-merged", pinned, "--sort=version:refname").split():
        if TAG.fullmatch(t):
            tags["mac" if t.startswith("macos-") else "cli"].append(t)
    sources = {}   # repo file to review → what changed upstream
    for f in (f for c in commits for f in c["files"]):
        if category(f) == "mac":
            for t in mac_targets(f) or []:
                sources.setdefault(t, set()).add(short(f))
        elif category(f) == "cli" and cli_zone(f) == "JSON output":
            sources.setdefault(BURN, set()).add("CLI JSON output")
    count = lambda *cats: sum(1 for c in commits if c["cats"] & set(cats))
    gh = URL.removesuffix(".git") if URL.startswith("https://github.com/") else ""
    r = {"pinned": pinned, "pinnedVersion": version, "head": head, "headDate": head_date, "ahead": len(commits),
         "tags": tags, "categories": {"mac": count("mac"), "cli": count("cli"), "docs": count("docs"),
                                      "other": count("ci", "other")},
         "toPort": sorted(sources), "compareUrl": f"{gh}/compare/{pinned}...{head}" if gh else "",
         "fetchedAt": fetched_at(), "error": warning}
    return r, commits, sources


def text(r, commits, sources):
    out = [f"agent-burn upstream: {URL}",
           f"Pinned: {r['pinned'][:12]} (agent-burn {r['pinnedVersion']}) · upstream: {r['head'][:12]} from "
           f"{r['headDate'][:10]}" + (f" · copy from {r['fetchedAt'][:16].replace('T', ' ')}" if r["fetchedAt"] else "")]
    if r["error"]:
        out.append("Warning: " + r["error"])
    n = len(commits)
    out.append(f"\n{n} new commit{'s' if n > 1 else ''} since your version:" if n
               else "\nUp to date: no upstream commit since your version.")
    for cat, label in GROUPS.items():
        group = [c for c in commits if cat in c["cats"]]
        if group:
            out.append(f"\n{label} ({len(group)})")
        for c in group:
            files = [f for f in c["files"] if category(f) == cat]
            zones = sorted({cli_zone(f) for f in files}) if cat == "cli" else []
            zones = [z + " → check Burn.qml" if z == "JSON output" else z for z in zones]
            out.append(f"  {c['sha']}  {c['date']}  {c['subject']}" + (f"  [{', '.join(zones)}]" if zones else ""))
            if cat == "mac":
                for f in files:
                    if "/Sources/" not in f:   # Mac app tests, build and release: nothing to port
                        continue
                    t = mac_targets(f)
                    out.append(f"      {short(f)} → " + ("to assess" if t is None else ", ".join(t) or "not ported"))
    tags = [f"{label} {', '.join(r['tags'][k])}" for k, label in (("cli", "CLI"), ("mac", "Mac app")) if r["tags"][k]]
    if tags:
        out.append("\nNew tags: " + " · ".join(tags))
    if sources:
        w = max(map(len, sources))
        out.append("\nRepo files to review:")
        out += [f"  {f.ljust(w)}  ← {', '.join(sorted(s))}" for f, s in sorted(sources.items())]
    if n:
        if r["compareUrl"]:
            out.append("\nCompare: " + r["compareUrl"])
        out.append("Diff of one file: agent-burn-upstream diff QuotaChart.swift (name or path)")
        out.append("CLI bump (build, JSON check, cli.env): agent-burn-upstream update --fetch")
    return "\n".join(out)


def diff(name):
    _, pinned, _ = read_pin()
    files = set(git("ls-tree", "-r", "--name-only", "origin/main").splitlines())
    files |= set(git("ls-tree", "-r", "--name-only", pinned).splitlines())
    paths = sorted(f for f in files if f == name or f.rsplit("/", 1)[-1] in (name, name + ".swift"))
    if not paths:
        raise Fail(f"“{name}” not found upstream (file name or path from the root)")
    # Captured then cleaned (no colors, no pager): git would pass upstream files' control characters to the terminal.
    sys.stdout.write(clean(git("diff", "--no-color", pinned, "origin/main", "--", *paths)))
    return 0


def lacks(node, path):
    """True: a key of path is missing; None: not checkable (null or empty list everywhere on the path);
    False: present (in at least one element of each list)."""
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
    return True if True in found else False if False in found else None   # Claude window null, Codex: checked


def fake_home(home):
    """Synthetic HOME with a Claude session (Max plan read from ~/.claude.json) and a Codex one (Plus, limits
    in its logs), from a minute ago: windows, economics and spendMix filled in offline, except Claude's
    windows (live reading)."""
    now = time.time()
    iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    tokens = {"input_tokens": 2500, "cached_input_tokens": 500, "output_tokens": 300, "total_tokens": 2800}
    limit = lambda used, minutes: {"used_percent": used, "window_minutes": minutes, "resets_at": int(now) + minutes * 30}
    files = {
        ".claude.json": [{"oauthAccount": {"organizationRateLimitTier": "default_claude_max_5x"}}],
        ".claude/projects/-tmp-demo/s1.jsonl": [{
            "type": "assistant", "timestamp": iso(now - 60), "sessionId": "s1", "requestId": "r1",
            "message": {"id": "m1", "role": "assistant", "model": "claude-sonnet-4-5-20250929", "usage": {
                "input_tokens": 1000, "output_tokens": 500, "cache_creation_input_tokens": 2000,
                "cache_read_input_tokens": 3000}}}],
        time.strftime(".codex/sessions/%Y/%m/%d/rollout-synthetic.jsonl"): [
            {"timestamp": iso(now - 120), "type": "turn_context", "payload": {"model": "gpt-5.3-codex"}},
            {"timestamp": iso(now - 60), "type": "event_msg", "payload": {
                "type": "token_count", "info": {"last_token_usage": tokens, "total_token_usage": tokens},
                "rate_limits": {"plan_type": "plus", "primary": limit(12, 300), "secondary": limit(40, 10080)}}}],
    }
    for name, lines in files.items():
        (home / name).parent.mkdir(parents=True, exist_ok=True)
        # Compact JSON: the Claude parser looks for the bytes "usage":{
        (home / name).write_text("".join(json.dumps(x, separators=(",", ":")) + "\n" for x in lines))


def check(binary, ver):
    """Does this CLI give the expected version and the keys that Burn.qml and the views read?"""
    with tempfile.TemporaryDirectory(prefix="agent-burn-check-") as home:
        fake_home(Path(home))
        # Empty environment except PATH, current directory = HOME: none of the user's data or agent-burn.json
        # (noCost, jq, offline change the JSON), no CLAUDE_CONFIG_DIR, CODEX_HOME or AGENT_BURN_QUOTA_ONLY.
        call = lambda *a: subprocess.run([str(binary), *a], capture_output=True, encoding="utf-8", errors="replace",
                                         timeout=300, cwd=home, env={"HOME": home, "PATH": os.environ.get("PATH", "")})
        got = clean(call("--version").stdout.strip())
        ok = got == ver
        print(f"  --version: {got or '?'}" + ("" if ok else f" ≠ “{ver}” (build.sh and build.ps1 would refuse this CLI)"))
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
            print(f"  {cmd}: " + (f"code {r.returncode}, unreadable JSON" if missing is None
                                  else "missing keys: " + ", ".join(missing) if missing
                                  else f"ok ({len(keys) - len(null)} keys)"
                                  + (", not checkable (null or empty): " + ", ".join(null) if null else "")))
    print("  Not checkable offline: claudeAccount, claudeAccountStatus (present only when the sign-in has expired),"
          " AGENT_BURN_QUOTA_ONLY reading (observedAt, sessionWindow) → check the popover and the dashboard"
          " with this CLI, online.")
    return ok


def bump(rev):
    _, pinned, _ = read_pin()
    ref = "origin/main" if rev in ("latest", "main", "HEAD") else rev   # the local main branch stays the clone's
    try:
        sha = git("rev-parse", "--verify", "--quiet", ref + "^{commit}").strip()
    except Fail:
        raise Fail(f"revision “{rev}” unknown upstream (rerun with --fetch?)") from None
    if sha == pinned:
        print(f"cli.env already pins {sha[:12]}: nothing to do.")
        return 0
    # Version copied into AB_VER="…" of cli.env, which a shell may source: semver only.
    m = re.search(r'^version\s*=\s*"([0-9][0-9A-Za-z.+-]*)"', git("show", f"{sha}:rust/crates/agent-burn/Cargo.toml"),
                  re.M)
    if not m:
        raise Fail(f"version not found in rust/crates/agent-burn/Cargo.toml at {sha[:12]}")
    ver = "agent-burn " + m[1]
    st = subprocess.run(["git", "-C", str(CLI_ENV.parent), "--no-optional-locks", "status", "--porcelain", "--",
                         CLI_ENV.name], capture_output=True, text=True, env=ENV)
    dirty = st.returncode == 0 and st.stdout.strip() != ""
    if st.returncode == 0:   # outside a git repo: nothing to report
        print("cli.env: " + ("uncommitted changes, kept (only the AB_REV and AB_VER lines change,"
                             " copy in cli.env.bak)." if dirty else "no local changes."))
    print(f"Compiling {ver} ({sha[:12]}): cargo, ~2 min…", flush=True)
    # Built in the cache, never installed: only cli.env changes, once this JSON is checked.
    staged = CACHE / "cli/bin/agent-burn"
    if subprocess.run(["cargo", "install", "-q", "--locked", "--force", "--git", URL, "--rev", sha,
                       "agent-burn", "--bin", "agent-burn", "--root", str(CACHE / "cli")]).returncode:
        raise Fail("cargo install failed: cli.env unchanged.")
    print("\nChecking the JSON read by Burn.qml and the views (compiled CLI, offline, synthetic HOME):")
    if not check(staged, ver):
        print(f"\nIncompatible: nothing was changed (cli.env). Adapt the QML first; compiled CLI kept"
              f" for inspection: AGENT_BURN_BIN={staged}")
        return 1
    text, _, _ = read_pin()   # read again: an edit made during the build is kept
    new = re.sub(r"^AB_REV=[0-9a-f]{7,40}$", lambda _: "AB_REV=" + sha, text, count=1, flags=re.M)
    new = re.sub(r'^AB_VER="agent-burn [^"]+"$', lambda _: f'AB_VER="{ver}"', new, count=1, flags=re.M)
    shutil.copy2(CLI_ENV, CLI_ENV.with_name(CLI_ENV.name + ".bak"))
    tmp = CLI_ENV.with_name(CLI_ENV.name + ".tmp")
    tmp.write_text(new)
    shutil.copymode(CLI_ENV, tmp)
    os.replace(tmp, CLI_ENV)   # AB_REV and AB_VER change together, or not at all
    sys.stdout.writelines(difflib.unified_diff(text.splitlines(True), new.splitlines(True),
                                               "cli.env (before, .bak copy)", "cli.env"))
    repo = CLI_ENV.parent
    add = "add -p" if dirty else "add"   # -p: the bump only, without the local changes
    print(f"\nCompatible: cli.env pinned (compiled CLI: {staged}). Next steps:\n"
          f"  recapture tests/fixtures with this CLI (selftest and desktop app tests;\n"
          f"  capture date in fake_cli of __main__.py and in gen.py of the burn-suite)\n"
          f"  git -C {repo} {add} cli.env   (+ the ported files)\n"
          f'  git -C {repo} commit -m "agent-burn: CLI pinned to {sha[:12]} ({ver})"\n'
          f"  git -C {repo} push   → CI rebuilds the CLI and the app")
    return 0


def main():
    p = argparse.ArgumentParser(prog="agent-burn-upstream", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", nargs="?", choices=("status", "diff", "update"), help="status by default")
    p.add_argument("target", nargs="?", metavar="FILE|REV", help="diff: upstream file; update: revision (latest)")
    p.add_argument("--fetch", action="store_true", help="updates the upstream copy first (network)")
    p.add_argument("--json", action="store_true", help="report as JSON (Quickshell module BurnUpstream)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--diff", metavar="FILE", help="= diff FILE")
    g.add_argument("--bump", nargs="?", const="latest", metavar="REV", help="= update [REV]")
    a = p.parse_intermixed_args()   # update --fetch v20.0.22 like update v20.0.22 --fetch
    if a.command and (a.diff or a.bump) or a.target and a.command not in ("diff", "update"):
        p.error("one command only: status, diff FILE or update [REV]")
    if a.command == "diff":
        a.diff = a.target or p.error("diff: missing file name or path")
    elif a.command == "update":
        a.bump = a.target or "latest"
    try:
        warning = fetch() if a.fetch else ""
        if not (REPO / ".git").is_dir():
            raise Fail("no upstream copy yet: run agent-burn-upstream status --fetch")
        if a.diff:
            return diff(a.diff)
        if a.bump:
            if warning:   # offline: "latest" is the copy's main, maybe behind
                print("Warning: " + warning)
            return bump(a.bump)
        r, commits, sources = report(warning)
    except (Fail, OSError, subprocess.SubprocessError) as e:
        if a.json:
            print(json.dumps({**EMPTY, "error": str(e)}))
        else:
            print(f"agent-burn-upstream: {e}", file=sys.stderr)
        return 1
    print(json.dumps(r) if a.json else text(r, commits, sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
