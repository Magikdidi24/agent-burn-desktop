# Development, tests, build and release

Architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Usage: [README](../README.md) and [USAGE.md](USAGE.md).

## Setup

- Python 3.12 on Linux, 3.13 on Windows and macOS (the ones CI and the builds use: python.org no longer publishes
  binaries of 3.12), and the only dependency, pinned in
  [`app/requirements.txt`](../app/requirements.txt) (`PySide6-Essentials==6.12.0`):

  ```sh
  python3.12 -m venv ~/.venvs/agent-burn
  ~/.venvs/agent-burn/bin/pip install -r app/requirements.txt
  ```

  Windows: `py -3.13 -m venv .venv`, then `.venv\Scripts\pip install -r app\requirements.txt`.

  Builds and CI install [`app/requirements.lock`](../app/requirements.lock) instead, with
  `pip install --require-hashes`: the lock of [`app/requirements-build.txt`](../app/requirements-build.txt)
  (`requirements.txt` plus `pyinstaller==6.22.3`), versions and sha256 of the whole tree for Linux x86_64,
  Windows x64 and ARM64, and macOS (universal2 wheels, for both builds). After a change to either of these two files,
  regenerate the lock from `app/`:
  `uv pip compile --universal --python-version 3.12 --generate-hashes requirements-build.txt -o requirements.lock`
  (with `--universal`, `--python-version` is a minimum: the lock also holds for 3.13).
- The `agent-burn` CLI, at the `AB_REV` revision of [`cli.env`](../cli.env):
  - Linux: `cargo install --locked --git https://github.com/Melvynx/agent-burn --rev <AB_REV> agent-burn --bin agent-burn --root ~/.local`
    (into `~/.local/bin/agent-burn`);
  - Windows: a first `build.ps1` run compiles it into `build\cli\bin\agent-burn.exe`;
  - macOS: the `cargo install` above, or a first `mac/build.sh` run (`build/cli-mac-<arch>/bin/agent-burn`);
  - or no CLI at all, with the fixtures (see below).
- Font: the build scripts put JetBrainsMono Nerd Font into `app/fonts/`, which runs from source also load.
  Without it, the font must be installed on the system, otherwise the icons show up as squares.
- Packages: podman (Linux build and tests); PowerShell 7.4+, Git, Rust (rustup, MSVC toolchain) and Inno Setup
  6.3+ (Windows); Xcode command line tools (`xcode-select --install`: clang, `codesign`, `sips`, `iconutil`,
  `ditto`), Git and Rust (rustup) on macOS.

## Running from source

Linux, from `app/`:

```sh
python -m agentburn                    # tray icon, like the installed app
python -m agentburn --show dashboard   # this window alone, without the icon (or --show popover)

# Without a real CLI: the fake agent-burn serves the fixtures (dates shifted to today), separate data
AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures AGENT_BURN_BIN=$PWD/tests/fake-agent-burn \
    AGENT_BURN_DATA=/tmp/agent-burn-dev python -m agentburn --show dashboard
```

`tests/fake-agent-burn` runs `python3 -m agentburn`, which serves the fixtures without loading Qt: the system
Python is enough. `tests/fixtures/codex` adds Codex.

macOS: the same commands, without `xdg-open` or D-Bus to worry about. Python shows in the Dock (no `LSUIElement`
outside the app bundle), and start at login is unavailable.

