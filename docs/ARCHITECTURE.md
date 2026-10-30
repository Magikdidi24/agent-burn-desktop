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
| CLI | `agent-burn` binary from [Melvynx/agent-burn](https://github.com/Melvynx/agent-burn) | Discovers the agents, reads their logs, computes prices (LiteLLM, models.dev, otherwise built-in prices), reads the limits (Claude usage API, Codex). Built by `build.ps1`, `linux/build.sh` and `mac/build.sh`, always at `AB_REV` ([`cli.env`](../cli.env)). |
| Core | [`shared/Burn.qml`](../shared/Burn.qml) | Runs the CLI, validates its output, keeps the cache, archive and readings, computes windows, pace and provider state. |
| Shared views | `shared/BurnPopover.qml`, `BurnDashboardView.qml`, `BurnQuotaChart.qml`, `BurnBarChart.qml`, `BurnButton.qml`, `assets/burn/` | Popover, dashboard, charts, keyboard-accessible button, agent icons. They read `Burn` and act only through its functions (`refresh()`, `setRange()`, `setCurrency()`, `openDashboard()`…) and through `Quickshell.execDetached` (opening the data folder, the rates provider's site). |
| Quickshell host (outside this repo) | `BurnPill.qml`, `BurnDashboard.qml`, `BurnUpstream.qml`, `Colors.qml` from the author's Quickshell bar, which keeps a copy of `shared/` synced from this repo at a pinned revision | Bar pill, dashboard window, upstream tracking, wallust palette. Specific to Quickshell and Hyprland. |
| Desktop app host | [`app/`](../app/) | Compatibility layer (`shim.py`), windows, tray icon, settings, logs, diagnostics, autostart, updates (Windows), selftest. |
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
4. A timer writes `burn-history.json`, `burn-quota.json`, `burn-summary.json` and `burn-fx.json` to the data folder
   atomically, at most once per second.
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
| `IdleMonitor` | Wayland's `ext-idle-notify`, `timeout`, `isIdle` | last input polled every 5 s, on Windows (`GetLastInputInfo`) and macOS (CoreGraphics `CGEventSourceSecondsSinceLastEventType`); Linux never idle |
| `Quickshell.env(name)` | variable or `null` | `os.environ` or `null` |
| `Quickshell.dataDir` | the shell's data directory | directory passed to `shim.register()` |
| `Quickshell.dataPath(p)` | `dataDir + "/" + p` | same |

The shared views add `Quickshell.execDetached` ("Show backup" button and the rates provider's link: on Windows and
macOS, `QDesktopServices` replaces `xdg-open`; on Linux a detached `QProcess` with the cleaned environment), and
`Quickshell.Widgets` `IconImage` and `ClippingRectangle` (`app/qml/widgets/`). They import nothing but `QtQuick`,
`QtQuick.Shapes` and these Quickshell modules: no `QtQuick.Controls`, hence `BurnButton` (`Rectangle` and
`MouseArea`, keyboard focus and accessible name). For the exchange rates, `Burn` uses QML's own `XMLHttpRequest`:
nothing to recreate, the same in both hosts.

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
(the shared QML never does that), any `signal()` kills the process, idle inhibitors are ignored on Windows and
macOS. Beyond
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
  `harness:codex`, `quota`, `cli`, `rates`), `currency` (chosen code, `USD` by default), `currencies` (sorted
  codes that have a rate, `USD` always), `rates` (`{ code: units per USD }`), `ratesAt` (the provider's update).
- **State**: `loading`, `error` (summary, period, missing CLI), `cliMissing`, `signInExpired`, `limitsStale`,
  `dataState` (`live`, `cached`, `unavailable`), `pricingMissing`, `updatedAt`, `now`, `ratesLoading`.
- **Set by the host**: `refreshInterval` (ms, 300,000 by default; the app binds it to its settings),
  `cliTimeoutMs` (maximum duration of a CLI run, 120,000 ms; only the test suite changes it), `cliHint`
  (remedy shown when the CLI is missing), `bin` (`AGENT_BURN_BIN`, otherwise `~/.local/bin/agent-burn`),
  `accessibleText` (false by default; true in the desktop app, false in the bar: see
  [Platform contract](#platform-contract)), `ratesUrl` (only the test suite changes it; `""`: never requested).
- **Navigation**: `dashboardOpen`, `dashboardPage` (`all` or an agent), `range` (`all`, `30d`, `7d`, `today`).
- **Registry**: `providers` (`{ id: { name, color, harness } }`), `knownProviders` (`["claude", "codex"]`,
  always listed), `names`.
- **Derived**: `agents` (agents from the summary and the archive, by descending cost), `tightest`, `remaining`,
  `remainingKey`, `remainingAgent`, `remainingWindow`, `dataDir`, `cliConfig`, `shownCurrency`.
- **Actions**: `refresh(force)`, `poke()` (summary if the data is more than 60 s old), `loadHarness(agent, force)`,
  `loadQuota()`, `loadRange(force)`, `setRange(r)`, `openDashboard(page)`, `setCurrency(code)`, `loadRates()`.
- **Read**: `agentEntry(a)`, `subEntry(a)`, `windows(a)`, `pace(a, key)` (`{ used, elapsed, projected, ratio,
  status, title, detail, exhaustAtMs }`: speed over the last day of the window, or hour for a 5-hour session,
  from the interpolated readings), `quotaSamples(a, key)`,
  `providerState(a)` (`{ state, label, detail, error, at }`), `stateText(s)`, `dailySeries(a)`,
  `spendSince(a, days)`, `lastDays(series, n)`, `priced(cost, tokens)` (`null` for tokens without a price).
- **Format**: `money(v, converted)`, `fx`, `tokens`, `pct`, `tone`, `ago`, `until`, `span`, `iso`, `agentName`,
  `agentIcon`, `agentColor`.
- **IPC** (bar only): `qs ipc call burn refresh`, `qs ipc call burn dashboard`.

Internal, public only because QML requires it, not to be used elsewhere: `cadence`, `staleAfter`, `pendingForce`,
`pendingRefresh`, `pendingHarness`, `rangeCache`, `spans`, `flags`, `launch`, `note`, `missing`, `isReport`,
`result`, `harnessDone`, `setSummary`, `remember`, `record`, `merge`, `load`, `ratesNext`, `rate`, `symbols`,
`ratesDone`, `ratesOf`, and on each `Cli`: `source`, `since`, `at`, `failed`, `problem`, `launched`, `timedOut`,
`errorOutput`.

Currency: amounts stay in USD everywhere (CLI, archive, files); `money()` converts them when it formats, at the
rate of `currency`, or shows USD while that rate is unknown (`shownCurrency`). Symbol for a few unambiguous
currencies, the code otherwise (`CHF 12.34`); no cents at 50 units or more per USD (JPY, KRW, INR…). `BurnBarChart`
gets values already converted (`fx()`), so that its axis is rounded in that currency, and formats them with
`money(v, true)`. The rates: see [Security](#security).

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
| `burn-fx.json` | `{ currency, rates, at, next }` | Display currency and the last valid rates (`at`: the provider's update; `next`: no request before). Read back with the same filter as the answer: invalid codes and rates dropped, an invalid currency becomes `USD`. |
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
4. Default `AGENT_BURN_BIN`: `bin/agent-burn(.exe)` of the bundle once frozen (`sys._MEIPASS`: the exe's directory,
   links resolved: `/opt/agent-burn-desktop/` even when launched through `/usr/bin/agent-burn-desktop`; in the macOS
   app, `Contents/Frameworks`), otherwise `agent-burn` from `PATH`, otherwise `~/.local/bin/agent-burn`.
5. Log ([`logs.setup`](../app/agentburn/logs.py)) before anything else.
6. `setDesktopFileName("io.github.magikdidi24.AgentBurn")` (Wayland app_id, portals); on Linux,
   `-platformtheme xdgdesktopportal` unless `QT_QPA_PLATFORMTHEME` is set (and never in selftest).
7. Tray mode: single instance. First a `QLockFile` (`<socket>.lock`, on Windows
   `<cache>\AgentBurn-<user>-<session>.lock`; the macOS socket is in the cache), stale only if its process is dead:
   two simultaneous launches each probed before the other's `listen()`, and `listen()` is not exclusive on Windows
   (two servers on the same pipe).
   The loser keeps trying to reach the winner for about 3 s, then exits with 0; a lock that cannot be created
   (read-only directory) lets the app start as before. The winner probes the existing instance (`QLocalSocket`): if
   it answers, it opens its dashboard and this process exits with 0. Otherwise `QLocalServer` with
   `UserAccessOption`; a failed `listen()` is logged.
8. Bundled fonts, window icon, `Settings` (in memory for the selftest), `Desktop` and `Updater` (supported only
   when `build-info.json` names a Windows target), color scheme.
9. `runtime.assemble()` prepares the QML directory, `register()` registers the shim then the `Settings`,
   `Desktop` and `Updater` singletons (`import AgentBurn`, app QML only), then `Main.qml` is loaded.
10. `fit()`: dashboard (1200 × 800) and Settings (620 × 680) centered on the primary screen, shrunk on a small
    screen (48 px margin) without going below their minimum size; screen smaller than that minimum: the minimum
    is brought down to the screen, the window fits on it whole and its content scrolls.
11. Selftest, or: dark title bars (Windows), tray icon and automatic update checks (`Updater.start()`), closing
    rules (`quit_when_closed()`: dashboard closed with `closeToTray` false, the app quits once Settings is closed
    too, unless the dashboard is reopened in the meantime; without a system tray, when the last window closes),
    later launches connected to the dashboard (on macOS also the reopen from Finder, Spotlight or Launchpad: the
    app activated while none of its windows, the menu included, is shown), Qt loop.
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
| `tray.py` | `QSystemTrayIcon` and its menu, icon drawn per size, popover placement (`place()`, X11, Windows and macOS; on Wayland, height capped by the screen the compositor put it on), system tray checked again every 5 s for the whole session: host appeared (icon recreated under xcb), gone or back, `Desktop.trayAvailable` tracked both ways and logged. macOS: no context menu set (Qt's status item would open it on every click, left included); a right click or Control-click shows the menu under the icon, in a new `QMenu` each time (Qt closes a menu clicked away while the app is in the background only if its window was created then); icon at 16 pt. |
| `platform_win.py` | `ctypes` and `winreg`: idle time, dark title bar (DWM), `Run` and `StartupApproved\Run` keys, `AllowSetForegroundWindow`, session number. |
| `platform_mac.py` | `ctypes` and `plistlib`: idle time (CoreGraphics, this login session), the user's LaunchAgent (`RunAtLoad`, the bundle's executable, `ProcessType` `Interactive`: an app, not a throttled background job); `Disabled` true or an unreadable plist count as disabled; `OSError` (nothing written) for an app run from its translocated copy or a path with a control character. Only in the `.app` (`<name>.app/Contents/MacOS`). |
| `platform_linux.py` | The user's XDG autostart file, `Exec` key escaped per the Desktop Entry spec; `$APPIMAGE` for an AppImage; `Hidden=true` or `X-GNOME-Autostart-enabled=false` count as disabled; `OSError` (nothing written) for an exe path with a control character, `%` or `\`. |
| `updater.py` | `Updater` singleton, frozen Windows builds only (`build-info.json` target `windows-x64` or `windows-arm64`; elsewhere `mode` is empty and nothing is ever requested): latest GitHub release a minute after the tray icon starts, then every 24 h or on request, one request at a time. Installed app (Inno's `unins000.exe` next to the exe): installer downloaded to the cache, checked by SHA-256, started detached, app quit; portable zip: the release page opens. See [Security](#security). |
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
  Diagnostics, About (with the `Updater` state and buttons on Windows builds). Enter works like Space
  (`activate()`), left and right arrows between the options of a row (`Choice`), current tab in bold and
  underlined and focus ring (`PageTab`, `Ring`), `open(section)` which gives focus to the section's tab, two-step
  reset (5 s), path fields wrapped anywhere.
- `Colors.qml`: same API as the bar's `Colors.qml`; chosen theme or the system's light/dark (unknown: dark);
  system accent made readable (4.5:1 contrast); secondary text (`muted`) at 4.5:1 or more on the background and
  the cards, in light as in dark.
- `widgets/`: `IconImage` and `ClippingRectangle` from `Quickshell.Widgets`.

### Processes and threads

- One process, one Qt main thread; everything is event-driven. The app creates no Python thread.
- Child processes: the CLI runs (asynchronous `QProcess`, output read at the end), `agent-burn --version`
  (killed after 10 s), detached `xdg-open` (Linux; Windows and macOS open folders and links through the system), on
  Windows the installer of an update (detached, with
  `child_environment()`, which it passes on to the app it starts again), and in tests or selftest the exe itself as
  a fake CLI.
- Synchronous file reads and writes on the main thread (small JSON files).
- Single instance through `QLocalServer`: socket `$XDG_RUNTIME_DIR/AgentBurn.sock` (macOS:
  `~/Library/Caches/AgentBurn/AgentBurn.sock`, under the 104-byte limit of socket paths there for a usual home;
  beyond it, `listen()` fails, logged, and the lock alone keeps one instance), or pipe
  `AgentBurn-<user>-<session>` on Windows; preceded by the `QLockFile` lock (see
  [Startup](#startup-agentburn__main__py)).
- On exit, `shim.wait_for_runs(5000)` waits for the CLI runs in progress to finish (5 s at most, without launching
  any other): if killed, a run could lose the Claude token it has just renewed. Then the QML engine is destroyed
  before the shim's Python objects; a run still going at that moment is killed. A run that finishes during the wait
  updates `Burn`, but the write deferred by one second may not happen: the next summary merges those days again.

## Security

- Processes launched as argv, never through a shell. Texts coming from the CLI shown as `Text.PlainText`.
- The app's own network requests: the update on Windows (next item) and the exchange rates:
  `GET https://open.er-api.com/v6/latest/USD`
  (`ratesUrl`, free, no key), with Qt's default headers only (user agent `Mozilla/5.0`, the system language in
  `Accept-Language`), nothing about the usage. Sent only when the currency is not USD (at startup, when it is chosen,
  then checked every hour) or when the currency list opens, never before `ratesNext`: the provider's next update,
  kept between 1 and 24 h. A USD user who never opens the list sends nothing. The answer is validated
  (`result` `success`, `base_code` `USD`, codes of 3 capital letters with a finite positive rate); any failure
  (network, HTTP status, unreadable JSON) keeps the cached rates and goes to `recentErrors`. The provider's terms
  require the "Rates By Exchange Rate API" link, shown in the currency list. The CLI, however, downloads pricing,
  queries the usage APIs and rewrites `~/.claude/.credentials.json` when it renews the Claude token.
- Update, frozen Windows builds only (`updater.py`): `GET https://api.github.com/repos/Magikdidi24/agent-burn-desktop/releases/latest`
  (`Accept: application/vnd.github+json`, user agent `AgentBurn/<version>`), a minute after the tray icon starts,
  then every 24 h, or from "Check for updates"; one request at a time, given up after 30 s without data. The
  answer is validated before any use: drafts and pre-releases ignored; `tag_name` exactly
  `desktop-v<major>.<minor>.<patch>` (ASCII digits), newer than `__version__` compared as numbers; assets
  `AgentBurn-Setup-<version>-<arch>.exe` (arch from `build-info.json`) and `SHA256SUMS`, each with a
  `browser_download_url` exactly `https://github.com/Magikdidi24/agent-burn-desktop/releases/download/desktop-v<version>/<name>`
  (a prefix check would let `../` leave the repository) and a size from 1 byte to 256 MB (64 KB for
  `SHA256SUMS`, 1 MB for the JSON); portable zip: `html_url` exactly the tag's release page, the only thing it
  opens. Network text shown or logged loses its control and format characters (line breaks, escapes, bidi
  overrides). "Update now": `SHA256SUMS` must give exactly one sum for the installer; the installer follows
  GitHub's redirect (Qt's default policy: never from HTTPS to HTTP), is written to `<cache>/AgentBurn-Setup.exe`,
  stopped beyond its announced size, then hashed (hashlib) as read back from disk: a mismatch or any error deletes
  it and runs nothing. It starts detached with `/SILENT /SUPPRESSMSGBOXES /NORESTART /relaunch=1`, plus
  `/MERGETASKS=!autostart` when start at login is off (Inno restores the previous installation's tasks: its
  `autostart` task would turn it back on), then the app leaves through `QCoreApplication.quit()`, like menu →
  Quit (CLI runs awaited, lock released). [`installer.iss`](../installer.iss) starts `{app}\AgentBurn.exe` again
  at the end only with `/relaunch=1`. The hash catches a corrupted or truncated download, not a compromised
  release: `SHA256SUMS` comes from the same release. `AGENT_BURN_UPDATE_URL` (tests) replaces both GitHub
  addresses (`<url>/releases/latest`, `<url>/releases/download/…`, `<url>/releases/tag/…`); like
  `AGENT_BURN_FAKE_DIR`, it stays active in the shipped app and is flagged in the log, but only for an address on
  this machine (`127.0.0.1`, `localhost`, `::1`): any other is ignored, so the variable cannot send "Update now"
  to someone else's installer.
- Atomic writes (`QSaveFile`, `os.replace`); unreadable files copied to `.bak`, never overwritten.
- CLI isolation (configuration, environment, working directory) and the frozen app's environment cleaned for
  every child.
- Single instance: socket in the user's runtime directory (0700; on macOS, in the cache under `~/Library`, 0700,
  rather than `$TMPDIR`, where macOS deletes files left untouched for days) or a pipe named with user and session,
  access restricted to the user (`UserAccessOption`); lock taken before probing, so that two simultaneous launches
  do not create two instances (two icons, duplicate CLI runs, overwritten settings).
- Autostart on Linux: exe path refused if it contains a control character (a line break would add an `Exec` chosen
  by the name of a folder), `%` or `\` (entry rejected by GLib or systemd). On macOS, the plist is written by
  `plistlib` (argv, no shell); refused for an app run from its translocated copy (its path is gone after a restart)
  or with a control character in the path (not allowed in XML).
- QML copy read back byte for byte at every launch: a file modified in the cache is not executed.
- Log and diagnostics redact secrets (patterns: see the
  [user guide](USAGE.md#privacy-what-the-app-reads-and-writes)); the diagnostics contain no environment variable
  and no file content.
- `AGENT_BURN_FAKE_DIR` stays active in the shipped app (the frozen selftest needs it): flagged in the log outside
  the selftest; only `harness claude|codex` are served, never a path taken from argv. `AGENT_BURN_SELFTEST_AUTOSTART`
  too, read only by `--selftest`.
- macOS app: signed ad hoc, not notarized (no paid developer account); no App Sandbox, which would keep the CLI out
  of the agents' folders and quarantine what the app downloads. The `.app` holds a single architecture (checked by
  `mac/build.sh`).
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
