# Tracking the upstream project

Agent Burn follows [Melvynx/agent-burn](https://github.com/Melvynx/agent-burn): the macOS app (model for the views)
and the Rust CLI (data engine). The CLI is pinned in [`cli.env`](../cli.env) by two lines that always change
together:

```sh
AB_REV=<full sha of the upstream commit>
AB_VER="agent-burn <version>"      # what agent-burn --version answers
```

`build.ps1` and `linux/build.sh` compile this CLI for the app and check that `--version` does answer `AB_VER`.
Upstream publishes no Linux or Windows binaries: it has to be compiled.

## The `agent-burn-upstream` tool

Script [`scripts/agent-burn-upstream.py`](../scripts/agent-burn-upstream.py), run from the repo root
(`scripts/agent-burn-upstream.py status`); called `agent-burn-upstream` below, the name it gives itself. Python 3
and git, nothing else (cargo for `update`).

| Command | Effect |
|---|---|
| `agent-burn-upstream [status] [--fetch] [--json]` | Report (default command): upstream `AB_REV..main` commits, grouped, new tags, files of this repo to review. |
| `agent-burn-upstream diff FILE` | Upstream diff of a file since `AB_REV`, by name (`QuotaChart.swift`) or path from the upstream root. |
| `agent-burn-upstream update [REV\|latest]` | Compiles the CLI at `REV` (tag or sha; `latest` = upstream `main`), checks its JSON and pins it in `cli.env`. Installs nothing. |

- `--fetch` goes with every command: it first updates the local copy of upstream (network). Without it,
  everything is read from the copy. Offline, `--fetch` warns ("Warning: offline, report from the cache") and
  carries on with the copy.
- The copy is a clone without blobs or checkout in `~/.cache/agent-burn-upstream/repo`. Without a copy, the
  command asks for `agent-burn-upstream status --fetch`.
- Old forms, still valid: `--fetch --json` (the one the Quickshell bar's banner uses), `--diff FILE`,
  `--bump [REV]`.
- Exit codes: 0 success (or already pinned); 1 failure, file not found or incompatible CLI (with `--json`,
  the empty JSON then carries `error`); 2 usage error (unknown command, `diff` without a file, two commands).
- Variables: `AGENT_BURN_UPSTREAM_URL` (upstream repo), `AGENT_BURN_UPSTREAM_CACHE` (copy and compiled CLI),
  `AGENT_BURN_CLI_ENV` (`cli.env` to read and modify).
- `--json`: `{ pinned, pinnedVersion, head, headDate, ahead, tags: { cli, mac }, categories: { mac, cli, docs,
  other }, toPort, compareUrl, fetchedAt, error }`.
- Any text coming from upstream (commit subjects, file names, git errors, diff) is stripped of its control
  characters (replaced with `?`): a commit subject cannot do anything to the terminal. Tags are kept only
  if they look like a version (`v1.2.3`, `macos-v…`). `diff` has neither color nor pager:
  add `| less` to page through it.

Reading the text report:

- groups: Mac app, CLI, Docs, CI/infra, Other;
- `[JSON output → check Burn.qml]`: the JSON that `Burn.qml` reads changes (summary, harness, reading, Claude
  account);
- `[pricing]`: prices change;
- under a Mac app commit, `File.swift → files of this repo`; "to assess": file missing from the
  script's `PORT` table, to add there; "not ported": left out on purpose (Cursor account view; automatic
  update);
- "Repo files to review", then the "Compare" link to GitHub.

In the Quickshell bar (`BurnUpstream.qml`, outside this repo): `--fetch --json` once a day
(first try 2 min after loading), and when the dashboard opens if the report is more than an hour old. A new
upstream head gives a single notification and a banner in the dashboard, until × dismisses it. Banner buttons:
"Report" (the text report in kitty) and "GitHub" (comparison). The desktop app does not have this tracking.

## Syncing in 7 steps

1. Check upstream. The Quickshell bar's banner does it every day. By hand, without network:
   `agent-burn-upstream status` (JSON: `agent-burn-upstream status --json`).

2. Fetch. `agent-burn-upstream status --fetch` updates the copy, then lists the grouped `AB_REV..main`
   commits, the new tags, the files of this repo to review and the compare link. If it prints
   "Up to date: no upstream commit since your version.", there is nothing to do.

3. Analyze. For each upstream file listed:
   `agent-burn-upstream diff QuotaChart.swift` or
   `agent-burn-upstream diff rust/crates/agent-burn/src/adapter/all/summary.rs`.
   Before porting, check what has already diverged here, from the repo root: `git status`, then
   `git log -p -- <file>` for each file to review.

4. Integrate.
   - Port into the listed files: shared QML (`shared/`), app (`app/…`).
   - Bump the CLI: `agent-burn-upstream update --fetch` (latest `main`) or
     `agent-burn-upstream update v20.0.22` (tag or sha). See [what `update` guarantees](#what-update-guarantees).
   - Incompatible CLI: nothing has changed. Adapt the QML while trying the compiled CLI
     (`AGENT_BURN_BIN=~/.cache/agent-burn-upstream/cli/bin/agent-burn`), then run `update` again.
   - [Recapture the fixtures](#recapturing-the-fixtures) with the new CLI.
   - Commit: `git add cli.env` (or `add -p cli.env` if `update` reported local changes), plus the
     ported files, then `git commit -m "agent-burn: CLI pinned to <sha12> (agent-burn <version>)"` (the
     message that `update` suggests).

5. Check Claude. The offline check of `update` does not see `claudeAccount`, `claudeAccountStatus`
   (present only when the sign-in has expired), the light reading (`observedAt`, `window`,
   `sessionWindow`) or the windows of `harness claude`: they only exist online. Run the app from
   source with the compiled CLI (from `app/`:
   `AGENT_BURN_BIN=~/.cache/agent-burn-upstream/cli/bin/agent-burn python -m agentburn`), then look at the icon
   (what is left of the tightest limit), the Claude tab of the popover (session, week, per-model limits, time
   of the reading) and the Claude page of the dashboard (plan economics, breakdown by token type, models).
   Online, if needed:

   ```sh
   B=~/.cache/agent-burn-upstream/cli/bin/agent-burn
   $B summary --value --json --no-color | jq '{claudeAccount, claudeAccountStatus}'
   AGENT_BURN_QUOTA_ONLY=1 $B harness claude --json --no-color | jq '{observedAt, window, sessionWindow}'
   ```

   These online runs may refresh the token and rewrite `~/.claude/.credentials.json` (behavior of the
   CLI).

6. Check Codex. `update` already checks `harness codex` and the Codex window of the summary on a synthetic
   Codex session: expected "harness codex: ok (10 keys)". With Codex installed:
   `$B harness codex --value --json --no-color | jq '{plan, economics, spendMix, window}'`, then the
   Codex page of the dashboard and its limits in the popover. Without Codex on the machine, note "not verified
   on real data".

7. Check the desktop app. From `app/`, with the development Python: unit
   tests, core suite under the shim (normal, `BURN_TEST=corrupt`, `BURN_TEST=timeout`) and under qs, selftest
   (OpenGL: nested session or `xvfb-run`), upstream tracking and license tools tests; commands in
   [DEVELOPMENT.md](DEVELOPMENT.md#tests). Then `git push`: CI
   ([`ci.yml`](../.github/workflows/ci.yml)) recompiles the pinned CLI
   (its caches, the CLI and the upstream Rust toolchain, are keyed on `AB_REV`) and rebuilds the packages. The
   crate notices (`THIRD-PARTY-NOTICES.txt`) and the License field of the `.rpm` are recomputed from it: a crate
   whose license is not an SPDX expression stops the Linux build (`tools/package_license.py` rejects it).
   The Quickshell bar only sees these changes at its next sync from this repo.

## What `update` guarantees

In order:

1. Resolves `REV` in the copy (`latest`, `main` or `HEAD` = `origin/main`, never the local branch of the clone).
   Same sha as `AB_REV`: "cli.env already pins …: nothing to do.", code 0.
2. Reads the version in `rust/crates/agent-burn/Cargo.toml` at that commit and refuses anything that is not a
   version (a shell may source the `AB_VER="…"` line of `cli.env`).
3. Says whether `cli.env` has uncommitted changes ("kept") or none.
4. Compiles into the cache: `cargo install --locked --force --git <upstream> --rev <sha> agent-burn --bin agent-burn
   --root ~/.cache/agent-burn-upstream/cli` (about 2 min).
5. Checks the compiled CLI offline, on a synthetic HOME (a Claude session with a Max plan, a
   Codex Plus session with limits in its logs), environment reduced to `HOME` and `PATH`, current directory
   = that HOME: neither the data, the configuration nor the variables of the user skew the result.
   - `--version` must answer the expected version;
   - `summary`: 22 keys read by `Burn.qml` and the views;
   - `harness claude`: 13 keys (the 3 of `window` stay "not checkable" offline);
   - `harness codex`: 10 keys.

   A missing key makes the CLI incompatible; a `null` key or an empty list is reported as "not checkable"
   without blocking.
6. Only if everything is compatible: atomic rewrite of only the `AB_REV` and `AB_VER` lines of `cli.env`,
   read again after the compilation (an edit made during those 2 min stays), with a `cli.env.bak` copy
   (ignored by git) and the diff shown.

Cargo failure, different version or incompatible JSON: `cli.env` does not change. In no case does `update`
install the CLI (`~/.local/bin` stays untouched): it stays in the cache, to try with `AGENT_BURN_BIN`. These
cases are covered by `scripts/test_agent_burn_upstream.py` (fake upstream repo, fake cargo).

## Recapturing the fixtures

The tests and the selftest serve real CLI outputs, cleaned up, from
[`tests/fixtures/`](../tests/fixtures/). There is no recapture script: the commands
are the app's.

| File | Capture |
|---|---|
| `summary-live.json` | `agent-burn summary --value --json --no-color`, online, Claude account present |
| `summary-offline.json` | the same with `--offline` (pricing missing) |
| `harness-claude.json` | `agent-burn harness claude --value --json --no-color` |
| `quota-claude-live.json` | `AGENT_BURN_QUOTA_ONLY=1 agent-burn harness claude --json --no-color` |
| `summary-claude-signin-expired.json` | summary with `claudeAccountStatus: "signInExpired"` (also without pricing: total cost 0) |
| `summary-codex-stale-logs.json` | summary on Codex logs older than 7 days |
| `summary-empty-home.json`, `summary-installed-no-usage.json` | summary of an empty HOME; of a Claude account without usage |
| `summary-quota-env-leak.json` | summary run with an inherited `AGENT_BURN_QUOTA_ONLY=1` (no `agents[]`) |
| `error-claude-config-dir.stderr.txt`, `error-unknown-flag.stderr.txt` | stderr of a code 1 (invalid `CLAUDE_CONFIG_DIR`) and of a code 2 (unknown option) |
| `codex/` | full directory for `AGENT_BURN_FAKE_DIR`: live Claude and a synthetic Codex session |

Rules:

- Run with `--config <missing file>` like the app; the offline cases in a fake HOME
  (`env -i HOME=<directory> PATH=$PATH agent-burn … --offline`).
- Clean up: no name, no email, no organization or account id. Only percentages, timestamps,
  amounts and model names remain.
- Align the dates on one capture day (the last day of the report) and put that day in the two
  constants that shift the fixtures to today: `fake_cli()` in `app/agentburn/__main__.py` and
  `app/tests/burn-suite/fake/gen.py` (currently `date(2026, 10, 23)`).
- The top-level directory deliberately has no `harness-codex.json`: the tests check the failure of the
  Codex harness there. `codex/` has one.
- Then rerun the unit tests, the core suite (shim and qs) and the selftest, with both fixture
  directories.
