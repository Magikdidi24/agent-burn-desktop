"""Tests d'agent-burn-upstream.py contre un faux dépôt amont local (git file://) et un faux cargo : stdlib et
git seulement, rien d'écrit hors du dossier temporaire (HOME, cache et install.sh y sont redirigés). Seule
exception, si ~/.local/bin/agent-burn existe : le vrai CLI lit le HOME synthétique du contrôle, hors ligne.

  python3 -I config/quickshell/scripts/test_agent_burn_upstream.py
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True   # importer le script ne doit pas laisser de __pycache__ dans le dépôt
HERE = Path(__file__).resolve().parent
QS = HERE.parent
SCRIPT = HERE / "agent-burn-upstream.py"
FIX = HERE.parents[2] / "desktop/agent-burn/tests/fixtures"   # sorties réelles du CLI


def load():
    spec = importlib.util.spec_from_file_location("abu", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


INSTALL_SH = """#!/usr/bin/env bash
# en-tête
AB_REV={rev}
AB_VER="agent-burn 20.0.21"
echo fin
"""

FAKE_CARGO = """#!/usr/bin/env python3
import os, sys
open(os.environ["FAKE_LOG"], "w").write("\\n".join(sys.argv[1:]))
if os.environ.get("FAKE_CARGO_FAIL"):
    sys.exit(101)
if os.environ.get("FAKE_CARGO_EDIT"):   # install.sh modifié pendant la compilation
    open(os.environ["FAKE_CARGO_EDIT"], "a").write("echo ajout\\n")
root = sys.argv[sys.argv.index("--root") + 1]
os.makedirs(root + "/bin", exist_ok=True)
# Le contrôle lance le CLI avec un environnement vide : ses réglages de test sont écrits dans le binaire.
env = {k: v for k, v in os.environ.items() if k.startswith("FAKE_AB")}
open(root + "/bin/agent-burn", "w").write(open(os.environ["FAKE_AB"]).read().replace("ENV = {}", f"ENV = {env!r}"))
os.chmod(root + "/bin/agent-burn", 0o755)
"""

FAKE_AB = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
ENV = {}
if sys.argv[1:] == ["--version"]:
    print(ENV.get("FAKE_AB_VERSION", "agent-burn 20.0.22"))
    sys.exit(0)
with open(ENV["FAKE_AB_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
home = Path(os.environ["HOME"])
with open(ENV["FAKE_AB_LOG"] + ".env", "a") as f:   # ce que voit le CLI
    f.write(json.dumps({"home": str(home), "cwd": os.getcwd(), "env": sorted(os.environ),
                        "files": sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file())}) + "\\n")
name = {"summary": "SUMMARY", "claude": "HARNESS", "codex": "CODEX"}[sys.argv[1 if sys.argv[1] == "summary" else 2]]
sys.stdout.write(open(ENV["FAKE_AB_" + name]).read())
"""
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")   # contrôles qu'un terminal interpréterait