Windows (PowerShell), from `app\`:

```powershell
$env:AGENT_BURN_BIN = "$PWD\..\build\cli\bin\agent-burn.exe"
python -m agentburn
```

Differences from the installed app:

- same data and settings folders as the installed app: `AGENT_BURN_DATA` sets another one. The old dev folder
  `~/.local/share/agent-burn-win-dev` is not carried over;
- no start at login (no installed exe to launch);
- the log also goes to stderr; Diagnostics shows "development version" and the CLI expected by `cli.env`;
- the shared QML files are read again from `shared/` at every launch (copy prepared in the cache): a change is
  picked up at the next launch;
- `AGENT_BURN_FAKE_DIR` outside the selftest is reported in the log;
- no update check: the updater only runs in a frozen Windows build. `AGENT_BURN_UPDATE_URL=<url>` (tests, an
  address on this machine only) points it at a fake GitHub instead of the real one: see
  [In-app update](#in-app-update-windows).

## Tests

On Linux, this function (bash or zsh) keeps the tests out of the user's graphical session and D-Bus session:

```sh
t() { env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 dbus-run-session -- "$@"; }
```

| What | Command | In CI |
|---|---|---|
| Unit tests | `t python -m unittest discover -s tests -v` (from `app/`) | Linux, Windows, macOS (Apple Silicon, and Intel under Rosetta 2) |
| Core suite under the shim | `t python tests/run_burn_suite.py`, then with `BURN_TEST=corrupt` and `BURN_TEST=timeout` | Linux, macOS |
| Core suite under Quickshell | see below | no |
| Upstream tracking | `python3 -I scripts/test_agent_burn_upstream.py` (from the root) | Linux; the check that needs the real CLI (`~/.local/bin/agent-burn`, skipped without it) runs in the packages job, with the CLI that job has just built |
| License tools (crate notices, `.rpm` license) | `python3 -m unittest discover -s .` (from `tools/`) | Linux |
| Selftest | see below | Linux (Xvfb), and on every frozen build |
| Linux packages | `linux/smoke-local.sh IMAGE` | 7 distros |
| Windows installer | `windows/smoke.ps1` | Windows x64 |
| macOS zip | `mac/smoke.sh ZIP` | macOS (Apple Silicon, and Intel under Rosetta 2) |

On macOS, no D-Bus: `QT_QPA_PLATFORM=offscreen` before the same commands (`PYTHONDONTWRITEBYTECODE=1` too).

### Unit tests

Fake CLI, startup (render loop, single instance and its lock, window size on a small screen, closing with or
without a system tray), popover (keyboard scrolling), icon and menu (system tray appearing or disappearing),
cached QML copy, settings (BOM, deeply nested JSON) and Settings window (Enter, arrows, visible focus, contrast,
two-step reset), log and redaction, diagnostics, folders (macOS ones with a simulated platform), Linux, Windows (fake
registry) and macOS (LaunchAgent in a temporary home) autostart, macOS icon clicks, shim (environment, stderr, current
directory, log, waiting for runs on close, idle polling), check of the selftest captures, in-app
update (fake GitHub on 127.0.0.1: see [In-app update](#in-app-update-windows)). They set `QT_QPA_PLATFORM=offscreen`
and `QT_QUICK_BACKEND=software` themselves; on Windows, `python -m unittest discover -s tests -v` is enough
(the 8 tests for Linux or macOS alone are skipped there).

### Core suite (Burn.qml)

[`app/tests/burn-suite/shell.qml`](../app/tests/burn-suite/shell.qml) tests `Burn.qml` without a window, with a
fake CLI (`burn-suite/fake/`) that replays the fixtures and failures (code 1 or 2, unreadable JSON, stuck CLI,
light reading). It must give the same result under the shim and under Quickshell: that is the proof of the shim's
fidelity. Expected result: `RESULT: N ok, 0 failed`, where N is currently 342 (normal), 29 (`corrupt`) and 6
(`timeout`): a smaller N means that some steps did not run.

Under the shim, from `app/` (code 1 if a test fails):

```sh
t python tests/run_burn_suite.py
t env BURN_TEST=corrupt python tests/run_burn_suite.py   # unreadable persisted files
t env BURN_TEST=timeout python tests/run_burn_suite.py   # stuck CLI, timeout lowered to 10 s: about 20 s
t python tests/run_burn_suite.py <directory>   # another shell.qml; its Burn.qml replaces the repo's (mutants)
```

Under Quickshell 0.3.2, from `app/`, on a copy (qs works outside the repo, and its
disposable XDG directories leave the real bar's data untouched):

```sh
S=$PWD/tests/burn-suite
R=$(mktemp -d /tmp/abq.XXXX)   # short path: the qs IPC socket path ($R/quickshell/by-id/<id>/ipc.sock) is limited to 108 bytes
mkdir -p $R/suite $R/fake $R/data $R/state $R/cache $R/config
cp $S/shell.qml ../shared/Burn.qml $R/suite/   # Burn.qml from shared/, not the burn-suite link
python3 -I $S/fake/gen.py $R/fake
env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR=$R XDG_DATA_HOME=$R/data \
    XDG_STATE_HOME=$R/state XDG_CACHE_HOME=$R/cache XDG_CONFIG_HOME=$R/config AGENT_BURN_BIN=$R/fake/agent-burn \
    dbus-run-session -- timeout 60 qs -p $R/suite 2>&1 | grep -a 'RESULT\|FAIL'
```

qs exits with 0 even when tests fail: read the `RESULT` line. Same variants with `BURN_TEST=corrupt`
and `BURN_TEST=timeout`. The qs warnings about Wayland, idle or portals
come from the environment without a screen.

The suite runs on Linux and macOS, not on Windows: the cp1252 console garbles its messages (seen under Wine).

### Selftest

`python -m agentburn --selftest DIR` renders the icon (16, 24, 32 px), the popover (Claude and General tabs), the
dashboard (All agents, Claude) and the 4 Settings sections, with the Codex tabs and page when the fixtures have
Codex. It writes the PNGs, `agent-burn.log` and `selftest.json`
(`ok`, `qmlErrors`, `warnings`, `captureErrors`, `dataLoaded`, `cliError`), and exits with 0 only if everything is
clean: data loaded, no QML warning, no CLI error, no capture that is empty, of a single color or of the wrong
size. It does not notice a missing icon font: look at the PNGs.

It needs OpenGL (software rendering ignores masks and shadows): under Xvfb like CI, in a desktop session
(offscreen rendering) or in a nested session. On Windows and macOS, it renders on screen (Direct3D, Metal: the
offscreen platform has no native window there), for a few seconds: do not click on it.
`AGENT_BURN_SELFTEST_AUTOSTART=on` (or `off`) also sets start at login at the end, through the Settings singleton as
the switch does, and `selftest.json` gives the state read back (`autostart`): `mac/smoke.sh` uses it, in a throwaway
HOME; elsewhere it would change the real start at login.

```sh
cd app
AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures AGENT_BURN_BIN=$PWD/tests/fake-agent-burn AGENT_BURN_DATA=/tmp/ab-selftest-data \
    xvfb-run -a -s '-screen 0 1920x1080x24' dbus-run-session -- python -m agentburn --selftest /tmp/ab-shots
