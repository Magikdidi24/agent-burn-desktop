#!/usr/bin/env bash
# Builds Agent Burn for macOS (CI: "macos" job; Xcode command line tools, rustup, Python 3.13 as python3): Rust CLI,
# fonts, licenses, PyInstaller "Agent Burn.app" signed ad hoc, frozen app selftest, zip. One architecture per build:
# arm64 (Apple Silicon) or x64 (Intel, built on Apple Silicon under Rosetta 2 with an x86_64 or universal2 Python).
#   bash mac/build.sh [arm64|x64]      (SKIP_CLI=1: reuses build/cli-mac-<arch> as is)
# Outputs in dist/mac-<arch>/: AgentBurn-<version>-macos-<arch>.zip, selftest/. CLI cached in build/cli-mac-<arch>/
# (key: AB_REV), the rest in build/mac-<arch>/. Written for the bash 3.2 of macOS.
set -euo pipefail

step() { printf '\n== [%ss] %s\n' "$SECONDS" "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }
ARCH=${1:-arm64}
case $ARCH in
    arm64) MACH=arm64 TARGET=aarch64-apple-darwin ;;
    x64) MACH=x86_64 TARGET=x86_64-apple-darwin ;;
    *) die "usage: build.sh [arm64|x64]" ;;
esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
W=$HERE/build/mac-$ARCH CLI=$HERE/build/cli-mac-$ARCH OUT=$HERE/dist/mac-$ARCH T=$HERE/build/mac-$ARCH/tools
cd "$HERE"
export PYTHONDONTWRITEBYTECODE=1
fetch() {   # URL SHA256 FILE: downloaded once, verified on every build
    [ -f "$3" ] && echo "$2  $3" | shasum -a 256 -c --quiet >/dev/null 2>&1 && return
    curl -fsSLo "$3" "$1" && echo "$2  $3" | shasum -a 256 -c --quiet
}
if ! command -v timeout >/dev/null; then   # not in macOS; Perl is
    timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

[ "$(uname -s)" = Darwin ] || die "build.sh runs on a Mac, not $(uname -s)"
# PyInstaller freezes the architecture its Python runs as: forced, a universal2 Python would pick the machine's.
py() { arch -$MACH "$V/bin/python" "$@"; }

# CLI revision: cli.env, single source (AB_REV and AB_VER change together).
REV=$(sed -n 's/^AB_REV=\([0-9a-f]\{40\}\)$/\1/p' cli.env)
ABVER=$(sed -n 's/^AB_VER="\(.*\)"$/\1/p' cli.env)
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' app/agentburn/__init__.py)
[ -n "$REV" ] && [ -n "$ABVER" ] && [ -n "$VER" ] || die "AB_REV / AB_VER (cli.env) or __version__ (app) not found"
mkdir -p "$W" "$T"

build_cli() {
    local src=$W/cli-src rust
    command -v rustup >/dev/null || die "rustup not found (https://rustup.rs), or rerun with SKIP_CLI=1"
    rm -rf "$src" "$CLI" && mkdir -p "$CLI/bin"
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 https://github.com/Melvynx/agent-burn "$REV"
    git -C "$src" checkout -q FETCH_HEAD
    # Toolchain pinned by upstream at this revision (rust-toolchain.toml), without its dev components.
    rust=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$src/rust-toolchain.toml")
    [ -n "$rust" ] || die "upstream rust-toolchain.toml has no channel"
    export RUSTUP_TOOLCHAIN=$rust CARGO_TARGET_DIR=$W/cli-target
    rustup -q toolchain install --profile minimal "$rust" --target $TARGET
    (cd "$src/rust" && cargo build -q --release --locked -p agent-burn --bin agent-burn --target $TARGET)
    cp "$CARGO_TARGET_DIR/$TARGET/release/agent-burn" "$CLI/bin/"
    cp "$src/apps/agent-burn/LICENSE" "$CLI/LICENSE-agent-burn.txt"
    python3 tools/third_party_notices.py "$src" "$CLI/THIRD-PARTY-NOTICES.txt" --target $TARGET
    echo $TARGET > "$CLI/target"
    echo "$REV" > "$CLI/rev"   # last: marker of a complete cache
}

step "CLI $ABVER ($REV)"
if [ "${SKIP_CLI:-}" = 1 ]; then
    [ -x "$CLI/bin/agent-burn" ] || die "SKIP_CLI=1 but $CLI/bin/agent-burn missing"
    [ "$(cat "$CLI/rev" 2>/dev/null)" = "$REV" ] || echo "!! SKIP_CLI=1: CLI built for a revision other than $REV"
