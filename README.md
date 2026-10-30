# Agent Burn (desktop app)

Agent Burn shows, on Windows, Linux and macOS, what your coding agents spend (Claude Code, Codex and the other agents
its CLI knows), their tokens and models, and your live subscription limits with the pace to stay within them. It does
this through a system tray (or menu bar) icon, a popover, a dashboard and a Settings window. It is a Windows and Linux
remake of Melvynx's macOS app [agent-burn](https://github.com/Melvynx/agent-burn), also built for macOS, and it
bundles that project's CLI (Rust, revision pinned in [`cli.env`](cli.env)) to read the logs, compute prices and read
the limits. MIT license.

Documentation: the [user guide](docs/USAGE.md) (icon, popover, dashboard, settings, updates, states, files,
privacy, troubleshooting, uninstalling); for developers: [architecture](docs/ARCHITECTURE.md),
[providers](docs/PROVIDERS.md), [upstream tracking](docs/UPSTREAM.md),
[tests, build and release](docs/DEVELOPMENT.md).

## Platforms

| Platform | Formats | What was actually checked |
|---|---|---|
| Windows 10 (1809 or later) and 11, x64 | installer, portable zip | By hand on Windows 10 and 11. By GitHub CI, on the `windows-2025` runner (Windows Server 2025): unit tests; build (CLI compiled with MSVC, bundle, selftest of the frozen app); silent install, shortcuts and registry, silent update the way the app starts it (the app restarts, start at login stays off), selftest of the installed app, tray mode for 10 s, 2nd launch, uninstall while the app runs, portable zip ([`windows/smoke.ps1`](windows/smoke.ps1)). Never on a desktop Windows 10 or 11: I have not seen SmartScreen, a real system tray or the dark title bar. Before CI, I tested it under Wine. |
| Windows 11 ARM64 | experimental `arm64` installer, or the x64 installer under emulation | arm64 installer built under Wine during development; CI only builds it on a manual run (the `arm64` checkbox), never done so far. Never run on an ARM machine, x64 emulation not tried. |
| Ubuntu 22.04 and 24.04, Debian 12 and 13 | `.deb` | Packages built by CI (Debian 12 container), then tested in a container of each distro, with no desktop session: install without the recommended packages, command, launcher, icons, AppStream, bundled CLI, selftest of the installed app (software rendering, then Mesa OpenGL under Xvfb), full uninstall ([`linux/smoke.sh`](linux/smoke.sh)). |
| Fedora 44 | `.rpm` (dnf) | Same as above. |
| openSUSE Tumbleweed | `.rpm` (zypper) | Same as above. |
| Arch Linux | `.tar.gz` archive, AppImage | Same as above (archive installed in `/opt`, AppImage run without FUSE). |
| Other x86_64 distro with glibc 2.35 or later | AppImage, archive | Not tried. |
| KDE Plasma (Wayland, and X11 through Xwayland) | | Locally, in a headless nested KWin session, under Wayland and under Xwayland, with a test system tray host. Frozen app (archive): icon, click, menu (Settings…, Logs, Quit), popover placement under X11; with no host, the dashboard, then exit when it is closed. From source: a host showing up 130 s after the app, the host going away, Quit during a CLI run. Never with Plasma's real system tray. |
| GNOME | | GNOME 50, headless (container), during the audit, with the old version of the app: no system tray without the AppIndicator extension, one with it. The current app has not run there. |
| XFCE, Cinnamon, Hyprland, others | | Not tried. |
| EL9 (AlmaLinux, Rocky…) and any glibc older than 2.35 | | Not supported. |
| macOS 14 or later, Apple Silicon | `.zip` (the app) | By GitHub CI, on the `macos-15` runner (an arm64 virtual machine): unit tests, core suite; build (CLI, app signed ad hoc, selftest of the frozen app); then the zip as downloaded: signature, selftest, start at login (LaunchAgent), menu bar mode for 10 s, 2nd launch ([`mac/smoke.sh`](mac/smoke.sh)). Never on a real Mac: I have not seen the menu bar icon, its clicks, the popover under it, Gatekeeper or the Keychain. |
| macOS 14 or later, Intel | `.zip` (the app) | Same, but built and run under Rosetta 2 on that arm64 runner: never on an Intel Mac. |

