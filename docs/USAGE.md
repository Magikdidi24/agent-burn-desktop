# User guide

Installation, platforms and known limitations: [README](../README.md). Internals: [ARCHITECTURE.md](ARCHITECTURE.md).

## Tray icon

The icon shows the % left of the tightest limit on a badge tinted by pace (gray: stale reading), or a gray flame
as long as there is no data. On hover: the limit and its reset; without a limit, the data state and its cause (CLI
not found, reading in progress, "CLI failed (see Settings › Diagnostics)").

| | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|
| Left click | popover, placed against the icon (near the pointer if the icon is tucked behind the arrow) | popover, near the pointer (the panel does not say where the icon is) | dashboard (the compositor would place the popover itself, often in the center) |
| Double click | dashboard (the popover opened by the 1st click closes) | — | — |
| Middle click | refresh | refresh | refresh |
| Right click | menu | menu, drawn by the panel | menu, drawn by the panel |

Change the left-click action in Settings → General → "Icon click".

Tray icon menu:

- 1 to 3 status lines, not clickable: the tightest limits ("Claude Code · Week: 25% left · resets in 1 d 20 h",
  followed by "· stale" if the reading is old); without a limit, the state of Claude Code and Codex
  ("Codex: Not detected"); without data, "Data unavailable", followed by the cause if there is one
  (": CLI failed (see Settings › Diagnostics)" for example). On Wayland, these lines are the only information
  shown next to the icon.
- Open popover, Open dashboard, Refresh, Start at login (checkbox, unavailable when running from source),
  Settings…, Logs (opens the logs folder), About, Quit.

Depending on the desktop:

- Windows: native system tray.
- Linux: StatusNotifierItem protocol (KDE Plasma, GNOME with the AppIndicator extension, XFCE, Cinnamon…).
  Only a KDE-style test host has been tried, in a nested session.
- GNOME without the AppIndicator / KStatusNotifierItem extension: no system tray. The app runs as a standalone
  window, closing the dashboard quits it, and Settings → General says so. Ubuntu enables this extension by
  default, Fedora ships it disabled (not verified here).

Closing windows: with an icon, closing the dashboard leaves the app in the system tray (option
"Keep in the system tray when closed", on by default). With the option off, closing the dashboard quits the app,
once Settings is closed too if it was open (reopening the dashboard in the meantime cancels this). Without an
icon, closing the last window quits the app, including when the system tray disappears along the way (panel
stopped): the app notices within 5 s. Otherwise: menu → Quit. On exit, the app waits up to 5 s for a CLI run in
progress to finish.

## Popover

A card placed against the icon (Windows) or near the pointer (X11), closed by Esc, by "Open dashboard" or by a
click elsewhere.

- General tab: total spend (all agents, API equivalent), tokens, today's spend, one line per agent, chart of the
  last 14 days.
- One tab per agent that has limits (Claude Code, Codex…): provider state, spend over the last 30 days, monthly
  plan, % left of the weekly limit shown large, then the other limits (5-hour session, per-model limits), pace
  verdict ("Room to keep going", "Pace slightly too fast" with the estimated run-out time and the pace to keep,
  "Limit reached") and chart of the readings with their forecast.
- At the bottom: data state ("Live · updated 2 min ago"), the CLI error if there is one, "Open dashboard" button.
  The refresh button is at the top right.
- Screen too short for the card: it scrolls, and Tab scrolls it to the focused control; Page Up, Page Down, Home
  and End scroll it.

## Dashboard

- Sidebar: All agents, one page per agent, Settings at the bottom. Period at the top: All, 30 days, 7 days, Today
  (the selected period in bold and in color).
- All agents: total spend, tokens, days recorded, models; Providers card (Claude Code and Codex, then the
  detected agents, with their state); daily spend; spend by agent; models table (filter, sort by column).
- Agent page: state, warnings (CLI error, error specific to this agent, explanation of the state when it is not
  "Live", missing pricing), plan (one gauge per limit, Claude extra credits), plan economics and breakdown by
  token type over 30 days (Claude Code and Codex), daily spend, models.
- Daily history: Claude Code deletes its logs older than 30 days; the app keeps every day it has seen, even after
  an update or an uninstall. "Show backup" opens the data folder.
- Keyboard: Tab moves through the controls, and the page (or the "By agent" list) scrolls to the focused control;
  Page Up, Page Down, Home and End scroll the page. Esc in "Filter models" clears the filter; a 2nd Esc, or Esc
  elsewhere, closes the window.