elif [ "$(cat "$CLI/rev" 2>/dev/null)" != "$REV" ] || [ ! -x "$CLI/bin/agent-burn" ]; then
    build_cli
fi
# AB_VER must describe this CLI: smoke.sh checks it in the zipped app.
[ "$("$CLI/bin/agent-burn" --version)" = "$ABVER" ] || die "the CLI does not answer “${ABVER}”: AB_REV and AB_VER disagree (cli.env)"
[ "$(lipo -archs "$CLI/bin/agent-burn")" = $MACH ] || die "$CLI/bin/agent-burn is $(lipo -archs "$CLI/bin/agent-burn"), not $MACH"
file -b "$CLI/bin/agent-burn"

step "JetBrainsMono Nerd Font v3.4.0 fonts (QML glyphs validated on this version)"
fonts_ok() {
    (cd app/fonts 2>/dev/null && shasum -a 256 -c --quiet >/dev/null 2>&1 <<'EOF'
0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9  JetBrainsMonoNerdFont-Regular.ttf
e82e27a7f37c9a0a13cc4e417503a149c6a0280586930772d2ebed803159c864  JetBrainsMonoNerdFont-Bold.ttf
30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad  OFL.txt
EOF
    )
}
if ! fonts_ok; then
    fetch https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.tar.xz \
        ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582 "$T/JetBrainsMono.tar.xz"
    mkdir -p app/fonts
    tar -xJf "$T/JetBrainsMono.tar.xz" -C app/fonts JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf OFL.txt
    fonts_ok || die "extracted fonts differ from the pinned ones"
fi

step "Python: venv, PySide6, PyInstaller"
V=$W/venv
# Hashed lock: versions and sha256 of the whole tree, PyInstaller included. Venv recreated when it changes: a removed
# package would otherwise stay in the venv (and the bundle).
if [ "$(cat "$V/stamp" 2>/dev/null)" != "$(cat app/requirements.lock)" ]; then
    rm -rf "$V" && arch -$MACH python3 -m venv "$V"
    py -m pip install -q --disable-pip-version-check --require-hashes -r app/requirements.lock
    cp app/requirements.lock "$V/stamp"
fi
py -c 'import platform, sysconfig; print("Python", platform.python_version(), platform.machine(), "for macOS",
    sysconfig.get_config_var("MACOSX_DEPLOYMENT_TARGET"), sysconfig.get_platform())'

step "Icon, licenses, build-info.json"
# .icns from the 256 px PNG, never upscaled: no 512 px sizes, Finder scales the largest one.
I=$W/AgentBurn.iconset
rm -rf "$I" && mkdir -p "$I"
for n in 16 32 128 256; do
    sips -z $n $n assets/agent-burn.png --out "$I/icon_${n}x${n}.png" >/dev/null
    [ $n = 256 ] || sips -z $((n * 2)) $((n * 2)) assets/agent-burn.png --out "$I/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$I" -o "$W/AgentBurn.icns"   # path read by agentburn.spec
X=$HERE/build/bundle-extra   # copied into the bundle by agentburn.spec (Contents/Resources)
rm -rf "$X" && mkdir -p "$X/licenses"
cp "$CLI/LICENSE-agent-burn.txt" "$CLI/THIRD-PARTY-NOTICES.txt" tools/licenses/LGPL-3.0.txt tools/licenses/GPL-3.0.txt "$X/licenses/"
cp LICENSE "$X/licenses/LICENSE-agent-burn-desktop.txt"
cp app/fonts/OFL.txt "$X/licenses/LICENSE-JetBrainsMono-NerdFont.txt"
# Without .git (CI checkout without git): the CI commit, a PR's head commit rather than its merge commit.
COMMIT=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo "${PR_HEAD_SHA:-${GITHUB_SHA:-unknown}}")
py - "$X" "$VER" "$COMMIT" "$REV" "$ABVER" "$(cat "$CLI/target")" "macos-$ARCH" <<'EOF'
import datetime, json, platform, sys, sysconfig
from pathlib import Path
import PySide6, PyInstaller
from PySide6.QtCore import qVersion
out, version, commit, rev, cli_version, cli_target, target = sys.argv[1:]
notice = Path("tools/licenses/NOTICE-Qt-PySide6.txt").read_text(encoding="utf-8")
Path(out, "licenses", "NOTICE-Qt-PySide6.txt").write_text(
    notice.replace("@QT@", qVersion()).replace("@PYSIDE6@", PySide6.__version__), encoding="utf-8")