```

Without OpenGL: `QT_QUICK_BACKEND=software` (passes, without shadows or the logo mask). With Codex:
`AGENT_BURN_FAKE_DIR=$PWD/../tests/fixtures/codex`. The builds run the same selftest on the frozen app, the exe
itself acting as the fake CLI (`AGENT_BURN_BIN` = the exe).

Offscreen (`QT_QPA_PLATFORM=offscreen`, the selftest default on Linux), the app keeps Qt's threaded render loop:
the basic loop, the one the app uses on Linux, loses the top of the popover card in the capture there. Under xcb
(`QT_QPA_PLATFORM=xcb`, the OpenGL selftest of the builds) or Wayland, it uses the basic loop like the app.

### Linux packages in a container

After a build (see below), for each image:

```sh
linux/smoke-local.sh docker.io/library/debian:13   # DIST = dist/linux by default
```

CI images: `ubuntu:22.04`, `ubuntu:24.04`, `debian:12`, `debian:13`, `fedora:44`,
`archlinux:latest`, `opensuse/tumbleweed` (locally: `docker.io/library/…`,
`registry.fedoraproject.org/fedora:44`, `registry.opensuse.org/opensuse/tumbleweed:latest`).
[`linux/smoke.sh`](../linux/smoke.sh) checks `SHA256SUMS`, installs the native package without its recommended
packages (Arch: the archive in `/opt` and `/usr/local`), checks the `PATH`, the launcher, the icons, AppStream, the
`/usr/share/doc/agent-burn-desktop/copyright` file (Debian, Ubuntu) and `--version` of the bundled CLI, resolves
every library of the bundle with `ldd` (`find` installed on openSUSE, whose image lacks it; failure without it),
runs the selftest of the installed app (software rendering, then Mesa OpenGL under Xvfb), uninstalls and checks
that no file is left. On Arch, it also tries the AppImage (`APPIMAGE_EXTRACT_AND_RUN=1`). Logs and captures:
`dist/linux/smoke-<distro>-<version>/` (in CI, `smoke-<n>` artifact on failure).

### Windows installer: `smoke.ps1`

```powershell
pwsh -File windows\smoke.ps1 -Setup <...\AgentBurn-Setup-<ver>-x64.exe> -Portable <...\AgentBurn-portable-<ver>-x64.zip>
```

It requires a machine without Agent Burn (installation, process, autostart or `%APPDATA%\AgentBurn`)
and refuses otherwise: it installs, then uninstalls for good. Made for CI runners or a disposable virtual
machine. Checks: silent installation (files, shortcuts, `Run` value, uninstall key), the same installer run
again the way the app runs an update with start at login off (`/relaunch=1` starts the app, which a silent
installation without it does not; `/MERGETASKS=!autostart` leaves the `Run` value out), selftest of the installed
exe, tray mode for 10 s, a 2nd launch that exits with 0, uninstallation while the app runs (folder, shortcuts,
`Run` and `StartupApproved` values, cache and logs gone, `%APPDATA%\AgentBurn` kept), then selftest of the
portable zip. Outputs in `dist/smoke/` (in CI, `selftest-windows-<arch>` artifact, without the extracted copy of
the zip). It runs in CI, on the `windows-2025` runner (Windows Server 2025), never on a desktop Windows; before
CI, its logic had been replayed in Python under Wine (43 checks out of 43, plus an update over an old
installation and the refusal of the arm64 installer on x64).

### macOS app: `smoke.sh`

```sh
bash mac/smoke.sh dist/mac-arm64/AgentBurn-<ver>-macos-arm64.zip   # or the x64 zip, under Rosetta 2 on Apple Silicon
```

It works in a throwaway HOME (`/tmp/abhome.*`, short for the single-instance socket), never the real one, and
checks the zip the way a user gets it: unzipped with `ditto`, `Agent Burn.app` at its top, Info.plist (identifier,
executable, version, `LSUIElement`), `codesign --verify --deep --strict`, no App Sandbox entitlement, the
architecture of the exe and of the bundled CLI (`lipo -archs`), the CLI's `--version`, `build-info.json`; then a
selftest of the unzipped app that turns start at login on (the LaunchAgent: label, `ProgramArguments` = the exe,
`RunAtLoad`) and one that turns it off (plist gone), both also checking that the app read its `build-info.json`
(version and target in its log); then menu bar mode for 10 s and a 2nd launch that hands over to it (code 0, the
1st one still running, "opened the dashboard of the running instance" in the log). Outputs in
`dist/mac-<arch>/smoke/` (in CI, `selftest-macos-<arch>` artifact, without the unzipped app). It has run only on
GitHub's `macos-15` runner, never on a real Mac.

### In-app update (Windows)

[`updater.py`](../app/agentburn/updater.py) only runs in a frozen Windows build.
[`test_updater.py`](../app/tests/test_updater.py) makes one through the constructor (build target `windows-x64`,
Inno's `unins000.exe` next to the exe or not) and serves a fake GitHub from `127.0.0.1` through
`AGENT_BURN_UPDATE_URL`, which replaces both GitHub addresses:
`<url>/releases/latest` (the GitHub release JSON: `tag_name`, `draft`, `prerelease`, `html_url`, `assets` with
`name`, `size`, `browser_download_url`), `<url>/releases/download/desktop-v<ver>/<file>` and
`<url>/releases/tag/desktop-v<ver>`. The installer never runs there (`QProcess` and `QCoreApplication` patched):
the test checks its exact command line. `smoke.ps1` runs the real installer with that command line.

End to end, by hand, on a Windows machine or VM: install version X, then in a folder `D` put
`releases/latest` (that JSON for version Y > X, addresses under `http://127.0.0.1:8000`),
`releases/download/desktop-v<Y>/AgentBurn-Setup-<Y>-x64.exe` and its `SHA256SUMS` next to it; serve `D` with
`python -m http.server 8000 -d D`, start version X with `AGENT_BURN_UPDATE_URL=http://127.0.0.1:8000` set,
then Settings → About → Check for updates, Update now: the app quits, the installer runs, version Y starts.
The installer part was also tried under Wine with Inno Setup 6.7.3, on a fake bundle: `/relaunch=1` runs the
last `[Run]` entry, a silent installation without it does not, and without `/MERGETASKS=!autostart` the
remembered `autostart` task writes the `Run` value back.