def sh(cwd, *args, env=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


class Port(unittest.TestCase):
    def test_every_target_exists(self):
        # Un fichier renommé ou supprimé : le rapport enverrait revoir un fichier absent.
        root = HERE.parents[2]
        self.assertEqual(sorted({t for ts in load().PORT.values() for t in ts if not (root / t).exists()}), [])


class Upstream(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="agent-burn-upstream-test-"))
        up = cls.up = cls.tmp / "upstream"
        up.mkdir()
        git = lambda *a: sh(up, "git", *a)
        git("init", "-q", "-b", "main")
        for k, v in [("user.email", "t@example.com"), ("user.name", "t"), ("uploadpack.allowFilter", "true"),
                     ("uploadpack.allowAnySHA1InWant", "true"), ("tag.gpgSign", "false"), ("commit.gpgSign", "false")]:
            git("config", k, v)
        day = iter(range(1, 30))

        def commit(msg, files):
            for f, content in files.items():
                p = up / f
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(content)
            git("add", "-A")
            d = f"2026-10-{next(day):02d}T10:00:00+02:00"
            sh(up, "git", "commit", "-q", "-m", msg, env={**os.environ, "GIT_AUTHOR_DATE": d, "GIT_COMMITTER_DATE": d})
            return git("rev-parse", "HEAD")

        cargo = lambda v: f'[package]\nname = "agent-burn"\nversion = "{v}"\nedition = "2024"\n'
        mac = "apps/macos/Sources/AgentBurn/"
        cls.c1 = commit("chore: initial", {
            mac + "QuotaChart.swift": "struct QuotaChart {}\n",
            mac + "Theme.swift": "enum Theme {}\n",
            mac + "CursorAccountView.swift": "struct CursorAccountView {}\n",
            mac + "AgentBurnApp.swift": "struct AgentBurnApp {}\n",
            "rust/crates/agent-burn/Cargo.toml": cargo("20.0.21"),
            "rust/crates/agent-burn/src/adapter/claude/parser.rs": "fn parse() {}\n",
            "rust/crates/agent-burn/src/adapter/all/summary.rs": "fn summary() {}\n",
            "rust/crates/agent-burn/src/pricing.rs": "fn price() {}\n",
            "README.md": "# Agent Burn\n",
            ".github/workflows/ci.yaml": "on: push\n"})
        git("tag", "v20.0.21")
        git("tag", "-a", "macos-v1.0.0", "-m", "macOS 1.0.0")
        cls.c2 = commit("feat(macos): plage du graphe de quota", {
            mac + "QuotaChart.swift": "struct QuotaChart { var range = 7 }\n",
            "apps/macos/Tests/AgentBurnTests/QuotaChartRangeTests.swift": "final class T {}\n"})
        cls.c3 = commit("fix(claude): parser", {"rust/crates/agent-burn/src/adapter/claude/parser.rs": "fn parse() { 1 }\n"})
        cls.c4 = commit("feat(summary): nouvelle clé JSON",
                        {"rust/crates/agent-burn/src/adapter/all/summary.rs": "fn summary() { 2 }\n"})
        cls.c5 = commit("chore(pricing): tarifs", {"rust/crates/agent-burn/src/pricing.rs": "fn price() { 3 }\n"})
        cls.c6 = commit("docs: readme", {"README.md": "# Agent Burn\n\nNouveau.\n"})
        cls.c7 = commit("ci: workflow", {".github/workflows/ci.yaml": "on: [push, pull_request]\n"})
        cls.c8 = commit("feat(macos): thème et Cursor", {
            mac + "Theme.swift": "enum Theme { case dark }\n",
            mac + "CursorAccountView.swift": "struct CursorAccountView { var x = 1 }\n",
            mac + "AgentBurnApp.swift": "struct AgentBurnApp { var y = 2 }\n"})
        cls.c9 = commit("chore: release agent-burn v20.0.22", {"rust/crates/agent-burn/Cargo.toml": cargo("20.0.22")})
        git("tag", "v20.0.22")
        git("tag", "-a", "macos-v1.1.0", "-m", "macOS 1.1.0")
        # Branche fusionnée : le commit compte, la fusion non (--no-merges).
        git("checkout", "-q", "-b", "popover")
        cls.c10 = commit("feat(macos): popover compact", {mac + "CompactHarnessView.swift": "struct CompactHarnessView {}\n"})
        git("checkout", "-q", "main")
        d = "2026-10-20T10:00:00+02:00"
        sh(up, "git", "merge", "-q", "--no-ff", "-m", "Merge branch popover", "popover",
           env={**os.environ, "GIT_AUTHOR_DATE": d, "GIT_COMMITTER_DATE": d})
        cls.head = git("rev-parse", "HEAD")

        cls.fakebin = cls.tmp / "fakebin"
        cls.fakebin.mkdir()
        (cls.fakebin / "cargo").write_text(FAKE_CARGO)
        (cls.tmp / "fake-agent-burn").write_text(FAKE_AB)
        for p in (cls.fakebin / "cargo", cls.tmp / "fake-agent-burn"):
            p.chmod(0o755)
        bad = json.loads((FIX / "summary-live.json").read_text())
        bad["days"] = bad.pop("daily")   # clé de 1er niveau renommée
        for a in bad["agents"]:
            a["cost"] = a.pop("totalCost")   # clé d'un élément de liste renommée
        (cls.tmp / "summary-renamed.json").write_text(json.dumps(bad))
        h = json.loads((FIX / "harness-claude.json").read_text())
        (cls.tmp / "harness-codex.json").write_text(json.dumps({**h, "agent": "codex"}))   # même structure
        h["window"] = None   # comme un vrai --offline : pas de relevé live
        (cls.tmp / "harness-offline.json").write_text(json.dumps(h))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="t-", dir=self.tmp))
        self.home = self.dir / "home"
        self.home.mkdir()
        self.install = self.dir / "install.sh"
        self.pin(self.c1)
        self.url = "file://" + str(self.up)

    def pin(self, rev):
        self.install.write_text(INSTALL_SH.format(rev=rev))
        self.install.chmod(0o755)

    def copy_upstream(self):
        """Copie modifiable du faux amont, servie à la place de l'original."""
        up2 = self.dir / "up2"
        shutil.copytree(self.up, up2)
        self.url = "file://" + str(up2)
        return up2

    def commit(self, repo, msg, files):
        for f, content in files.items():
            (repo / f).parent.mkdir(parents=True, exist_ok=True)
            (repo / f).write_text(content)
        sh(repo, "git", "add", "-A")
        sh(repo, "git", "commit", "-q", "-m", msg)

    def run_script(self, *args, **env):
        e = {**os.environ, "AGENT_BURN_UPSTREAM_URL": self.url, "AGENT_BURN_UPSTREAM_CACHE": str(self.dir / "cache"),
             "AGENT_BURN_INSTALL_SH": str(self.install), "HOME": str(self.home),
             "GIT_CEILING_DIRECTORIES": str(self.tmp),   # install.sh hors dépôt, même si TMPDIR est dans un dépôt
             "PATH": f"{self.fakebin}:{os.environ['PATH']}", "FAKE_LOG": str(self.dir / "cargo.log"),
             "FAKE_AB": str(self.tmp / "fake-agent-burn"), "FAKE_AB_LOG": str(self.dir / "ab.log"),
             "FAKE_AB_SUMMARY": str(FIX / "summary-live.json"), "FAKE_AB_HARNESS": str(FIX / "harness-claude.json"),
             "FAKE_AB_CODEX": str(self.tmp / "harness-codex.json"), **env}
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=e, timeout=120)

    def report(self, *args, **env):
        r = self.run_script("--json", *args, **env)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return json.loads(r.stdout)

    def assert_nothing_installed(self, before):
        self.assertEqual(self.install.read_text(), before)
        self.assertFalse((self.home / ".local/bin/agent-burn").exists())

    # ── rapport ──
    def test_no_cache_without_fetch(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 1)
        self.assertIn("--fetch", r.stderr)
        r = self.run_script("--json")
        self.assertEqual(r.returncode, 1)
        d = json.loads(r.stdout)
        self.assertTrue(d["error"])
        self.assertEqual((d["ahead"], d["head"]), (0, ""))

    def test_json_report(self):
        d = self.report("--fetch")
        self.assertEqual(set(d), {"pinned", "pinnedVersion", "head", "headDate", "ahead", "tags", "categories", "toPort",
                                  "compareUrl", "fetchedAt", "error"})
        self.assertEqual(d["pinned"], self.c1)
        self.assertEqual(d["pinnedVersion"], "20.0.21")
        self.assertEqual(d["head"], self.head)
        self.assertTrue(d["headDate"].startswith("2026-10-20T10:00:00"))
        self.assertEqual(d["ahead"], 9)
        self.assertEqual(d["tags"], {"cli": ["v20.0.22"], "mac": ["macos-v1.1.0"]})
        self.assertEqual(d["categories"], {"mac": 3, "cli": 4, "docs": 1, "other": 1})
        self.assertEqual(d["toPort"], ["config/quickshell/Burn.qml", "config/quickshell/BurnDashboard.qml",
                                       "config/quickshell/BurnDashboardView.qml", "config/quickshell/BurnPill.qml",
                                       "config/quickshell/BurnPopover.qml", "config/quickshell/BurnQuotaChart.qml",
                                       "desktop/agent-burn/app/agentburn/tray.py", "desktop/agent-burn/app/qml/Colors.qml",
                                       "desktop/agent-burn/app/qml/DashboardWindow.qml"])
        self.assertEqual(d["compareUrl"], "")   # pas GitHub
        self.assertTrue(d["fetchedAt"])
        self.assertEqual(d["error"], "")

    def test_compare_url_on_github(self):
        self.run_script("--fetch")
        d = self.report(AGENT_BURN_UPSTREAM_URL="https://github.com/Melvynx/agent-burn")
        self.assertEqual(d["compareUrl"], f"https://github.com/Melvynx/agent-burn/compare/{self.c1}...{self.head}")

    def test_text_report(self):
        r = self.run_script("--fetch")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        for s in ["9 nouveaux commits", "App Mac (3)", "CLI (4)", "Docs (1)", "CI/infra (1)",
                  self.c2[:7], "feat(macos): plage du graphe de quota",
                  "QuotaChart.swift → config/quickshell/BurnQuotaChart.qml",
                  "Theme.swift → config/quickshell/BurnPopover.qml, config/quickshell/BurnDashboardView.qml, "
                  "desktop/agent-burn/app/qml/Colors.qml",
                  "CursorAccountView.swift → non porté",
                  "AgentBurnApp.swift → config/quickshell/BurnPill.qml, config/quickshell/BurnDashboard.qml, "
                  "desktop/agent-burn/app/agentburn/tray.py, desktop/agent-burn/app/qml/DashboardWindow.qml",
                  "CompactHarnessView.swift → config/quickshell/BurnPopover.qml",
                  "[adapter/claude]", "[sortie JSON → vérifier Burn.qml]", "[tarifs]",
                  "v20.0.22", "macos-v1.1.0", "Fichiers du repo à revoir", "config/quickshell/Burn.qml",
                  "agent-burn-upstream diff QuotaChart.swift", "agent-burn-upstream update --fetch"]:
            self.assertIn(s, out)
        self.assertNotIn("Merge branch popover", out)
        self.assertNotIn("QuotaChartRangeTests", out)   # tests de l'app Mac : rien à porter, pas listés

    def test_up_to_date(self):
        self.pin(self.head)
        d = self.report("--fetch")
        self.assertEqual((d["ahead"], d["toPort"], d["tags"]), (0, [], {"cli": [], "mac": []}))
        self.assertEqual(d["categories"], {"mac": 0, "cli": 0, "docs": 0, "other": 0})
        self.assertIn("À jour", self.run_script().stdout)

    def test_offline_uses_cache(self):
        up2 = self.copy_upstream()
        self.report("--fetch")
        up2.rename(self.dir / "up2.off")   # réseau coupé
        d = self.report("--fetch")
        self.assertEqual(d["ahead"], 9)
        self.assertEqual(d["head"], self.head)   # BurnUpstream : head non vide = pas un échec du suivi
        self.assertIn("hors ligne", d["error"].lower())
        r = self.run_script("--fetch")
        self.assertEqual(r.returncode, 0)
        self.assertIn("hors ligne", r.stdout.lower())

    def test_fetch_sees_new_commit_and_tag(self):
        up2 = self.copy_upstream()
        self.report("--fetch")
        self.commit(up2, "fix(codex): limites", {"rust/crates/agent-burn/src/adapter/codex/limits.rs": "fn l() {}\n"})
        sh(up2, "git", "tag", "v20.0.23")
        d = self.report("--fetch")
        self.assertEqual(d["ahead"], 10)
        self.assertEqual(d["head"], sh(up2, "git", "rev-parse", "HEAD"))
        self.assertEqual(d["tags"]["cli"], ["v20.0.22", "v20.0.23"])

    def test_report_fetches_no_blob(self):
        # Copie sans blobs : la détection de renommage les téléchargerait (échec hors ligne).
        # GIT_NO_LAZY_FETCH=1 fait échouer tout téléchargement implicite.
        up2 = self.copy_upstream()
        mac = "apps/macos/Sources/AgentBurn/"
        body = "".join(f"  var v{i} = {i}\n" for i in range(30)) + "}\n"
        self.commit(up2, "feat(macos): harness", {mac + "HarnessView.swift": "struct HarnessView {\n" + body})
        sh(up2, "git", "mv", mac + "HarnessView.swift", mac + "HarnessPanel.swift")
        self.commit(up2, "refactor(macos): HarnessPanel", {mac + "HarnessPanel.swift": "struct HarnessPanel {\n" + body})
        self.pin(self.head)
        r = self.run_script("--fetch", GIT_NO_LAZY_FETCH="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        cache = self.dir / "cache/repo"   # sinon ce test ne prouve rien : copie partielle, sans checkout
        self.assertEqual(sh(cache, "git", "config", "remote.origin.partialclonefilter"), "blob:none")
        self.assertEqual([p.name for p in cache.iterdir()], [".git"])
        self.assertIn("2 nouveaux commits", r.stdout)
        self.assertIn("HarnessView.swift → config/quickshell/BurnPopover.qml, config/quickshell/Burn.qml",
                      r.stdout)   # nom d'avant
        self.assertIn("HarnessPanel.swift → à évaluer", r.stdout)

    def test_mac_only_files_are_mapped(self):
        up2 = self.copy_upstream()
        names = ("AppAppearance", "AppUpdater", "AppViews", "BrandImages", "LoginItem", "QuotaService")
        self.commit(up2, "feat(macos): réglages", {f"apps/macos/Sources/AgentBurn/{n}.swift": f"// {n}\n" for n in names})
        self.pin(self.head)
        self.assertEqual(self.report("--fetch")["toPort"], [
            "config/quickshell/Burn.qml", "config/quickshell/BurnDashboardView.qml", "config/quickshell/BurnPopover.qml",
            "config/quickshell/Colors.qml", "config/quickshell/assets/burn/", "desktop/agent-burn/app/agentburn/__main__.py",
            "desktop/agent-burn/app/agentburn/platform_linux.py", "desktop/agent-burn/app/agentburn/platform_win.py",
            "desktop/agent-burn/app/qml/Colors.qml", "desktop/agent-burn/app/qml/SettingsWindow.qml"])
        out = self.run_script().stdout
        self.assertNotIn("à évaluer", out)
        self.assertIn("AppUpdater.swift → non porté", out)

    def test_cli_args_crate_is_not_json_output(self):
        # agent-burn-cli/src/types.rs = arguments du CLI, pas les structures du JSON lu par Burn.qml.
        up2 = self.copy_upstream()
        self.commit(up2, "feat(cli): option", {"rust/crates/agent-burn-cli/src/types.rs": "pub struct Args;\n"})
        self.pin(self.head)
        self.assertEqual(self.report("--fetch")["toPort"], [])
        self.assertIn("feat(cli): option  [autre]", self.run_script().stdout)

    def test_unknown_pin(self):
        self.pin("deadbeef" * 5)
        r = self.run_script("--fetch", "--json")
        self.assertEqual(r.returncode, 1)
        d = json.loads(r.stdout)
        self.assertIn("AB_REV", d["error"])
        self.assertEqual(d["head"], "")   # échec dur : BurnUpstream l'affiche dans le bandeau

    def test_install_sh_without_pin(self):
        self.install.write_text("#!/bin/sh\necho rien\n")
        r = self.run_script("--fetch")
        self.assertEqual(r.returncode, 1)
        self.assertIn("AB_REV", r.stderr)

    # ── diff ──
    def test_diff_by_swift_name(self):
        self.run_script("--fetch")
        for name in ("QuotaChart.swift", "QuotaChart"):
            r = self.run_script("--diff", name)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("+struct QuotaChart { var range = 7 }", r.stdout)
            self.assertNotIn("Theme", r.stdout)

    def test_diff_by_path(self):
        r = self.run_script("--fetch", "--diff", "rust/crates/agent-burn/src/adapter/all/summary.rs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("+fn summary() { 2 }", r.stdout)

    def test_diff_unknown(self):
        r = self.run_script("--fetch", "--diff", "Nope.swift")
        self.assertEqual(r.returncode, 1)
        self.assertIn("introuvable", r.stderr)

    # ── bump ──
    def test_bump_latest(self):
        before = self.install.read_text()
        r = self.run_script("--fetch", "--bump")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        after = self.install.read_text()
        self.assertEqual(after, before.replace(self.c1, self.head).replace("20.0.21", "20.0.22"))
        self.assertEqual((self.dir / "install.sh.bak").read_text(), before)
        self.assertEqual(self.install.stat().st_mode & 0o777, 0o755)
        # Compilé à part, puis copié à la place du CLI de la barre une fois son JSON vérifié.
        self.assertEqual((self.dir / "cargo.log").read_text().split("\n"),
                         ["install", "-q", "--locked", "--force", "--git", self.url, "--rev", self.head, "agent-burn",
                          "--bin", "agent-burn", "--root", str(self.dir / "cache/cli")])
        installed = self.home / ".local/bin/agent-burn"
        self.assertEqual(installed.read_bytes(), (self.dir / "cache/cli/bin/agent-burn").read_bytes())
        self.assertTrue(os.access(installed, os.X_OK))
        self.assertFalse((self.home / ".local/bin/agent-burn.tmp").exists())
        calls = (self.dir / "ab.log").read_text().splitlines()
        self.assertEqual(sorted(calls), ["harness claude --value --json --no-color --offline",
                                         "harness codex --value --json --no-color --offline",
                                         "summary --value --json --no-color --offline"])
        for s in ["+AB_REV=" + self.head, '+AB_VER="agent-burn 20.0.22"', "Compatible", "Étapes suivantes",
                  "recapture desktop/agent-burn/tests/fixtures", "push", "Non vérifiable hors ligne : claudeAccount",
                  "claudeAccountStatus", "summary : ok (22 clés)\n", "harness claude : ok (13 clés)\n",
                  "harness codex : ok (10 clés)\n", f"git -C {self.dir} add install.sh"]:
            self.assertIn(s, r.stdout)
        self.assertNotIn("install.sh : ", r.stdout)   # hors d'un dépôt git : rien à signaler

    def test_bump_checks_against_a_synthetic_home(self):
        # Ni les données, ni l'environnement, ni les réglages de l'utilisateur ne changent le contrôle.
        r = self.run_script("--fetch", "--bump", CLAUDE_CONFIG_DIR=str(self.home), AGENT_BURN_QUOTA_ONLY="1")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        seen = [json.loads(line) for line in (self.dir / "ab.log.env").read_text().splitlines()]
        self.assertEqual(len(seen), 3)
        for s in seen:
            self.assertNotEqual(s["home"], str(self.home))
            self.assertEqual(s["cwd"], s["home"])   # pas de .agent-burn/agent-burn.json du dossier courant
            self.assertTrue({"HOME", "PATH"} <= set(s["env"]) <= {"HOME", "PATH", "LC_CTYPE"}, s["env"])
            self.assertIn(".claude/projects/-tmp-demo/s1.jsonl", s["files"])
            self.assertTrue(any(f.startswith(".codex/sessions/") for f in s["files"]), s["files"])
            self.assertFalse(os.path.exists(s["home"]))   # supprimé après le contrôle

    def test_synthetic_home_fills_the_keys_with_the_real_cli(self):
        # Le HOME synthétique doit rester lisible par le vrai CLI (hors ligne, sans réseau ni identifiants).
        cli = Path.home() / ".local/bin/agent-burn"
        if not os.access(cli, os.X_OK):
            self.skipTest(f"pas de CLI agent-burn à {cli}")
        ver = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=30, cwd=self.home,
                             env={"HOME": str(self.home), "PATH": os.environ["PATH"]}).stdout.strip()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertTrue(load().check(cli, ver), out.getvalue())
        self.assertIn("summary : ok (22 clés)\n", out.getvalue())
        self.assertIn("harness claude : ok (10 clés), non vérifiable (null ou vide) : window.usedPercent, "
                      "window.elapsedPercent, window.windowMinutes\n", out.getvalue())   # relevé live seulement
        self.assertIn("harness codex : ok (10 clés)\n", out.getvalue())

    def test_bump_keeps_uncommitted_install_sh_changes(self):
        git = lambda *a: sh(self.dir, "git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                            "-c", "commit.gpgSign=false", *a)
        git("init", "-q")
        git("add", "install.sh")
        git("commit", "-q", "-m", "install")
        r = self.run_script("--fetch", "update", "v20.0.22")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("install.sh : aucune modification locale.", r.stdout)
        self.pin(self.c1)   # = le commit
        self.install.write_text(self.install.read_text().replace("echo fin", "echo local"))   # non commité
        before = self.install.read_text()
        r = self.run_script("update", "v20.0.22")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertLess(r.stdout.index("modifications non commitées, conservées"), r.stdout.index("Compilation"))
        self.assertEqual(self.install.read_text(), before.replace(self.c1, self.c9).replace("20.0.21", "20.0.22"))
        self.assertEqual((self.dir / "install.sh.bak").read_text(), before)
        self.assertIn(f"git -C {self.dir} add -p install.sh", r.stdout)   # le bump seul

    def test_bump_keeps_edits_made_during_the_build(self):
        r = self.run_script("--fetch", "--bump", FAKE_CARGO_EDIT=str(self.install))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        text = self.install.read_text()
        self.assertTrue(text.endswith("echo fin\necho ajout\n"), text)
        self.assertIn(f"AB_REV={self.head}\n", text)

    def test_bump_main_is_upstream_main_not_the_clone_branch(self):
        # Le clone crée une branche main locale que fetch ne déplace jamais : main = origin/main.
        up2 = self.copy_upstream()
        self.report("--fetch")
        self.commit(up2, "fix(claude): après le clone", {"rust/crates/agent-burn/src/adapter/claude/parser.rs": "fn p() {}\n"})
        new = sh(up2, "git", "rev-parse", "HEAD")
        self.report("--fetch")
        for rev in ("main", "HEAD"):
            self.pin(self.c1)
            r = self.run_script("--bump", rev)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            self.assertIn(f"AB_REV={new}\n", self.install.read_text(), rev)

    def test_bump_offline_warns_before_bumping(self):
        up2 = self.copy_upstream()
        self.report("--fetch")
        up2.rename(self.dir / "up2.off")   # réseau coupé : « latest » = main de la copie, peut-être en retard
        r = self.run_script("--fetch", "--bump")
        self.assertTrue(r.stdout.startswith("Attention : hors ligne"), r.stdout + r.stderr)

    def test_bump_rev_and_tag(self):
        self.run_script("--fetch")
        r = self.run_script("--bump", self.c5[:9], FAKE_AB_VERSION="agent-burn 20.0.21")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn(f"AB_REV={self.c5}\n", self.install.read_text())
        self.assertIn('AB_VER="agent-burn 20.0.21"\n', self.install.read_text())
        r = self.run_script("--bump", "v20.0.22")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn(f"AB_REV={self.c9}\n", self.install.read_text())

    def test_bump_same_rev(self):
        self.pin(self.head)
        r = self.run_script("--fetch", "--bump", "latest")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("déjà", r.stdout)
        self.assertFalse((self.dir / "cargo.log").exists())

    def test_bump_cargo_failure_changes_nothing(self):
        before = self.install.read_text()
        r = self.run_script("--fetch", "--bump", FAKE_CARGO_FAIL="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("cargo", r.stderr)
        self.assert_nothing_installed(before)

    def test_bump_incompatible_json_changes_nothing(self):
        before = self.install.read_text()
        r = self.run_script("--fetch", "--bump", FAKE_AB_SUMMARY=str(self.tmp / "summary-renamed.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("summary : clés manquantes : agents[].totalCost, daily[].date, daily[].cost, daily[].tokens\n",
                      r.stdout)
        self.assertIn("harness claude : ok", r.stdout)
        self.assertIn("rien n'a été changé", r.stdout)
        self.assertIn("AGENT_BURN_BIN=" + str(self.dir / "cache/cli/bin/agent-burn"), r.stdout)   # gardé pour examen
        self.assert_nothing_installed(before)

    def test_bump_offline_nulls_are_compatible_but_flagged(self):
        # summary-offline : fenêtres d'abonnement null, pas de claudeAccount ; harness : window null.
        r = self.run_script("--fetch", "--bump", FAKE_AB_SUMMARY=str(FIX / "summary-offline.json"),
                            FAKE_AB_HARNESS=str(self.tmp / "harness-offline.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("Compatible", r.stdout)
        self.assertIn("summary : ok (19 clés), non vérifiable (null ou vide) : subscription.agents[].shortWindow.usedPercent"
                      ", subscription.agents[].window.usedPercent, subscription.agents[].window.elapsedMinutes\n", r.stdout)
        self.assertIn("harness claude : ok (10 clés), non vérifiable (null ou vide) : window.usedPercent, "
                      "window.elapsedPercent, window.windowMinutes\n", r.stdout)

    def test_lacks_states(self):
        lacks = load().lacks
        path = "agents[].window.used".split(".")
        self.assertIs(lacks({"agents": [{"window": None}, {"window": {"used": 1}}]}, path), False)   # Claude null, Codex
        self.assertIs(lacks({"agents": [{"window": None}]}, path), None)
        self.assertIs(lacks({"agents": []}, path), None)   # liste vide : rien de vérifié
        self.assertIs(lacks({"agents": [{"window": {}}, {"window": {"used": 1}}]}, path), True)
        self.assertIs(lacks({"agents": [{"window": {"used": None}}]}, path), False)   # feuille null : clé présente
        self.assertIs(lacks({"agents": {}}, path), True)   # plus une liste

    def test_bump_refuses_a_non_semver_version(self):
        # Recopiée dans AB_VER="…" d'install.sh, que bash évalue : $(…) y serait exécuté.
        up2 = self.copy_upstream()
        self.commit(up2, "chore: release", {"rust/crates/agent-burn/Cargo.toml":
                                            '[package]\nname = "agent-burn"\nversion = "20.0.23$(touch pwned)"\n'})
        before = self.install.read_text()
        r = self.run_script("--fetch", "update")
        self.assertEqual(r.returncode, 1)
        self.assertIn("version introuvable", r.stderr)
        self.assertFalse((self.dir / "cargo.log").exists())
        self.assert_nothing_installed(before)

    def test_bump_version_mismatch_changes_nothing(self):
        before = self.install.read_text()
        r = self.run_script("--fetch", "--bump", FAKE_AB_VERSION="agent-burn 99.0.0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("--version", r.stdout)
        self.assert_nothing_installed(before)

    # ── amont hostile : séquences terminal (bouton Rapport → kitty) et balisage (notification) ──
    def test_control_chars_never_reach_the_terminal(self):
        up2 = self.copy_upstream()
        esc = "\x1b]52;c;ZWNobyBwd25lZA==\x07\x1b[2J\u009b31m"   # presse-papiers (OSC 52), écran effacé, CSI en C1
        self.commit(up2, "feat: titre " + esc + "fin", {"apps/macos/Sources/AgentBurn/Evil\u009b2J.swift": "x\n",
                                                        "rust/crates/agent-burn/src/adapter/all/x.rs": "a" + esc + "b\n"})
        for t in ("v9<b>x</b>", "v99.0.0", "macos-v9.0.0", "vnope", "v1\u009b", "macos", "v1.2.3-rc.1+b5"):
            sh(up2, "git", "tag", t)
        self.pin(self.head)
        d = self.report("--fetch")
        self.assertEqual(d["tags"], {"cli": ["v1.2.3-rc.1+b5", "v99.0.0"], "mac": ["macos-v9.0.0"]})
        self.assertIsNone(CTRL.search(json.dumps(d, ensure_ascii=False)))
        out = self.run_script().stdout
        self.assertIsNone(CTRL.search(out))
        self.assertIn("feat: titre ?]52;c;ZWNobyBwd25lZA==??[2J?31mfin", out)
        self.assertIn("Evil?2J.swift → à évaluer", out)
        r = self.run_script("diff", "x.rs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(CTRL.search(r.stdout))
        self.assertIn("+a?]52;c;ZWNobyBwd25lZA==??[2J?31mb\n", r.stdout)

    def test_git_errors_are_cleaned(self):
        mod = load()
        with self.assertRaises(mod.Fail) as e:
            mod.run("sh", "-c", "printf 'remote: \\033]0;titre\\007 oups\\n' >&2; exit 3")
        self.assertEqual(str(e.exception), "remote: ?]0;titre? oups")

    # ── sous-commandes ──
    def test_subcommands_are_aliases(self):
        self.assertEqual(self.report("--fetch")["head"], self.head)   # forme de BurnUpstream.qml
        self.assertEqual(json.loads(self.run_script("status", "--json").stdout)["ahead"], 9)
        self.assertEqual(self.run_script("status").stdout, self.run_script().stdout)
        self.assertIn("+struct QuotaChart { var range = 7 }", self.run_script("diff", "QuotaChart").stdout)
        r = self.run_script("update", "--fetch", "v20.0.22")   # options avant ou après REV
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn(f"AB_REV={self.c9}\n", self.install.read_text())
        r = self.run_script("update")
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn(f"AB_REV={self.head}\n", self.install.read_text())   # latest
        out = self.run_script("--help").stdout
        for s in ("agent-burn-upstream [status] [--fetch] [--json]", "agent-burn-upstream diff QuotaChart.swift",
                  "agent-burn-upstream update [REV|latest]"):
            self.assertIn(s, out)
        for bad in (["diff"], ["status", "x"], ["update", "--bump"], ["diff", "X", "--diff", "Y"], ["nope"]):
            self.assertEqual(self.run_script(*bad).returncode, 2, bad)

    # ── liste des clés ──
    def test_keys_are_read_by_the_qml(self):
        mod = load()
        qml = "".join((QS / f).read_text() for f in ("Burn.qml", "BurnPopover.qml", "BurnDashboardView.qml"))
        for paths in mod.KEYS.values():
            for p in paths:
                for seg in p.split("."):
                    self.assertIn(seg.removesuffix("[]"), qml, p)


if __name__ == "__main__":
    unittest.main(verbosity=2)