CI ([`ci.yml`](.github/workflows/ci.yml)) reruns the Windows, Linux and macOS checks above on every push (results in
the Actions tab). Its first complete run, all green, was on 2026-10-25, just before the app got its own repository. I
also run, locally on Linux and from source: unit tests (152), the core suite under Quickshell 0.3.2 and under the
app (342 checks, 29 with corrupted files, 6 with a stuck CLI), selftests, and the nested KWin sessions from the
table.

## Install

### Where to get the files

- [Releases](https://github.com/Magikdidi24/agent-burn-desktop/releases): CI builds every package for each
  `desktop-v<version>` tag and makes a draft release out of them, which I publish by hand.
- Between releases, the CI artifacts: [Actions](https://github.com/Magikdidi24/agent-burn-desktop/actions) tab →
  "Agent Burn (desktop)" workflow → a successful run → `agent-burn-desktop-linux`,
  `agent-burn-desktop-windows-x64`, `agent-burn-desktop-macos-arm64` or `agent-burn-desktop-macos-x64`. You have to
  be signed in to GitHub to download them, and they are kept for 30 days.
- Local build: see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

| File | For |
|---|---|
| `AgentBurn-Setup-<version>-x64.exe` | Windows, installer |
| `AgentBurn-portable-<version>-x64.zip` | Windows, no install |
| `agent-burn-desktop_<version>_amd64.deb` | Debian, Ubuntu |
| `agent-burn-desktop-<version>-1.x86_64.rpm` | Fedora, openSUSE |
| `agent-burn-desktop-<version>-x86_64.AppImage` | any recent x86_64 distro |
| `agent-burn-desktop-<version>-x86_64.tar.gz` | Arch, or a manual install |
| `AgentBurn-<version>-macos-arm64.zip` | macOS, Apple Silicon (M1 and later) |
| `AgentBurn-<version>-macos-x64.zip` | macOS, Intel |
| `SHA256SUMS` | verification: `sha256sum -c --ignore-missing SHA256SUMS` (Windows: `Get-FileHash <file>`; macOS: `shasum -a 256 <file>`) |

### Windows

1. Run `AgentBurn-Setup-<version>-x64.exe`. It installs for your user only, without admin rights, in
   `%LOCALAPPDATA%\Programs\Agent Burn`, with a Start menu shortcut. Two checkboxes: "Start Agent Burn at
   Windows startup" (checked) and "Create a desktop shortcut" (unchecked). The app starts at the end.
2. SmartScreen: the installer is not signed. "Windows protected your PC" → "More info" → "Run anyway".
3. Updating: the app checks GitHub for a new release a minute after it starts, then once a day. When one is out,
   Settings → About → "Update now" (or "Update to Agent Burn X.Y.Z" in the tray icon menu) downloads its
   installer, checks it against the release's `SHA256SUMS`, installs it silently and restarts the app, keeping
   your data, settings and start at login choice. Version 1.0.0 predates this: from 1.0.0, install the next
   version by hand once. Running a newer installer by hand still works: it closes the app if it is running,
   replaces the install and keeps your data and settings.
4. If you pick the folder yourself: the installer only empties its subfolders (`bin`, `licenses`, `PySide6`…)
   when it goes over an existing Agent Burn install (`AgentBurn.exe` and `unins000.dat` present). A folder that
   holds anything else keeps its files.

Without installing: unzip `AgentBurn-portable-<version>-x64.zip` wherever you like and run
`AgentBurn\AgentBurn.exe`. Data and settings still go to `%APPDATA%\AgentBurn`, cache and logs to
`%LOCALAPPDATA%\AgentBurn`. It checks for new releases too, but only offers "Open download page": unzip the new
version in place of the old folder.

### Linux

x86_64 builds, glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora, openSUSE Tumbleweed, Arch…).

```sh
sudo apt install ./agent-burn-desktop_<version>_amd64.deb                              # Debian, Ubuntu
sudo dnf install ./agent-burn-desktop-<version>-1.x86_64.rpm                           # Fedora
sudo zypper install --allow-unsigned-rpm ./agent-burn-desktop-<version>-1.x86_64.rpm   # openSUSE
```

The packages are not signed. They install the app in `/opt/agent-burn-desktop` (with its own CLI in `bin/`, so
no clash with a separately installed `agent-burn`), the `agent-burn-desktop` command, the "Agent Burn" menu
entry, the icons and the AppStream metadata. Recommended packages: a font (DejaVu) and Mesa (OpenGL).

AppImage:

```sh
chmod +x agent-burn-desktop-<version>-x86_64.AppImage
./agent-burn-desktop-<version>-x86_64.AppImage
```

It needs FUSE. Without FUSE: `./agent-burn-desktop-<version>-x86_64.AppImage --appimage-extract-and-run` (or the
`APPIMAGE_EXTRACT_AND_RUN=1` variable). No menu entry. "Start at login" points to the AppImage file: if you move
the file, turn the option on again.

Archive: unpack and run, nothing to install.

```sh
tar -xzf agent-burn-desktop-<version>-x86_64.tar.gz
./agent-burn-desktop-<version>-x86_64/agent-burn-desktop
```

Menu integration (optional), the way the package test does it on Arch:

```sh
V=agent-burn-desktop-1.2.0-x86_64    # archive name without .tar.gz
sudo mkdir /opt/agent-burn-desktop
sudo tar -xzf $V.tar.gz -C /opt/agent-burn-desktop --strip-components=1 --exclude=$V/share
sudo ln -s /opt/agent-burn-desktop/agent-burn-desktop /usr/local/bin/agent-burn-desktop
sudo tar -xzf $V.tar.gz -C /usr/local --strip-components=1 $V/share
```

Dependencies on Arch:
`sudo pacman -S --needed fontconfig freetype2 libdrm libglvnd libx11 libxcb libxkbcommon libxkbcommon-x11 wayland mesa ttf-dejavu`.

### macOS

macOS 14 (Sonoma) or later: the `arm64` zip for Apple Silicon, the `x64` one for Intel.

1. Unzip it (double-click), then move `Agent Burn.app` to Applications before opening it: opened where it was
   downloaded, macOS runs the app from a temporary copy, which start at login refuses.
2. The app is signed ad hoc, not by an Apple developer account, so macOS blocks its first launch ("Agent Burn" Not
   Opened). Then System Settings → Privacy & Security → "Open Anyway", and confirm. Or, in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Agent Burn.app"`.
3. Its icon goes into the menu bar; no Dock icon. Left click: popover; right click or Control-click: menu.
4. Claude limits: the CLI reads Claude Code's sign-in from the Keychain item "Claude Code-credentials" through the
   system `security` tool, the way Claude Code stores it there. If macOS asks whether `security` may use it, allow it
   ("Always Allow" stops the question); denied, the limits stay unknown, the spend still shows.
5. Updating: see [Updates](docs/USAGE.md#updates).

Melvynx's native macOS app is also named `Agent Burn.app`: only one of the two fits in Applications.

### From source

Python 3.12 or newer (the Linux packages bundle 3.12, the Windows and macOS ones 3.13) and PySide6 6.12: see
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Requirements

- Claude Code and/or Codex used on this machine, under this user account: the CLI reads their local logs. Nothing
  else to install: the `agent-burn` CLI, Python and Qt come with the app.
- Live Claude limits: Claude Code signed in (`claude`, then `/login`) and a network connection.
- Codex limits: read from the Codex session logs, or live when Codex is signed in and the network is up.
- For the icon: a system tray (Windows; KDE; GNOME with the AppIndicator extension; the macOS menu bar). Without
  one, the app works as a plain window.

## First launch

- Windows: the installer starts the app. The icon shows up in the system tray, sometimes tucked behind the ^
  arrow: drag it onto the taskbar.
- Linux: the "Agent Burn" menu entry, or `agent-burn-desktop`.
- macOS: Agent Burn in Applications, Spotlight or Launchpad. The icon shows up in the menu bar.
- The first report arrives a few seconds after launch (longer when offline). On later launches, the last report
  shows right away, marked "Cached", until the new one comes in.
- With no system tray, the dashboard opens. The app checks again every 5 s for as long as it runs: a panel started
  after it, or the AppIndicator extension turned on later, gets the icon without restarting the app.
- Starting the app while it is already running opens its dashboard: one instance per user and per session. Two
  launches at the same moment do not make two instances: a lock decides, and the second one tries for about 3 s
  to reach the first (which then opens its dashboard), then exits. On macOS, opened again from Finder, Spotlight or
  Launchpad, the running app shows its dashboard (macOS reactivates it instead of starting another one).

The rest (icon, popover, dashboard, settings, troubleshooting, uninstalling): [docs/USAGE.md](docs/USAGE.md).

## Known limitations

- I have never run it on a real Mac, only on GitHub's macOS runners (arm64 virtual machines, the Intel app under
  Rosetta 2). Not seen: the menu bar icon and its clicks (left, right, Control-click; read from Qt's sources), the
  popover under it, Gatekeeper, the Keychain question, a launch at login, a reopen from Finder.
- Not signed (SmartScreen, antivirus).
- Updates from the app: Windows and macOS. The Windows portable zip, and a Mac app in a folder you can't write to,
  only open the download page, and 1.0.0 predates updates. On Linux, install the new package by hand. No update has
  gone through on a real Windows or Mac yet: CI runs the Windows installer the way the app does (`/relaunch=1`), and
  the tests use a fake GitHub.
- Wayland: the compositor places the popover. GNOME: system tray only with the AppIndicator extension.
- Linux: no idle detection, so readings go on while the session is idle (Windows and macOS pause them after 5 min
  without input).
- macOS: signed ad hoc, not notarized (Gatekeeper, see [macOS](#macos)). Start at login is a LaunchAgent: turned
  off in System Settings → General → Login Items ("Allow in the Background"), it stays on in the app, which only
  sees its plist; after moving the app, turn it on again.
- I have only seen Codex with test data (synthetic or cleaned), never with a real Codex account.
- Outside Claude, limit windows are assumed to be 5 h and 7 days.
- Screen readers: the app exposes the texts of the popover and the dashboard, a one-sentence summary of each
  chart (period, total and most expensive day; quota left and forecast at the reset) and the names of the
  controls; keyboard navigation works. Only checked against Qt's accessibility tree, never with Orca or Narrator.
- Linux: Qt renders without a dedicated render thread (`QSG_RENDER_LOOP=basic`), because the threaded loop of
  Qt 6.12 sometimes crashes under Wayland when a window opens, much more often with texts exposed to screen
  readers (seen in a nested KWin session, software rendering). The app has few animations, so the basic loop is
  enough. A `QSG_RENDER_LOOP` value that is already set wins; ours is passed neither to the CLI nor to
  `xdg-open`. Not rechecked on a real GPU or a real compositor; Qt bug not reported.
- Windows: dark title bar not verified (Wine does not apply it), and no effect expected before Windows 10 20H1.
- Size: about 195 MB installed on Linux; the Windows installer is about 40 MB; the macOS app about 160 MB
  (a zip of 55 MB).
- Linux x86_64 only, glibc 2.35 or later. Windows ARM64 is experimental.
- The CLI is killed if it runs longer than 120 s, and by the installer; on exit, the app waits at most 5 s for a
  run in progress to finish before killing it. If the CLI were rewriting Claude's token at that moment, Claude
  Code could ask for `/login` again (a risk I read in the CLI's code, never observed).

## Development

- `app/`: the PySide6 app (Quickshell compatibility layer, windows, icon, settings), its QML and its tests;
  `shared/`: the `Burn.qml` core and the shared views (popover, dashboard, charts); `linux/`, `windows/`, `mac/`,
  `build.ps1`, `installer.iss`, `agentburn.spec`: package builds and tests; `scripts/`: upstream project
  tracking; `tests/fixtures/`: real CLI output, cleaned; [`cli.env`](cli.env): pinned CLI revision.
- `shared/` is also the core of my Quickshell bar (Hyprland), which keeps a copy synced from this repository, at
  a pinned revision, through a script. So these files have to run as they are under both Quickshell and the app:
  see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#platform-contract).
- Setup, tests, build and release: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Code signing policy

I'm applying to the SignPath Foundation's open source program for the Windows builds: free code signing provided
by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org). Until that is
approved and set up, the Windows app and installer stay unsigned.

- Source: this repository. Releases: [GitHub Releases](https://github.com/Magikdidi24/agent-burn-desktop/releases).
  Every release is built from its `desktop-v*` tag by the CI workflow
  ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)); nothing is built or signed on a personal machine.
- Signed files: `AgentBurn.exe` and the `AgentBurn-Setup-<version>-x64.exe` installer. The third-party files in
  the bundle (Python, Qt, PySide6, the agent-burn CLI) are not signed as mine.
- Roles: I maintain the project alone. Committer, reviewer and approver of every signing request:
  [Berthelot Samuel](https://github.com/Magikdidi24). Changes to the release workflow or this policy go through
  me.
- Privacy: the app sends nothing about you or your usage to me or to anyone else. What it does send over the
  network: the agent-burn CLI asks Claude and Codex for your limits and downloads model prices; on Windows and
  macOS the app asks GitHub for the latest release once a day; with a currency other than USD, or when you open the
  currency list, it downloads exchange rates (once a day at most). Details in the
  [user guide](docs/USAGE.md#privacy-what-the-app-reads-and-writes).

## Licenses

- Agent Burn (this app): MIT, [LICENSE](LICENSE).
- The `agent-burn` CLI (bundled): MIT, © ryoppippi and Melvynx. The licenses of the Rust crates linked into the
  binary, with their full text, are in `THIRD-PARTY-NOTICES.txt`.
- Agent logos (`shared/assets/burn/`) and the app icon (`assets/`): taken from Melvynx's
  [agent-burn](https://github.com/Melvynx/agent-burn), under the same MIT license as the CLI (© ryoppippi and
  Melvynx, text in `LICENSE-agent-burn.txt`). The logos are trademarks of their respective owners; they are only
  used to identify each agent.
- Qt 6, PySide6, Shiboken6: LGPL-3.0, used unmodified. They are separate shared libraries (the app's `PySide6/`
  folder, `Contents/Frameworks/PySide6/` in the macOS app; on Linux, also the `lib*.so.6` links at its root), so you
  can replace them with a compatible modified version without recompiling the app (LGPL-3.0, section 4 d) 1)); on
  macOS, sign the app again afterwards: `codesign --force --deep -s - "Agent Burn.app"`. Notice and links to the
  sources: `NOTICE-Qt-PySide6.txt`; texts: `LGPL-3.0.txt`, `GPL-3.0.txt`.
- Third-party components compiled into Qt and PySide6 (ICU on Linux, PCRE2, HarfBuzz, libpng, FreeType and zlib
  on Windows, Unicode data, Wayland protocols…): platform, SPDX license, copyright and text of each one in
  `QT-THIRD-PARTY.txt`. The image plugins the app never opens (JPEG, TIFF, WebP, GIF, TGA, WBMP, ICNS) and the
  Windows software OpenGL (`opengl32sw.dll`) are not shipped. The macOS app ships the same list, checked against the
  Linux and Windows files only.
- JetBrainsMono Nerd Font: SIL Open Font License 1.1.
- Python: PSF license, with the C libraries of its distribution and the software included in CPython (libmpdec,
  HACL*, Mersenne Twister…), in `LICENSE-Python.txt`.
- Linux: Debian notices of the bundled system libraries (`licenses/debian/`).
- AppImage only: its runtime (type2-runtime) contains libfuse (LGPL-2.1, with its sources and how to relink it),
  squashfuse, zstd, zlib, mimalloc and musl: `NOTICE-AppImage-runtime.txt`.

All these texts are in the `licenses/` folder next to the executable (`Contents/Resources/licenses/` in the macOS
app), which Settings → About → Licenses opens.
The `.deb` also has `/usr/share/doc/agent-burn-desktop/copyright` (the app's MIT license and a pointer to
`licenses/`); the License field of the `.rpm` is the SPDX expression for everything it contains.

Thanks to Melvynx for [agent-burn](https://github.com/Melvynx/agent-burn): the Mac app was the model for this
one, and its CLI does all the work of reading the logs, computing prices and reading the limits.