# Qt third-party components and software incorporated in Python: collected for these versions, redo when they change.
qt_third = Path("tools/licenses/QT-THIRD-PARTY.txt").read_text(encoding="utf-8")
py_notice = "tools/licenses/PYTHON-%d.%d-THIRD-PARTY.txt" % sys.version_info[:2]   # one per shipped minor version
py_third = Path(py_notice).read_text(encoding="utf-8")
if not qt_third.startswith(f"Qt {qVersion()} and PySide6 {PySide6.__version__}:"):
    sys.exit(f"tools/licenses/QT-THIRD-PARTY.txt does not describe Qt {qVersion()} and PySide6 {PySide6.__version__}: redo it")
if not py_third.startswith("Python %d.%d:" % sys.version_info[:2]):
    sys.exit(f"{py_notice} does not describe Python {platform.python_version()}: redo it")
Path(out, "licenses", "QT-THIRD-PARTY.txt").write_text(qt_third, encoding="utf-8")
# Python's LICENSE.txt without the incorporated software (Doc/license.rst): appended after it.
py_license = Path(sysconfig.get_path("stdlib"), "LICENSE.txt").read_text(encoding="utf-8")
if "Licenses and Acknowledgements for Incorporated Software" not in py_license:
    py_license += "\n\n" + py_third
Path(out, "licenses", "LICENSE-Python.txt").write_text(py_license, encoding="utf-8")
Path(out, "build-info.json").write_text(json.dumps({
    "appVersion": version, "commit": commit, "target": target,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cliRev": rev, "cliVersion": cli_version, "cliTarget": cli_target,
    "python": platform.python_version(), "pyside6": PySide6.__version__, "qt": qVersion(),
    "pyinstaller": PyInstaller.__version__}, indent=2) + "\n", encoding="utf-8")
EOF

step "PyInstaller bundle"
rm -rf "$W/dist"
py -m PyInstaller --noconfirm --log-level WARN --workpath "$W/pyinstaller" --distpath "$W/dist" agentburn.spec
APP="$W/dist/Agent Burn.app"
EXE="$APP/Contents/MacOS/AgentBurn"
# Contract with agentburn.spec: without it, a bundle without CLI, licenses or build-info.json would still ship.
[ -x "$APP/Contents/Frameworks/bin/agent-burn" ] || die "agentburn.spec did not pick up $CLI: no Contents/Frameworks/bin/agent-burn"
(cd "$X" && find . -type f) | while read -r f; do
    [ -f "$APP/Contents/Resources/$f" ] || die "agentburn.spec did not pick up build/bundle-extra: $f missing from Contents/Resources"
done
# Thin bundle: every Mach-O file of this architecture only (PyInstaller thins the universal2 wheels).
others=$(find "$APP" -type f | while read -r f; do
    a=$(lipo -archs "$f" 2>/dev/null) || continue   # not a Mach-O file
    [ "$a" = $MACH ] || echo "$f ($a)"
done)
[ -z "$others" ] || die "not $MACH only: $others"
echo "bundle: $(du -sh "$APP" | cut -f1), $MACH only"

step "Ad hoc signature"
# Signed again as a whole, nested code included: Apple Silicon runs nothing unsigned, a signature from Apple
# (notarization) needs a paid account.
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

step "Frozen app selftest"
# The exe serves the fixtures itself (fake CLI); data, cache and start at login in build/, never in the real HOME.
rm -rf "$OUT" "$W/selftest-home" && mkdir -p "$OUT"
HOME="$W/selftest-home" AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$EXE" AGENT_BURN_DATA="$W/selftest-home/data" \
    timeout 300 "$EXE" --selftest "$OUT/selftest" >"$OUT/selftest.log" 2>&1 ||
    die "selftest failed (code $?): dist/mac-$ARCH/selftest.log and dist/mac-$ARCH/selftest/selftest.json"

step "Zip"
ZIP=$OUT/AgentBurn-$VER-macos-$ARCH.zip
# ditto: symbolic links, permissions and signature kept, "Agent Burn.app" at the top of the zip.
(cd "$W/dist" && ditto -c -k --sequesterRsrc --keepParent "Agent Burn.app" "$ZIP")
step "OK"
ls -l "$OUT"
shasum -a 256 "$ZIP"