### Under Wine

Useful for a first rough pass, not a Windows verification (the development Wine lab is not in the repo):

- working: Windows Python 3.12 with PySide6 6.12 (unit tests), PyInstaller, ISCC, the installer
  (installation, update, uninstallation) and the selftest of the frozen app;
- Wine does not pass on the Unix `QT_*` variables: set them on the Windows side (`cmd /c "set QT_QPA_PLATFORM=offscreen&& …"`);
- PowerShell 7 does not run under Wine: `build.ps1` and `smoke.ps1` cannot be tried there;
- no MSVC toolchain: the lab's CLI was cross-compiled (`x86_64-pc-windows-gnu`), unlike the one in the builds;
- Wine does not apply the dark title bar and tells nothing about SmartScreen, Defender or the real system
  tray.

## Building

### Linux: `linux/build-local.sh`

```sh
linux/build-local.sh                       # podman, python:3.12-slim-bookworm image, network
SKIP_CLI=1 linux/build-local.sh            # reuses the CLI in build/cli-linux as is
AB_CACHE=/absolute/path linux/build-local.sh   # cargo, rustup and pip caches in this directory
```

The wrapper runs [`linux/build.sh`](../linux/build.sh) in the container, as root, with the repo mounted. The
image is pinned by its digest, the same as in CI (`--pull=missing`: downloaded once); to bump it, change the
digest in both places. The cargo, rustup and pip caches go into `AB_CACHE` (by default the `agent-burn-build-cache`
podman volume). The wrapper also passes the repo's commit (`GITHUB_SHA`), which `build-info.json` records: from a
worktree, the mounted `.git` points outside the container and `build.sh` would not read it.
`build.sh` refuses to run anywhere but in Debian 12: the bundle takes the glibc of bookworm (floor 2.35) and so
runs on newer distros. Without `CARGO_HOME` or `RUSTUP_HOME`, it uses `$HOME/.cargo` and
`$HOME/.rustup` (in CI, the `$HOME/.cargo` registry is cached along with the CLI).

Steps:

1. reads `AB_REV`, `AB_VER` (`cli.env`) and `__version__` (`app/agentburn/__init__.py`);
2. CLI (only if it needs compiling: gcc and musl are installed only then): shallow clone of upstream
   at `AB_REV`, Rust from its `rust-toolchain.toml` (pinned rustup-init),
   static `x86_64-unknown-linux-musl` binary (`gnu` fallback if upstream breaks this build), `--version` == `AB_VER`,
   license and crate notices; cached in `build/cli-linux/` (key: `AB_REV`);
