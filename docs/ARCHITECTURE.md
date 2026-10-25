# Agent Burn architecture

For anyone changing the code. Usage: [README](../README.md) and [USAGE.md](USAGE.md). Provider signals and states:
[PROVIDERS.md](PROVIDERS.md). Tests, build, release: [DEVELOPMENT.md](DEVELOPMENT.md).

## Overview

```
        agent-burn CLI (Rust, upstream project, revision AB_REV from cli.env)
        agent logs, pricing, live limits
                     │  JSON on stdout: summary, harness <agent>, light reading
        Burn.qml: shared core (QML singleton, no view)
        CLI runs, validation, cache, daily archive, state of each provider
                     │  QML properties and functions
        shared views: BurnPopover, BurnDashboardView, BurnQuotaChart, BurnBarChart, BurnButton
                     │
        ┌────────────┴──────────────────────────┐
  Quickshell 0.3.2 (bar, separate repo)     desktop app (PySide6 6.12) + shim.py
  BurnPill, BurnDashboard, BurnUpstream,    Main, PopoverWindow, DashboardWindow, SettingsWindow,
  Colors (wallust palette)                  Colors, tray.py, settings, logs, diagnostics
```

Three rules hold it all together:

- the CLI computes (logs, prices, limits); neither the core nor the app reads the agents' files itself;
- `Burn.qml` decides what is shown and how fresh it is, from the CLI's signals alone; an unknown value stays
  `null` (shown as "—"), never 0;
- the views only display; the host (Quickshell or the app) provides windows, icon and platform.

## Components