- Size: 1200 × 800, reduced on a small screen but never below 900 × 600; on an even smaller screen, the window
  takes the available space and its content scrolls. At 900 × 600, a card title drops its gray detail
  ("Last 30 days") when both do not fit on the line.

## Settings

Tray icon menu → Settings…, or the dashboard's Settings button. Every change is saved right away. Esc closes the
window (an open list first).

Keyboard: Tab moves from one control to the next (the page scrolls to it), Space or Enter activates it (button,
switch, option, tab), Left or Right arrow moves to the neighboring option in a row and selects it. The control
reached with the keyboard has a ring in the accent color; the current section's tab is bold and underlined. When
opened on a section from the tray icon menu (Settings…, About), the window puts the focus on its tab.

| Section | Setting | Values (default) | Effect |
|---|---|---|---|
| General | Auto refresh | 1, 5, 15 or 30 min (5) | Limits read at this interval, full report at least once an hour (on every round if the tightest limit is not a Claude window). The open dashboard reloads at the same interval. |
| | Theme | System, Light, Dark (System) | System follows the desktop's light/dark mode (on Linux, through xdg-desktop-portal). |
| | Start at login | yes / no (no, unless the Windows installer box was checked) | Not available from source (switch grayed out). Windows: `AgentBurn` value of `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (disabling it in Task Manager is respected; turning the option back on undoes that). Linux: `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop`, which launches the app's exe, links resolved (`/opt/agent-burn-desktop/agent-burn-desktop` for the packages), or the AppImage file; `Hidden=true` or `X-GNOME-Autostart-enabled=false` (set by the desktop's tool) count as disabled; only this file is created or removed. An app path that contains a control character (line break…), `%` or `\` is refused and the option stays off (noted in the log): the entry would be hijacked or ignored. |
| | Keep in the system tray when closed | yes / no (yes) | No: closing the dashboard quits the app. |
| | Icon click | Popover, Dashboard (Dashboard on Wayland, Popover elsewhere) | Left-click action. |
| Providers | — | — | Claude Code, Codex, then every other agent seen: state, explanation, age of the reading, last error specific to the agent. agent-burn CLI: location, version ("unreadable" if `--version` prints nothing, "no response (10 s)" if it hangs), report state followed by the CLI error on failure, "Refresh now" button. |
| Diagnostics | — | — | Versions (app, CLI, CLI expected by the build), system, display ("Wayland (KDE)", "X11 (GNOME, Wayland session)" for an X11 app on Wayland…), screens, system tray, folders. "Open logs", "Open data folder", "Copy diagnostics" buttons. "Detailed log (debug)" switch, no restart needed (content: see [Privacy](#privacy-what-the-app-reads-and-writes)). Recent errors (time, source, message). "Reset settings" button, in two steps: it becomes "Confirm reset" for 5 s, and only a 2nd press resets. |
| About | — | — | Versions, credit, "Licenses" button (installed app). |

Settings are stored in `settings.json` (see [Where the files are](#where-the-files-are)): `refreshMinutes`,
`theme`, `closeToTray`, `trayClick`, `debugLogging`. An invalid value falls back to its default (noted in the
log). A file saved with a UTF-8 byte order mark (Notepad, PowerShell 5) is read normally. An unreadable file
(invalid JSON, even nested to the extreme) is copied to `settings.json.bak`, the defaults apply and Diagnostics
says so. Start at login is not stored there: it is read from the system.

## Data state

Shown at the bottom of the popover and the dashboard, in Settings → Providers, and in the icon's tooltip when no
limit has been read.

| State | When | What to do |
|---|---|---|
| **Live** | The CLI's last report succeeded within the last hour plus one refresh round and 2 min (the longest a run can take: an hourly report in progress does not switch the state to "Cached"). | Nothing. |
| **Cached** | Report read back from disk at launch, until the first run; or last run failed (CLI error, no response within 120 s, unreadable report, CLI missing); or report too old. The last figures stay on screen. | Refresh. If it lasts, read the error (bottom of the popover, Settings → Diagnostics → Recent errors). |
| **Unavailable** | No successful report, not even an old one. | Wait for the first report, otherwise see [Troubleshooting](#troubleshooting). |

## Provider states

Shown on the agent's tab, at the top of its dashboard page, in the Providers card, in Settings → Providers and in
the tray icon menu when there is no limit. The signals are detailed in [PROVIDERS.md](PROVIDERS.md).

| Label | Meaning | What to do |
|---|---|---|
| **Live** | Limits read recently: from the Claude account within the last 10 min, or within two refresh rounds when the interval is over 5 min (30 min at a 15-min interval, 60 min at 30 min); for the other agents, in the last report, itself live. | Nothing. |
| **Stale reading** | Last known limits, kept on screen: no Claude reading for longer than this threshold (the detail says so: "no reading for more than 10 min"), because of the network, or the usage API refusing calls that come too often; for the others, a cached report. | Refresh, check the network. |
| **Check sign-in** | Claude only: the sign-in renewal was refused. Either the sign-in expired, or the network was down while the token had expired (waking from sleep before the Wi-Fi is back): the CLI cannot tell the difference. | Check the network, then Refresh. If it persists with the network up: `claude` in a terminal, then `/login`. |
| **Local usage** | Spend read from the logs, no limits. Claude: not signed in or offline (the CLI does not say which). Others: no limit in the report, or limits older than 7 days (old Codex logs), which are discarded. | Claude: sign in, check the network. Codex: a recent Codex session brings its limits up to date. |
| **Not detected** | The CLI finds neither usage nor a subscription for this agent. | Normal if the agent is not used on this machine with this account. |
| **Report failed** | No successful report, not even an old one, and the CLI's last run failed: the detail is the CLI error. | Read the error, then Refresh; see the [CLI errors](#cli-not-found). |
| **Unknown** | No report yet, and no failure. | Wait a few seconds. |
| **CLI not found** | The bundled CLI does not start. | See [CLI not found](#cli-not-found). |

## Where the files are

| | Windows | Linux |
|---|---|---|
| App | `%LOCALAPPDATA%\Programs\Agent Burn` (installer), or the zip's folder | `/opt/agent-burn-desktop` (packages), the AppImage file, or the archive's folder |
| Bundled CLI | `bin\agent-burn.exe` in the app folder | `bin/agent-burn` in the app folder |
| Data | `%APPDATA%\AgentBurn` | `~/.local/share/agent-burn-desktop` (`$XDG_DATA_HOME`) |
| Settings | `%APPDATA%\AgentBurn\settings.json` | `~/.config/agent-burn-desktop/settings.json` (`$XDG_CONFIG_HOME`) |
| Logs | `%LOCALAPPDATA%\AgentBurn\logs` | `~/.local/state/agent-burn-desktop/logs` (`$XDG_STATE_HOME`) |
| Cache | `%LOCALAPPDATA%\AgentBurn\cache` | `~/.cache/agent-burn-desktop` and `~/.cache/AgentBurn/qmlcache` (`$XDG_CACHE_HOME`) |
| Start at login | `AgentBurn` value of `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop` |
| Single instance | named pipe `\\.\pipe\AgentBurn-<user>-<session>`, lock `%LOCALAPPDATA%\AgentBurn\cache\AgentBurn-<user>-<session>.lock` | `$XDG_RUNTIME_DIR/AgentBurn.sock` and its lock `AgentBurn.sock.lock` |
| The CLI's own cache | `%USERPROFILE%\.cache\agent-burn` | `~/.cache/agent-burn` |

Data folder:

- `burn-history.json`: daily archive (cost and tokens per day and per agent);
- `burn-quota.json`: last reading of the Claude account and limit readings from the last 8 days (charts);
- `burn-summary.json`: last successful report, shown as "Cached" at launch;
- `*.bak`: copy of one of these files found unreadable, the app then starting that file over from scratch;
- `agent-burn-cli.json` never exists: it is the empty configuration passed to the CLI (see below).

Logs: `agent-burn.log`, rotated at 1 MB with 3 copies (`.1` to `.3`), one line per event
(`<ISO time> <LEVEL> <logger>: <message>`). Cache: prepared copy of the QML (`qml-<hash>`, checked again at every
launch) and Qt's compiled cache. The `AGENT_BURN_DATA` variable overrides the data folder (tests).

## Privacy: what the app reads and writes

- The app makes no network calls. It launches the bundled `agent-burn` CLI (arguments passed directly, never
  through a shell), one run of each kind at a time, and reads its JSON output.
- The CLI reads Claude Code's logs and configuration (`~/.claude/projects`, `~/.claude.json`), its sign-in token
  (`~/.claude/.credentials.json`) to read the limits, the Codex logs (`~/.codex/sessions`,
  `~/.codex/archived_sessions`) and its token (`~/.codex/auth.json`), and the folders of the other agents. On
  Windows, these paths are under `%USERPROFILE%`: the app forces `HOME=%USERPROFILE%` on the CLI, which would
  otherwise follow a `HOME` set elsewhere (Git Bash for example).
- The CLI writes: when Claude's OAuth token has expired, it renews it and rewrites `~/.claude/.credentials.json`,
  like Claude Code does (temporary locks in `~/.claude`); and its cache `claude-usage.json`.
- The CLI contacts: pricing (LiteLLM on raw.githubusercontent.com, models.dev), `api.anthropic.com` (Claude
  limits), `platform.claude.com` (token renewal), `chatgpt.com` (Codex limits, if Codex is signed in).
- The user's agent-burn configuration is ignored on purpose: each run gets
  `--config <data folder>/agent-burn-cli.json`, a file that is never created. `./.agent-burn/`,
  `~/.config/agent-burn/agent-burn.json` and `~/.claude/agent-burn.json` (`noCost`, `jq`, `offline`…) therefore
  have no effect, and neither do inherited `AGENT_BURN_FORCE_REFRESH`, `AGENT_BURN_QUOTA_ONLY` or `LOG_LEVEL`.
  The CLI runs in the data folder. The figures are thus those of the CLI with its defaults, whatever the
  machine's configuration.
- The app writes only its folders (table above), the start at login entry when the option is on, and its
  single-instance endpoint with its lock. Usage (costs, tokens, models, plan) is stored there in plain text.
- Logs: command line of each CLI run (with the paths), exit code, duration, output size, the CLI's `Error:` line
  on failure; never the report itself. Also Qt and QML messages, Python errors with their traceback, and the
  system tray appearing or disappearing.
- Detailed log (debug), in addition: the end of the stderr of each CLI run (4,000 characters at most), the
  settings in effect at startup and after every change, every write of the settings, the system theme and its
  changes, clicks on the icon, 2nd launches handed over to the running instance.
- Redacted as `[redacted]`, in the log as well as on the error output: `sk-ant-…` tokens, `Bearer` values, JWTs,
  access/refresh/id token values (also in escaped JSON, as the CLI prints it in an error), email addresses, hex or
  base64 strings of 32 characters or more that mix digits and letters, including right after an `=`
  (`KEY=value`, URL parameter); UUIDs in paths are redacted too. These are patterns: a secret of another shape
  would get through.
- Copied diagnostics: same redaction, no environment variables and no file contents. They contain the folder
  paths, and so the user name.

## Troubleshooting

### No icon in the system tray

- Windows: the icon may be behind the ^ arrow on the taskbar: drag it out.
- GNOME: install and enable the AppIndicator extension (already on in Ubuntu). Settings → General points this out
  when no system tray is detected.
- Panel started, or extension enabled, after the app: the icon appears within 5 s, without restarting the app.
- Settings → Diagnostics → "System tray" says what the app found. Without an icon, everything stays reachable
  from the dashboard.

### The popover opens in the center of the screen (Wayland)

This is normal: on Wayland, the compositor ignores the position the app asks for. So left click opens the
dashboard by default, and the lines at the top of the menu give the limits. The popover stays in the menu
("Open popover") and can become the click action again (Settings → General → Icon click).

### Check sign-in

The CLI's renewal of the Claude sign-in was refused. The CLI sends the same signal for an expired sign-in and for
an expired token without network. Check the network, then Refresh: after a refusal, the CLI waits 10 min before
trying again, and Refresh forces a new attempt. If it persists with the network up, run `claude` in a terminal,
then `/login`. The last known limits stay on screen, marked stale.

### Pricing unavailable

Banner "Pricing unavailable: amounts incomplete (network down or pricing not downloaded)": the CLI could not
download the prices (offline, LiteLLM unreachable), and its built-in prices do not know recent models, which are
counted at $0. The app shows "—" rather than $0.00 and the archive keeps the cost already known for past days. Go
back online, then Refresh. Offline, a report also takes much more computation.

### CLI not found

App message: "Agent Burn can't find its CLI (<path>): reinstall the app."

- The CLI is `bin\agent-burn.exe` (Windows) or `bin/agent-burn` (Linux) in the app folder. Settings → Providers →
  agent-burn CLI gives its location and version.
- Windows: an antivirus may have quarantined it. Restore it, or reinstall.
- An `AGENT_BURN_BIN` variable set in the environment overrides this path: remove it.

Other CLI errors, shown as is at the bottom of the popover and the dashboard, in Settings → Providers ("Report")
and in Diagnostics → Recent errors. With no report at all, not even an old one, each provider shows
"Report failed" with the message; with no known limit, the icon's tooltip (and without data, its menu) says
"CLI failed (see Settings › Diagnostics)":

- "agent-burn failed (code 1): …", followed by the CLI's message. For example
  "No valid Claude data directories found in CLAUDE_CONFIG_DIR": the `CLAUDE_CONFIG_DIR` variable points to a
  folder without `projects/`, which makes the whole report fail, Codex included. Fix it or remove it.
- "Incompatible agent-burn CLI" (code 2): the CLI rejects an option; it does not match the version the app
  expects (reinstall, or remove `AGENT_BURN_BIN`).
- "agent-burn did not respond within 120 s": run stopped. Can happen offline with a large history (prices
  computed without downloaded pricing).
- "agent-burn returned an unreadable report.": output that is not a report. Attach the diagnostics to a bug
  report.
- CLI version "unreadable" or "no response (10 s)" (Settings → Providers): `agent-burn --version` printed
  nothing, or did not respond within 10 s. Same fix as when the CLI is not found.

### SmartScreen, antivirus

Neither the installer nor the app is signed: SmartScreen warns on first launch ("More info" → "Run anyway"), and
some antivirus products distrust PyInstaller executables. First check the file against `SHA256SUMS`. If the
antivirus removes `bin\agent-burn.exe`, the app shows "CLI not found".

### Wrong theme

- Settings → General → Theme: Light or Dark forces the theme.
- Linux, with System: the theme is read through xdg-desktop-portal. Without a portal, the app does not know the
  desktop theme and uses dark. If `QT_QPA_PLATFORMTHEME` is set, the app uses that Qt module instead of the
  portal.
- Windows: the app follows the light/dark mode for apps and the accent color.

### Collecting diagnostics

- Settings → Diagnostics → Copy diagnostics: versions, system, folders, state of each provider, recent errors.
  Paste it into a bug report.
- Logs: tray icon menu → Logs, or Settings → Diagnostics → Open logs. For more detail, turn on
  "Detailed log (debug)" (end of the stderr of each CLI run, settings, clicks on the icon), reproduce, then
  attach `agent-burn.log`.

### Resetting settings

Settings → Diagnostics → Reset settings, then Confirm reset within 5 s (start at login does not change). Or
delete `settings.json` while the app is closed. To erase everything, also delete the data folder: the history is
then lost.

## Uninstalling

| Format | Uninstall | What remains |
|---|---|---|
| Windows installer | Settings → Apps → Installed apps → Agent Burn → Uninstall. Stops the app (any `AgentBurn.exe` instance of the user, portable copy included), removes the folder, the shortcuts, start at login, the cache and the logs. | `%APPDATA%\AgentBurn` (history, settings), which a reinstall picks up again. |
| Portable zip | Turn off "Start at login", quit, delete the folder. | `%APPDATA%\AgentBurn`, `%LOCALAPPDATA%\AgentBurn`. |
| `.deb`, `.rpm` | Turn off start at login, quit, then `sudo apt remove agent-burn-desktop`, `sudo dnf remove agent-burn-desktop` or `sudo zypper remove agent-burn-desktop`. | The user's folders (data, settings, logs, cache). |
| AppImage | Turn off start at login, quit, delete the file. | Same. |
| Archive | Turn off start at login, quit, delete the folder. If installed as in the [README](../README.md#linux): `sudo rm -r /opt/agent-burn-desktop /usr/local/bin/agent-burn-desktop` and the `io.github.magikdidi24.AgentBurn.*` files copied under `/usr/local/share` (`applications/`, `metainfo/`, `icons/hicolor/*/apps/`). | Same. |

On Linux, if start at login is still on, `~/.config/autostart/io.github.magikdidi24.AgentBurn.desktop` stays
behind: delete it. To erase everything:
`rm -r ~/.local/share/agent-burn-desktop ~/.config/agent-burn-desktop ~/.local/state/agent-burn-desktop ~/.cache/agent-burn-desktop ~/.cache/AgentBurn`
(Windows: delete `%APPDATA%\AgentBurn` and `%LOCALAPPDATA%\AgentBurn`). The CLI cache (`~/.cache/agent-burn`)
belongs to the CLI and may be used by another `agent-burn`: it is never touched.