3. JetBrainsMono Nerd Font v3.4.0 fonts checked by sha256;
4. venv from `app/requirements.lock` (versions and sha256, `--require-hashes`), recreated when it changes;
5. icons, `licenses/` (including `QT-THIRD-PARTY.txt` and `LICENSE-Python.txt` completed with the software
   incorporated in CPython), `build-info.json`, then the PyInstaller bundle ([`agentburn.spec`](../agentburn.spec),
   without the unused image plugins); stops if Qt, PySide6 or Python are no longer the ones the notices describe
   (see [Bumping Qt, PySide6, Python or the AppImage runtime](#bumping-qt-pyside6-python-or-the-appimage-runtime));
6. rejects a bundle that needs a library neither bundled nor declared in [`linux/nfpm.yaml`](../linux/nfpm.yaml);
   computes the minimum glibc;
7. selftests of the frozen app: software rendering, then OpenGL under Xvfb;
8. `.deb` (with `/usr/share/doc/agent-burn-desktop/copyright`) and `.rpm` (License field: the SPDX expression of
   the whole content, computed by [`tools/package_license.py`](../tools/package_license.py) from the notices),
   archive, AppImage (pinned appimagetool and runtime; `NOTICE-AppImage-runtime.txt` in the AppImage
   only), `SHA256SUMS`.

Outputs in `dist/linux/`: `agent-burn-desktop-<ver>-x86_64.tar.gz`, `…-x86_64.AppImage`,
`agent-burn-desktop_<ver>_amd64.deb`, `agent-burn-desktop-<ver>-1.x86_64.rpm`, `SHA256SUMS`,
`selftest/{software,opengl}/`. Times measured on the development workstation: about 3 min from cold, 80 s of it
for the CLI, 1 min 30 s with the CLI cached. `build/`, `dist/` and `app/fonts/` are ignored by git.

### Windows: `build.ps1`

Windows 10/11 with PowerShell 7.4+ (`winget install Microsoft.PowerShell`), Python 3.13 of the same
architecture as the target in the `PATH`, Git, Rust via [rustup](https://rustup.rs) (MSVC toolchain, Visual
Studio C++ Build Tools) and [Inno Setup](https://jrsoftware.org/isdl.php) 6.3+ (`iscc` in the `PATH`, or its
default folder). Network: GitHub, crates.io, PyPI.

```powershell
pwsh -File build.ps1               # x64: CLI, fonts, licenses, bundle, selftest, zip, installer
pwsh -File build.ps1 -Arch arm64   # on an ARM64 machine, with an ARM64 Python
pwsh -File build.ps1 -SkipCli      # reuses build\cli as is (iterations without Rust)
```

- `-Arch` (`x64` by default, lowercase) picks the Rust target; the venv's Python must be of the same
  architecture (PyInstaller freezes its own), otherwise the script stops: delete `.venv` and rerun. The venv is
  filled from `app/requirements.lock` (`--require-hashes`).
- The CLI is compiled from a shallow clone of upstream at `AB_REV`, in `%TEMP%\agent-burn-cli` (deleted
  afterwards), with a static CRT; the `build\cli\rev` marker (`<AB_REV> <target>`) avoids recompiling it.
- Before PyInstaller: `build\bundle-extra\licenses\` (including `QT-THIRD-PARTY.txt`, and `LICENSE-Python.txt`
  completed with the software incorporated in CPython, missing from the python.org `LICENSE.txt`), `build-info.json`
  and the exe's version resource; stops if the notices do not describe the Qt, PySide6 and Python of the venv;
  after PyInstaller: the build fails if one of them is missing from the bundle.
- The selftest of the frozen app runs for a few seconds before the zip and the installer: do not click on it.
  It fails on the slightest error or failed capture (see `dist\selftest\selftest.json` and `stderr.txt`, in
  UTF-8 like the log).
- Rerunnable: the venv, fonts and CLI already made are reused; the bundle, zip and installer are overwritten.
- The log marks each step with the elapsed time (`== [Ns] …`, like `build.sh`); from Inno Setup, it keeps
  the compiler version, its warnings and the compile time.

Outputs in `dist\`: `AgentBurn\` (bundle), `AgentBurn-portable-<ver>-<arch>.zip`,
`AgentBurn-Setup-<ver>-<arch>.exe`, `selftest\`. [`installer.iss`](../installer.iss) is only compiled through
`build.ps1` (`/DAppVersion` and `/DArch` required). Its `[InstallDelete]` lines empty the subfolders of the
bundle (files from a previous version) only over an installation of Agent Burn (`OwnInstall`:
`AgentBurn.exe` and `unins000.dat` present in `{app}`), and the folder choice is disabled
(`DisableDirPage`): an existing folder picked by hand would be emptied at the next update. `build.ps1` does not
run under Wine (no PowerShell 7): it has only run in CI, on the `windows-2025` runner.

### macOS: `mac/build.sh`

```sh
bash mac/build.sh          # Apple Silicon app: arm64 (default)
bash mac/build.sh x64      # Intel app; on Apple Silicon, with Rosetta 2 and an x86_64 or universal2 python3
SKIP_CLI=1 bash mac/build.sh   # reuses build/cli-mac-<arch> as is
```

A Mac with the Xcode command line tools, rustup, and Python 3.13 as `python3` (setup-python in CI; for x64, an
x86_64 one under Rosetta 2). Steps, `bash` 3.2 compatible:

1. CLI (only if `build/cli-mac-<arch>/rev` is not `AB_REV`): shallow clone of upstream, Rust from its
   `rust-toolchain.toml`, `cargo build --target aarch64-apple-darwin` or `x86_64-apple-darwin` (cross-compiled on
   Apple Silicon), `--version` == `AB_VER`, `lipo -archs` == the build's architecture, license and crate notices;
2. the JetBrainsMono Nerd Font fonts, checked by sha256 as on Linux;
3. venv from `app/requirements.lock` (`--require-hashes`), every Python command run through `arch -arm64` or
   `arch -x86_64`: PyInstaller freezes the architecture its Python runs as, and thins the universal2 wheels to it;
4. `.icns` from `assets/agent-burn.png` (`sips`, `iconutil`; 256 px source, no 512 px sizes), `licenses/` and
   `build-info.json` (target `macos-arm64` or `macos-x64`) as on Linux;
5. PyInstaller, then the checks: CLI in `Contents/Frameworks/bin/`, everything from `build/bundle-extra` in
   `Contents/Resources`, every Mach-O file of the bundle of the build's architecture only;
6. ad hoc signature of the whole bundle (`codesign --force --deep -s -`), then `codesign --verify --deep --strict`;
7. selftest of the frozen app, on screen, HOME in `build/mac-<arch>/selftest-home`;
8. zip with `ditto -c -k --sequesterRsrc --keepParent`, `Agent Burn.app` at its top.

[`agentburn.spec`](../agentburn.spec) makes the `.app` with `BUNDLE`: `Contents/MacOS/AgentBurn`, the binaries
(the CLI too) in `Contents/Frameworks` (`sys._MEIPASS`), the data in `Contents/Resources` with links from
`Contents/Frameworks`; Info.plist: `io.github.magikdidi24.AgentBurn`, `CFBundleShortVersionString` and
`CFBundleVersion` = `__version__`, `LSUIElement` (menu bar app), `LSMinimumSystemVersion` 14.0 (the PySide6 6.12
wheels); not sandboxed, no entitlements. Outputs in `dist/mac-<arch>/`: `AgentBurn-<ver>-macos-<arch>.zip`,
`selftest/`, `selftest.log`. It has run only on GitHub's `macos-15` runner (arm64), the x64 build under Rosetta 2.

### Bumping Qt, PySide6, Python or the AppImage runtime

The notices in [`tools/licenses/`](../tools/licenses/) describe precise versions, given by their first
line: `QT-THIRD-PARTY.txt` (Qt and PySide6), `PYTHON-<X.Y>-THIRD-PARTY.txt` (one per shipped minor version of
Python: 3.12 on Linux, 3.13 on Windows and macOS), `NOTICE-AppImage-runtime.txt` (`RUNTIME` in `build.sh`).
The build scripts stop as long as they no longer match (or the notice for their Python is
missing). After a change of PySide6 (and so of Qt) or of Python, regenerate the lock (see
[Setup](#setup)), then redo the notice concerned; after a change of `RUNTIME`, redo the runtime
one. The scripts that produced them are not in the repo. Sources used: the `qt_attribution.json` files and the
license files of qtbase, qtdeclarative, qtwayland and pyside-setup at the version tag, chosen from the libraries
actually shipped; the "Licenses and Acknowledgements for Incorporated Software" section of CPython's
`Doc/license.rst`, plus the HACL* notice; the sources of type2-runtime and of the libraries it links.

## Release

1. Bump `__version__` in [`app/agentburn/__init__.py`](../app/agentburn/__init__.py), in the `X.Y.Z` format
   (digits only: Windows version resources).
2. Commit, push, and wait for a green CI run on that commit.
3. Tag: `git tag desktop-v<ver> && git push origin desktop-v<ver>`.
4. CI redoes everything, the CLI included: on a tag, it is always compiled from the upstream sources, never
   taken from the cache. Then the "Release (draft)" job creates a draft release titled "Agent Burn <version>":
   Linux packages (AppImage, `.deb`, `.rpm`, archive), Windows x64 installer and zip, the macOS zips (Apple
   Silicon and Intel), one `SHA256SUMS`. Windows ARM64 is never in it. It refuses a `desktop-vX.Y.Z` tag whose
   `.deb`, x64 installer and macOS zips are not version X.Y.Z (different `__version__`): error, no release.
5. Before publishing, by hand:
   - `sha256sum -c --ignore-missing SHA256SUMS` on the downloaded files;
   - install on a real Windows: SmartScreen, icon, popover next to the icon, Settings → Diagnostics (app, CLI
     and expected CLI versions);
   - install a package on a real Linux desktop (KDE, or GNOME with AppIndicator);
   - on a real Mac (never done so far): Gatekeeper and "Open Anyway", the menu bar icon and its clicks (left,
     right, Control-click), the popover under it, start at login after a restart, the Keychain question;
   - notes: changes, CLI version (`AB_VER`), known limitations;
   - publish the draft. It becomes the latest release: installed Windows apps offer it within a day, and the
     portable copies point to its page (see [In-app update](#in-app-update-windows)). Version 1.0.0 has no
     updater: its users install the next version by hand.
6. To redo a release: first delete the draft (`gh release delete desktop-v<ver>`), then rerun
   the tag's run.

The release date in the AppStream metadata is the build day.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml), "Agent Burn (desktop)". First complete run on
2026-10-25, just before the app got its own repository: all jobs green (the release, without a tag, skipped),
ARM64 never launched. The file passes actionlint (with shellcheck) with no errors.

Triggers: push on any branch, except when it only touches `*.md` files or `docs/`; pull request, same
rule; `desktop-v*` tag (GitHub does not apply path filters to tags: everything runs, release included);
manual run with an `arm64` checkbox ("Run workflow" button on the Actions tab, or
`gh workflow run ci.yml --ref <branch> -f arm64=true`). A new push cancels the run in progress for the same
branch, tag or pull request; a push and the pull request of its branch each get their own run.

| Job | Machine | Content | Artifacts |
|---|---|---|---|
| Tests | `ubuntu-24.04` | Qt libraries, Xvfb and Mesa; dependencies from the hashed lock; unit tests; license tools (`tools/`); core suite (normal, corrupted, stuck CLI); upstream tracking; selftest under Xvfb | `selftest-linux-dev` (7 days) |
| Linux (packages) | `python:3.12-slim-bookworm` container, pinned by digest | `linux/build.sh`, then the upstream tracking check with the built CLI | `agent-burn-desktop-linux` (30 days) |
| Packages on … | 7 distro containers (tags, no digest: up-to-date distros) | `linux/smoke.sh` on the artifact downloaded into `dist-in/` | `smoke-<n>` on failure (7 days): `smoke.sh` logs and captures |
| Windows x64 | `windows-2025` (pinned image: `windows-latest` would change it without warning) | Python 3.13; `.venv` venv filled from the hashed lock (the `build.ps1` one), unit tests on a real Windows (UTF-8 output, 5 min at most), Inno Setup (choco 6.7.1 if missing), `build.ps1`, `smoke.ps1` | `agent-burn-desktop-windows-x64` (30 days, uploaded before `smoke.ps1`), `selftest-windows-x64` (7 days, as soon as the build has run: build selftest and `smoke.ps1` outputs, without the extracted copy of the zip) |
| Windows ARM64 (experimental) | `windows-11-arm` | like x64; only on a manual run with `arm64`, its failure does not fail the run | same, `-arm64` |
| macOS Apple Silicon, macOS Intel (Rosetta 2) | `macos-15` (arm64) for both | Python 3.13 (x86_64 for Intel, after Rosetta 2 if the image lacks it); unit tests, core suite (normal, corrupted, stuck CLI) offscreen; `mac/build.sh arm64` or `x64`, `mac/smoke.sh` | `agent-burn-desktop-macos-arm64` and `-x64` (30 days), `selftest-macos-<arch>` (7 days: build selftest, `smoke.sh` outputs without the unzipped app) |
| Release (draft) | `ubuntu-24.04` | `desktop-v*` tags only, after the packages, Windows and macOS: refuses a tag whose version is not the one of the packages, `SHA256SUMS`, `gh release create --draft --verify-tag` | draft release |

- Caches: CLI per `AB_REV` (and per architecture on Windows and macOS) with the cargo registry, saved as soon as it is
  compiled even if the rest fails, never reused by a release tag; extracted fonts (`app/fonts`, checked again
  by sha256 on every build); pip for the Tests and Windows jobs (setup-python), keyed on the lock. No cache
  for the Rust toolchain: rustup installs the upstream one on every CLI compilation (about 15 s), and a cache
  per revision would never be read again. A cache is only visible to its branch and to `main`: merging the workflow
  into `main` seeds them for all branches.
- Hygiene: actions pinned by SHA (version in a comment), `persist-credentials: false`, `contents: read`
  permissions (except the release), a maximum timeout on every job, `pull_request` and never
  `pull_request_target` (a pull request from a fork has neither secrets nor write access), runs grouped by pull
  request number or by full ref (the one of a fork cannot cancel a run of the repo).
- `build-info.json` of the Linux build: on a pull request, the head commit of the PR (`PR_HEAD_SHA`), not the
  temporary merge commit that CI builds.
- Not in CI: the core suite under Quickshell, the core suite on Windows, a QML lint.
- Durations of the first complete run: tests 3 min 40 s (2 min of it for the "stuck CLI" suite, 20 s since),
  Linux packages 2 min 30 s, Windows x64 10 min, each distro about 1 min, so 15 min end to end; plus 5 to
  12 min when the CLI is recompiled (estimate). The macOS jobs, run in parallel since: about 7 min for Apple
  Silicon and 10 min for Intel under Rosetta 2, 2 min of each for the CLI when it is compiled. Public repo:
  GitHub does not bill the minutes of its standard runners. The package artifacts (about 300 MB for Linux,
  110 MB for Windows and 110 MB for the two macOS zips per run) are kept 30 days,
  uploaded without recompression (`compression-level: 0`): between two releases, that is where users
  find them (see the README).

## Conventions

- Language: English for code comments, UI text, docs and commit messages; commit messages follow the
  Conventional Commits format (`feat(desktop): …`, `fix(burn): …`, `build: …`, `ci: …`, `test: …`, `docs: …`).
- Shared QML (`shared/`): must run as is under Quickshell 0.3.2 (the author's Quickshell bar keeps a copy of it
  synced from this repo) and under PySide6 6.12 through the shim. Only the symbols of the [platform contract](ARCHITECTURE.md#platform-contract),
  no `QtQuick.Controls`. An additional shared file goes into `runtime.SHARED` (also read by
  `agentburn.spec`), otherwise "X is not a type". Check under both hosts: core suite, selftest, and a
  render under qs.
- Screen readers, shared QML: a new `Txt` that serves as the label of a `BurnButton` or of a field, or that
  has its own `Accessible.name`, gets `spoken: false`, otherwise it is announced twice when
  `Burn.accessibleText` is true (see [the platform contract](ARCHITECTURE.md#platform-contract)).
- Nerd Font glyphs (Unicode Private Use Area): in the QML and the Python, always as a `\uXXXX` escape, never
  the raw character, which editing tools lose or alter. Check (no exceptions):
  `grep -nP '[\x{E000}-\x{F8FF}]' shared/*.qml app/qml/*.qml app/agentburn/*.py`.
- Text coming from the CLI is shown as `Text.PlainText`; processes are launched with argv; writes are atomic.
- A deliberate shortcut carries a `shortcut: <limit>, <when to revisit>` comment.
- Platform-specific code goes in `platform_win.py`, `platform_linux.py` or `platform_mac.py`, directories in
  `paths.py` only.
- To keep in sync: the `io.github.magikdidi24.AgentBurn` id (`.desktop` file, icons, AppStream,
  `setDesktopFileName`, autostart; on macOS the bundle identifier in `agentburn.spec` and the LaunchAgent label in
  `platform_mac.py`, both checked by `mac/smoke.sh`), the `AgentBurn` application name (`WM_CLASS` on X11 ↔
  `StartupWMClass`), the `AgentBurn.exe`, `agent-burn-desktop` and `Agent Burn.app/Contents/MacOS/AgentBurn`
  executables, the CLI in `bin/` of the bundle (`sys._MEIPASS`), the `build-info.json` keys (`appVersion`,
  `cliRev`, `cliVersion`, `target`, `builtAt`) written by the three build scripts (the Windows `target` values,
  `windows-x64` and `windows-arm64`, also turn the updater on: `updater.ARCHS`; the macOS ones are `macos-arm64` and
  `macos-x64`), the `desktop-v<ver>` tag and the `AgentBurn-Setup-<ver>-<arch>.exe` and `SHA256SUMS` release files
  (`build.ps1`, `installer.iss`, the release job, `updater.py`), the `AgentBurn-<ver>-macos-<arch>.zip` release files
  (`mac/build.sh`, `mac/smoke.sh`, the release job), the `/relaunch=1` parameter (`updater.py`, `installer.iss`,
  `smoke.ps1`), the digest of the build image (workflow and `linux/build-local.sh`), the sums of the extracted
  JetBrainsMono Nerd Font fonts (`linux/build.sh`, `build.ps1` and `mac/build.sh`) and the version in their cache key
  (workflow).

## ARM64

- Windows ARM64: `build.ps1 -Arch arm64` on an ARM64 machine with an ARM64 Python (no cross-compilation).
  CI builds it on `windows-11-arm`, on a manual run only, as experimental and outside the
  releases; never run to date. The arm64 installer has only been
  compiled under Wine; PyPI does publish the `win_arm64` wheels of PySide6 6.12 and PyInstaller (seen during
  the audit). Nothing has run on ARM hardware.
- The x64 installer accepts Windows 11 ARM, which emulates it: never tried.
- Linux ARM64: no build (`build.sh`, nfpm and the AppImage target x86_64).
- macOS: two single-architecture apps, arm64 and x64, both built on the arm64 `macos-15` runner; the x64 one runs
  there only under Rosetta 2, never on an Intel Mac.