| Layer | Files | Role |
|---|---|---|
| CLI | `agent-burn` binary from [Melvynx/agent-burn](https://github.com/Melvynx/agent-burn) | Discovers the agents, reads their logs, computes prices (LiteLLM, models.dev, otherwise built-in prices), reads the limits (Claude usage API, Codex). Built by `build.ps1` and `linux/build.sh`, always at `AB_REV` ([`cli.env`](../cli.env)). |
| Core | [`shared/Burn.qml`](../shared/Burn.qml) | Runs the CLI, validates its output, keeps the cache, archive and readings, computes windows, pace and provider state. |
| Shared views | `shared/BurnPopover.qml`, `BurnDashboardView.qml`, `BurnQuotaChart.qml`, `BurnBarChart.qml`, `BurnButton.qml`, `assets/burn/` | Popover, dashboard, charts, keyboard-accessible button, agent icons. They read `Burn` and act only through its functions (`refresh()`, `setRange()`, `openDashboard()`…) and through `Quickshell.execDetached` (opening the data folder). |
| Quickshell host (outside this repo) | `BurnPill.qml`, `BurnDashboard.qml`, `BurnUpstream.qml`, `Colors.qml` from the author's Quickshell bar, which keeps a copy of `shared/` synced from this repo at a pinned revision | Bar pill, dashboard window, upstream tracking, wallust palette. Specific to Quickshell and Hyprland. |
| Desktop app host | [`app/`](../app/) | Compatibility layer (`shim.py`), windows, tray icon, settings, logs, diagnostics, autostart, selftest. |
| Upstream tracking | [`scripts/agent-burn-upstream.py`](../scripts/agent-burn-upstream.py) | See [UPSTREAM.md](UPSTREAM.md). |

## Data flow

1. `Burn` runs the CLI (argv, never a shell). Exact commands, `--config` always last:
   - report: `agent-burn summary --value --json --no-color --config <data>/agent-burn-cli.json`;
   - dashboard period: the same with `--since YYYYMMDD` before `--config`;
   - detail page: `agent-burn harness claude|codex --value --json --no-color --config …`;
   - light reading of the Claude limits: `agent-burn harness claude --json --no-color --config …` with
     `AGENT_BURN_QUOTA_ONLY=1`.
2. stdout and stderr are read at the end of the run. Exit code 0 and valid JSON: the report is accepted if it has an
   `agents[]` array (summary, period), the light reading if it has `window` and `observedAt > 0`. Otherwise see
   [Errors](#errors).
3. An accepted summary becomes `Burn.summary` (`updatedAt` = now); its `claudeAccount` replaces the stored account
   if it is not older; `claudeAccountStatus` sets `signInExpired`; its days are merged into the archive; one reading
   per limit window is added to the samples. A period fills `rangeCache[range]` and also merges its days. A harness
   fills `harnesses[agent]` (or `harnessErrors[agent]`). A light reading updates the week and the session of the
   Claude account and resets `signInExpired` to false.
4. A timer writes `burn-history.json`, `burn-quota.json` and `burn-summary.json` to the data folder atomically, at
   most once per second.
5. The views read the properties of `Burn` and its read functions (`windows()`, `pace()`, `providerState()`,
   `dailySeries()`…). The `Burn.now` clock ticks every 10 s (stopped while idle) for the values that age
   ("3 min ago", past resets).

## Platform contract

`Burn.qml` imports `Quickshell`, `Quickshell.Io` and `Quickshell.Wayland` and uses only 9 symbols. Quickshell
provides them in the bar; [`shim.py`](../app/agentburn/shim.py) recreates them in the app with the same semantics.

| Symbol | Quickshell | `shim.py` |
|---|---|---|
| `Singleton` | QML singleton | `Scope` (default property `children`) |
| `Process` | `command`, `environment` (`null` removes a variable), `running`, `exec()`, `signal()`, `started`, `exited(exitCode, exitStatus)`; `running: true` written before `command` starts after loading | on `QProcess`, same properties and signals, same deferred start for `running` set before `command`; starting environment `child_environment()`, working directory = data folder, every run logged |
| `StdioCollector` | `text` at the end of the stream | filled before `exited`, as under qs |
| `FileView` | `path`, `text()`, `setText()`, `preload`, `blockLoading`, `blockWrites`, `printErrors` | synchronous read, atomic write (`QSaveFile`); the loading settings are accepted with no effect |
| `IpcHandler` | `target` and functions callable by `qs ipc call` | no IPC; functions callable from Python (tests) |
| `IdleMonitor` | Wayland's `ext-idle-notify`, `timeout`, `isIdle` | Windows: last input (`GetLastInputInfo`) polled every 5 s; elsewhere never idle |
| `Quickshell.env(name)` | variable or `null` | `os.environ` or `null` |
| `Quickshell.dataDir` | the shell's data directory | directory passed to `shim.register()` |
| `Quickshell.dataPath(p)` | `dataDir + "/" + p` | same |

The shared views add `Quickshell.execDetached` ("Show backup" button: on Windows, `QDesktopServices` replaces
`xdg-open`; elsewhere a detached `QProcess` with the cleaned environment), and `Quickshell.Widgets` `IconImage` and
`ClippingRectangle` (`app/qml/widgets/`). They import nothing but `QtQuick`, `QtQuick.Shapes` and these Quickshell
modules: no `QtQuick.Controls`, hence `BurnButton` (`Rectangle` and `MouseArea`, keyboard focus and accessible
name).

Screen readers: `Burn.accessibleText` (false by default) decides whether the views expose their texts. When true,
every `Txt` in `BurnPopover` and `BurnDashboardView` gets `Accessible.role = StaticText` and an `Accessible.name`
bound to its text, both set from JS; `BurnBarChart` and `BurnQuotaChart` get the `Chart` role and a summary
sentence (period, total and most expensive day; remaining and forecast at the reset; without a chart, the message
shown). When false, no extra `Accessible` object is created: the bar's accessibility tree stays as it was. The
desktop app sets it to true (`Main.qml`), with the basic render loop on Linux; the bar leaves it false, because on
Qt 6.12 these objects crash Wayland's threaded render loop, the one the bar uses, far more often. A `Txt` that
serves as the label of a `BurnButton` or of a field, or that has its own `Accessible.name`, takes `spoken: false`:
otherwise it would be announced twice.

Reproduced semantics, observed under qs: at the end of a run, `streamFinished` → `exited` (`running` already
false) → `runningChanged`; missing binary: a single `runningChanged`, without `started` (this is how `Burn` detects
a CLI that is not found). Shim shortcuts, commented in the code: `exec()` during a run relaunches nothing at its end
(the shared QML never does that), any `signal()` kills the process, idle inhibitors are ignored on Windows. Beyond
qs: `shim.wait_for_runs(ms)`, called by the app when it closes, waits for the runs in progress to finish (one
shared timeout, `exited` delivered during the wait) and launches none afterwards, even from an `exited`; true if
all have finished.

The proof: [`tests/burn-suite/shell.qml`](../app/tests/burn-suite/shell.qml) tests `Burn.qml` without a window,
with a fake CLI, and runs as is under `qs -p` and under the shim
([`run_burn_suite.py`](../app/tests/run_burn_suite.py)). Both must give the same result, in all three modes
(normal, corrupted persisted files, stuck CLI); commands in
[DEVELOPMENT.md](DEVELOPMENT.md#core-suite-burnqml).

`shim.register()` is called only once per process: a 2nd registration breaks type identity on the PySide side,
and the `Quickshell` singleton stays bound to the first QML engine.

## Core: the `Burn` API

Public, used by the views and the hosts:

- **Data**: `summary`, `summaryCached`, `harnesses`, `harnessErrors` (`{ agent: message }`), `account`
  (latest `claudeAccount`), `rangeSummary`, `history`, `historyDays`, `samples`, `recentErrors` (last 20
  failures `{ t, source, msg }`, without stdout; `source` is one of `summary`, `range`, `harness:claude`,
  `harness:codex`, `quota`, `cli`).
- **State**: `loading`, `error` (summary, period, missing CLI), `cliMissing`, `signInExpired`, `limitsStale`,
  `dataState` (`live`, `cached`, `unavailable`), `pricingMissing`, `updatedAt`, `now`.
- **Set by the host**: `refreshInterval` (ms, 300,000 by default; the app binds it to its settings),
  `cliTimeoutMs` (maximum duration of a CLI run, 120,000 ms; only the test suite changes it), `cliHint`
  (remedy shown when the CLI is missing), `bin` (`AGENT_BURN_BIN`, otherwise `~/.local/bin/agent-burn`),
  `accessibleText` (false by default; true in the desktop app, false in the bar: see
  [Platform contract](#platform-contract)).
- **Navigation**: `dashboardOpen`, `dashboardPage` (`all` or an agent), `range` (`all`, `30d`, `7d`, `today`).
- **Registry**: `providers` (`{ id: { name, color, harness } }`), `knownProviders` (`["claude", "codex"]`,
  always listed), `names`.
- **Derived**: `agents` (agents from the summary and the archive, by descending cost), `tightest`, `remaining`,
  `remainingKey`, `remainingAgent`, `remainingWindow`, `dataDir`, `cliConfig`.
- **Actions**: `refresh(force)`, `poke()` (summary if the data is more than 60 s old), `loadHarness(agent, force)`,
  `loadQuota()`, `loadRange(force)`, `setRange(r)`, `openDashboard(page)`.
- **Read**: `agentEntry(a)`, `subEntry(a)`, `windows(a)`, `pace(a, key)`, `quotaSamples(a, key)`,
  `providerState(a)` (`{ state, label, detail, error, at }`), `stateText(s)`, `dailySeries(a)`,
  `spendSince(a, days)`, `lastDays(series, n)`, `priced(cost, tokens)` (`null` for tokens without a price).
- **Format**: `money`, `tokens`, `pct`, `tone`, `ago`, `until`, `span`, `iso`, `agentName`, `agentIcon`,
  `agentColor`.
- **IPC** (bar only): `qs ipc call burn refresh`, `qs ipc call burn dashboard`.

Internal, public only because QML requires it, not to be used elsewhere: `cadence`, `staleAfter`, `pendingForce`,
`pendingRefresh`, `pendingHarness`, `rangeCache`, `spans`, `flags`, `launch`, `note`, `missing`, `isReport`,
`result`, `harnessDone`, `setSummary`, `remember`, `record`, `merge`, `load`, and on each `Cli`: `source`,
`since`, `at`, `failed`, `problem`, `launched`, `timedOut`, `errorOutput`.

`dataState`: `unavailable` without a summary; `cached` if the summary comes from disk (`summaryCached`), if the
last summary failed, or if it is older than one hour plus one `cadence` plus `cliTimeoutMs` (the maximum duration
of a run: the hourly summary in progress does not switch it to cached); otherwise `live`. `stateText()` turns it
into "Live", "Cached", "Unavailable". `limitsStale`: Claude reading older than `staleAfter` = max(10 min,
2 × `cadence`), or the sign-in needs checking. `providerState()` is described in
[PROVIDERS.md](PROVIDERS.md#provider-states).

## Errors

Messages shared by `error`, `harnessErrors` and `recentErrors.msg`:

| Case | Message |
|---|---|
| run killed after 120 s | "agent-burn did not respond within 120 s: try again in a moment." |
| exit code 2 (option unknown to the CLI) | "Incompatible agent-burn CLI" + ": detail" |
| other non-zero exit code | "agent-burn failed (code N)" + ": detail" |
| exit code 0 but invalid JSON, summary without `agents[]`, light reading without `window` or without `observedAt` | "agent-burn returned an unreadable report." |
| cannot launch | "agent-burn not found or not executable: <path>"; sets `cliMissing` and `error` (except for the light reading) |

The detail is the stderr line that starts with `Error: ` (otherwise the first non-empty one); an
`Error: CliError("…")` is unwrapped and its Rust escapes (`\"`, `\\`) undone; 160 characters at most. A harness
failure only touches `harnessErrors[agent]` (cleared on the next success), never `error`. A light reading failure
only goes to `recentErrors`: the last account stays, flagged stale after `staleAfter`. With no summary at all,
`error` becomes the detail of the "Report failed" state of every provider.

In the app, every run is also logged (logger `agentburn.cli`): command line, exit code, duration, bytes, the error
line on failure; at DEBUG ("Detailed log"), the end of stderr, 4,000 characters at most, redacted like the rest of
the log.

## Persisted files

In the data folder (`Quickshell.dataDir`; for the app, see
[the user guide](USAGE.md#where-the-files-are)):

| File | Contents | Rules |
|---|---|---|
| `burn-history.json` | `{ "YYYY-MM-DD": { cost, tokens, agents: { id: { cost, tokens } } } }` | A summary replaces the days it contains, the others stay. A cost that drops without a drop in tokens, or $0 with tokens (missing pricing), keeps the archived cost. |
| `burn-quota.json` | `{ account, samples }` | `samples`: `{ "agent:window": [{ t, used }] }`, 8 days, one point per newer reading, plateaus compacted. |
| `burn-summary.json` | `{ at, data }` | Last successful summary. Read back at startup only if `at > 0` and `data.agents` is an array: `summaryCached` true, no merge and no reading replayed. |
| `*.bak` | raw copy of one of the files above, found unreadable | The core starts over from an empty object for that file. |
| `agent-burn-cli.json` | never created | Passed to the CLI as `--config`. |
| `burn-upstream.json` | bar only (`BurnUpstream.qml`) | Notified upstream head, dismissed banner, date of the last report. |

Writes: at most one per second, atomic (renamed temporary file).

## Refresh

| Trigger | What runs |
|---|---|
| 3 s after loading | summary, unless a run is in progress or a summary succeeded less than 60 s ago (dashboard opened at launch) |
| background round, every `cadence` = max(60 s, `refreshInterval`), except while idle | light reading if the tightest limit is Claude's session or week and the summary is less than an hour old; otherwise summary |
| back from idle (`IdleMonitor`, 300 s) | `poke()` |
| popover open: on opening, then every 60 s | `poke()` |
| dashboard open: on opening, then every `refreshInterval` | `poke()`, harness of the agents that have a subscription (if the previous one is more than 5 min old), period on opening and after each summary; on opening, `Burn` itself calls `poke()` before `loadRange()`: the period waits for that summary, if it runs, and follows it |
| Refresh (buttons, menu, middle click, IPC) | forced summary (`AGENT_BURN_FORCE_REFRESH=1`), then forced harness and period if the dashboard is open |

Only one run of each kind at a time (5 `Cli` instances: summary, period, light reading, harness claude,
harness codex). During a summary:

- `refresh()` is recorded (`pendingForce`) and replayed, forced, when it ends;
- `loadHarness()` is recorded (`pendingHarness`) and launched right after it, even if it failed;
- `loadRange()` and `loadQuota()` do not run: the usage API answers 429 to several processes at once, and the
  reading the summary shares (55 s on the CLI side) serves the next runs. The end of the summary relaunches the
  period if the dashboard is open.

During a period, `refresh()` is recorded (`pendingRefresh`, and `pendingForce` if it is forced) and launched when
it ends, forced if any of the calls was; the end of that summary then reloads the period. So a summary and a
period never run together. `loadHarness()` and `loadQuota()`, however, do not wait for the period (rare: a period
takes about 1 s).

Watchdog: every 5 s while a run is going, a run that has lasted more than `cliTimeoutMs` (120 s) is killed
(`signal(9)`); its `exited` produces the timeout message.

## CLI isolation

The JSON must depend only on the agents' data, not on the machine's configuration:

- `--config <data>/agent-burn-cli.json` at the end of every command. With `--config`, the CLI reads only this
  file, and a missing file means "no configuration": `./.agent-burn/`, `~/.config/agent-burn/agent-burn.json`
  and `~/.claude/agent-burn.json` (`noCost`, `jq`, `offline`, which change the JSON) are ignored. Checked with
  CLI 20.0.21 in fake HOMEs, offline.
- `AGENT_BURN_FORCE_REFRESH`, `AGENT_BURN_QUOTA_ONLY` and `LOG_LEVEL` are removed (`null`) unless the run sets
  them itself (forced summary, light reading). An inherited `AGENT_BURN_QUOTA_ONLY` would change the shape of the
  summary.
- In the app, `shim.child_environment()` also:
  - frozen app: removes `_PYI_*`, `QT_PLUGIN_PATH`, `QML2_IMPORT_PATH`, `QML_IMPORT_PATH`, and gives
    `LD_LIBRARY_PATH` back its value from before the PyInstaller launcher (`LD_LIBRARY_PATH_ORIG`) or removes it:
    otherwise a system Qt program launched by `xdg-open` would load the bundle's Qt;
  - Windows: `HOME` = `USERPROFILE` (the CLI reads `HOME` before `USERPROFILE`);
  - keeps the rest (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`…);
  - working directory = data folder.
- Under Quickshell, the working directory is qs's own; `--config` is enough to neutralize `./.agent-burn/`.

## Desktop app

### Startup (`agentburn/__main__.py`)

1. Fake CLI: with `AGENT_BURN_FAKE_DIR` and an argv of `summary`, `harness claude|codex` or `--version`, the exe
   serves the fixtures from that directory (dates shifted to today) and exits, without loading Qt. Used by the
   tests and by the selftest of the frozen app, where `AGENT_BURN_BIN` is the exe itself. Outside the selftest, the
   variable is flagged in the log.
2. Options: `--selftest DIR`, `--show popover|dashboard` (dev: that window alone, without the tray icon).
3. On Linux, `QSG_RENDER_LOOP=basic` (removed from launched processes: `shim.APP_VARS`) unless a value is already
   set or the platform is `offscreen` (selftest): the threaded render loop of Qt 6.12 crashes in QtWaylandClient
   (`QWaylandWindow::beginFrame`) while a window is being shown, far more often with the texts exposed to screen
   readers (seen in a nested KWin session, Mesa llvmpipe: no crash in 9 tries with the basic loop). Offscreen,
   there is nothing from Wayland, and the basic loop would capture the top of the enlarged popover badly.
4. Default `AGENT_BURN_BIN`: `<exe directory>/bin/agent-burn(.exe)` once frozen (exe with links resolved:
   `/opt/agent-burn-desktop/` even when launched through `/usr/bin/agent-burn-desktop`), otherwise `agent-burn`
   from `PATH`, otherwise `~/.local/bin/agent-burn`.
5. Log ([`logs.setup`](../app/agentburn/logs.py)) before anything else.
6. `setDesktopFileName("io.github.magikdidi24.AgentBurn")` (Wayland app_id, portals); on Linux,
   `-platformtheme xdgdesktopportal` unless `QT_QPA_PLATFORMTHEME` is set (and never in selftest).
7. Tray mode: single instance. First a `QLockFile` (`<socket>.lock`, on Windows
   `<cache>\AgentBurn-<user>-<session>.lock`), stale only if its process is dead: two simultaneous launches each
   probed before the other's `listen()`, and `listen()` is not exclusive on Windows (two servers on the same pipe).
   The loser keeps trying to reach the winner for about 3 s, then exits with 0; a lock that cannot be created
   (read-only directory) lets the app start as before. The winner probes the existing instance (`QLocalSocket`): if
   it answers, it opens its dashboard and this process exits with 0. Otherwise `QLocalServer` with
   `UserAccessOption`; a failed `listen()` is logged.
8. Bundled fonts, window icon, `Settings` (in memory for the selftest) and `Desktop`, color scheme.
9. `runtime.assemble()` prepares the QML directory, `register()` registers the shim then the `Settings` and
   `Desktop` singletons (`import AgentBurn`, app QML only), then `Main.qml` is loaded.
10. `fit()`: dashboard (1200 × 800) and Settings (620 × 680) centered on the primary screen, shrunk on a small
    screen (48 px margin) without going below their minimum size; screen smaller than that minimum: the minimum
    is brought down to the screen, the window fits on it whole and its content scrolls.
11. Selftest, or: dark title bars (Windows), tray icon, closing rules (`quit_when_closed()`: dashboard closed with
    `closeToTray` false, the app quits once Settings is closed too, unless the dashboard is reopened in the
    meantime; without a system tray, when the last window closes), later launches connected to the dashboard, Qt
    loop.
12. On leaving the loop: `shim.wait_for_runs(5000)`, then the QML engine is destroyed.

### Python modules (`app/agentburn/`)

| Module | Role |
|---|---|
| `shim.py` | Quickshell types (see above), `child_environment()`, `agentburn.cli` log of each run (command line, exit code, duration, bytes; end of stderr at DEBUG; never stdout), `wait_for_runs()` on closing. |
| `runtime.py` | Assembles the shared QML (`SHARED`, also read by `agentburn.spec`), `assets/burn/`, the app QML and a `qmldir` (`Burn` and `Colors` singletons) in `<cache>/qml-<content sha1>`. Reused only if it is identical byte for byte, with no extra file; otherwise rebuilt, then renamed atomically. |
| `paths.py` | The only place that knows the per-OS directories and the single-instance name. |
| `settings.py` | `Settings` singleton: validated JSON (UTF-8 BOM accepted), written atomically, `.bak` of an unreadable file (invalid JSON, extreme nesting), `reset()`. Autostart is delegated to the platform module (none in dev). |
| `logs.py` | Rotating file (1 MB × 3, UTF-8), stderr outside the frozen app (switched back to UTF-8, even when redirected on Windows), secret redaction on every handler, Qt messages on the `qt` logger, uncaught exceptions logged (main thread, threads), DEBUG level switched on the fly. The DEBUG lines: end of the CLI's stderr (`shim.py`), settings in effect and every write, system theme, clicks on the icon, 2nd launches. |
| `diagnostics.py` | `Desktop` singleton: versions (app, `build-info.json` or `cli.env` in dev, `agent-burn --version` read in the background: "unreadable" if empty, "no response (10 s)" if it hangs), platform, screens, folders, opening the folders, redacted diagnostics text. |
| `tray.py` | `QSystemTrayIcon` and its menu, icon drawn per size, popover placement (`place()`, X11 and Windows; on Wayland, height capped by the screen the compositor put it on), system tray checked again every 5 s for the whole session: host appeared (icon recreated under xcb), gone or back, `Desktop.trayAvailable` tracked both ways and logged. |
| `platform_win.py` | `ctypes` and `winreg`: idle time, dark title bar (DWM), `Run` and `StartupApproved\Run` keys, `AllowSetForegroundWindow`, session number. |
| `platform_linux.py` | The user's XDG autostart file, `Exec` key escaped per the Desktop Entry spec; `$APPIMAGE` for an AppImage; `Hidden=true` or `X-GNOME-Autostart-enabled=false` count as disabled; `OSError` (nothing written) for an exe path with a control character, `%` or `\`. |
| `selftest.py` | Renders the icon, the popover, the dashboard and the 4 settings sections; rejects a capture that is empty, of a single color, of the wrong size or with a transparent corner; writes `selftest.json`. |

### App QML (`app/qml/`)

- `Main.qml`: root (`QtObject`), read by `tray.py` and `selftest.py`: `remaining`, `tone`, `tooltip`,
  `menuLines`, `popover`, `dashboard`, `settingsWindow`; `openDashboard()`, `refresh()`,
  `openSettings(section)`. Binds `Burn.refreshInterval` to `Settings.refreshMinutes` and `Burn.accessibleText` to
  true, sets `Burn.cliHint` and `Colors.theme`. With no limit and with `Burn.error`, the tooltip (and, without
  data, the menu line) ends with "CLI failed (see Settings › Diagnostics)".
- `PopoverWindow.qml`: frameless window around `BurnPopover`, scrollable if the screen is too short: scrolls to
  the control reached with Tab, Page Up / Page Down / Home / End.
- `DashboardWindow.qml`: window around `BurnDashboardView` (Settings button enabled), reloads at the interval set
  in the settings. Keyboard scrolling (focus followed, Page Up / Page Down / Home / End) and Escape in the model
  filter are in `BurnDashboardView`, shared with the bar.
- `SettingsWindow.qml`: Qt Quick controls (Fusion) in the `Colors` palette; sections General, Providers,
  Diagnostics, About. Enter works like Space (`activate()`), left and right arrows between the options of a row
  (`Choice`), current tab in bold and underlined and focus ring (`PageTab`, `Ring`), `open(section)` which gives
  focus to the section's tab, two-step reset (5 s), path fields wrapped anywhere.
- `Colors.qml`: same API as the bar's `Colors.qml`; chosen theme or the system's light/dark (unknown: dark);
  system accent made readable (4.5:1 contrast); secondary text (`muted`) at 4.5:1 or more on the background and
  the cards, in light as in dark.
- `widgets/`: `IconImage` and `ClippingRectangle` from `Quickshell.Widgets`.

### Processes and threads

- One process, one Qt main thread; everything is event-driven. The app creates no Python thread.
- Child processes: the CLI runs (asynchronous `QProcess`, output read at the end), `agent-burn --version`
  (killed after 10 s), detached `xdg-open`, and in tests or selftest the exe itself as a fake CLI.
- Synchronous file reads and writes on the main thread (small JSON files).
- Single instance through `QLocalServer`: socket `$XDG_RUNTIME_DIR/AgentBurn.sock`, or pipe
  `AgentBurn-<user>-<session>` on Windows; preceded by the `QLockFile` lock (see
  [Startup](#startup-agentburn__main__py)).
- On exit, `shim.wait_for_runs(5000)` waits for the CLI runs in progress to finish (5 s at most, without launching
  any other): if killed, a run could lose the Claude token it has just renewed. Then the QML engine is destroyed
  before the shim's Python objects; a run still going at that moment is killed. A run that finishes during the wait
  updates `Burn`, but the write deferred by one second may not happen: the next summary merges those days again.

## Security

- Processes launched as argv, never through a shell. Texts coming from the CLI shown as `Text.PlainText`.
- No network calls from the app. The CLI, however, downloads pricing, queries the usage APIs and rewrites
  `~/.claude/.credentials.json` when it renews the Claude token.
- Atomic writes (`QSaveFile`, `os.replace`); unreadable files copied to `.bak`, never overwritten.
- CLI isolation (configuration, environment, working directory) and the frozen app's environment cleaned for
  every child.
- Single instance: socket in the user's runtime directory (0700) or a pipe named with user and session, access
  restricted to the user (`UserAccessOption`); lock taken before probing, so that two simultaneous launches do not
  create two instances (two icons, duplicate CLI runs, overwritten settings).
- Autostart on Linux: exe path refused if it contains a control character (a line break would add an `Exec` chosen
  by the name of a folder), `%` or `\` (entry rejected by GLib or systemd).
- QML copy read back byte for byte at every launch: a file modified in the cache is not executed.
- Log and diagnostics redact secrets (patterns: see the
  [user guide](USAGE.md#privacy-what-the-app-reads-and-writes)); the diagnostics contain no environment variable
  and no file content.
- `AGENT_BURN_FAKE_DIR` stays active in the shipped app (the frozen selftest needs it): flagged in the log outside
  the selftest; only `harness claude|codex` are served, never a path taken from argv.
- Builds: Nerd Font and downloaded tools (nfpm, appimagetool, AppImage
  runtime, rustup-init) checked by sha256; Python dependencies installed from a hashed lock file
  (`app/requirements.lock`, `--require-hashes`); Linux build image pinned by digest. CI: actions
  pinned by SHA, `persist-credentials: false`, `contents: read` everywhere except the release job.
- Windows installer: its `[InstallDelete]` lines empty the bundle's subdirectories only over an existing Agent Burn
  install (`OwnInstall`: `AgentBurn.exe` and `unins000.dat` present), and the installer does not offer to choose
  the folder (`DisableDirPage`): otherwise an existing folder picked by hand would be emptied on the next update.
  Only `/DIR=` on the command line can still target another folder.
- Known issues: `AllowSetForegroundWindow(ASFW_ANY)` on the 2nd launch on Windows (any process can take the
  foreground until the next input); in dev on Windows, `shutil.which("agent-burn")` also searches the working
  directory; the Windows uninstallation stops every `AgentBurn.exe` of the user by its name.

## Adding a provider

The CLI does the discovery: an agent it knows already shows up, with its id as its name and a gray color. To
integrate it properly:

1. **Registry**: add `<id>: { name, color, harness: false }` to `providers` in `Burn.qml`, and the icon
   `shared/assets/burn/<id>.png` (copied by `runtime.assemble()` and by `agentburn.spec`).
   `harness` is only informative: no code reads it.
2. **Always listed** (settings, diagnostics, tray icon menu, Providers card) even when missing: add it to
   `knownProviders`. Otherwise it is listed only once seen in a report.
3. **Limits**: nothing to do if the CLI puts it in `subscription.agents` with `window` / `shortWindow`;
   `windows()` shows them, assuming 5 h / 7 days and expiring them at 7 days. If its windows differ, read their
   duration from the report (see the `shortcut` comment of `windows()`).
4. **Detail page** (`harness <id>`): only `claude` and `codex` have a `Cli` in `Burn.qml`. It needs a new `Cli`
   (`source: "harness:<id>"`), its case in `loadHarness()`, the list replayed at the end of the summary
   (`["claude", "codex"]`), the label of the source in `SettingsWindow.qml`, the keys read in `KEYS` of
   `agent-burn-upstream.py`, and the fake CLI (`fake_cli` in `__main__.py`, which accepts only `claude` and `codex`).
5. **State**: `providerState()` applies as is; its Claude-specific branches only concern `claude`.
6. **Tests**: a cleaned real fixture in `tests/fixtures/` (dates set to the capture day, see
   [UPSTREAM.md](UPSTREAM.md#recapturing-the-fixtures)), its case in `burn-suite/fake/gen.py` and
   `shell.qml`, the suite under both qs and the shim, the selftest for rendering.
7. **Upstream tracking**: map the new files of the Mac app in the `PORT` table.
