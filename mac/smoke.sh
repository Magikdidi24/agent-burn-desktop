#!/usr/bin/env bash
# Smoke test of a macOS zip on a Mac (CI: "macos" jobs), the app as a user gets it: unzipped with ditto, Info.plist,
# ad hoc signature without sandbox, architecture, bundled CLI, selftest of the unzipped app (build-info.json read:
# version and target) with start at login turned on then off (LaunchAgent plist checked), tray mode for 10 s, a 2nd
# launch handed over to it. In a throwaway HOME, never the real one. The x64 app runs under Rosetta 2 on Apple Silicon.
#   bash mac/smoke.sh ZIP [OUTPUT]      ZIP: AgentBurn-<version>-macos-<arm64|x64>.zip
# OUTPUT (logs, captures): dist/mac-<arch>/smoke by default. Code ≠ 0 at the 1st failure. For the bash 3.2 of macOS.
set -euo pipefail
APPID=io.github.magikdidi24.AgentBurn
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
ZIP=$(cd "$(dirname "${1:?usage: smoke.sh ZIP [OUTPUT]}")" && pwd)/$(basename "$1")
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$HERE/app/agentburn/__init__.py")
ABVER=$(sed -n 's/^AB_VER="\(.*\)"$/\1/p' "$HERE/cli.env")

step() { printf '\n== [%ss] %s\n' "$SECONDS" "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
case $(basename "$ZIP") in
    "AgentBurn-$VER-macos-arm64.zip") ARCH=arm64 MACH=arm64 ;;
    "AgentBurn-$VER-macos-x64.zip") ARCH=x64 MACH=x86_64 ;;
    *) die "$ZIP: AgentBurn-$VER-macos-<arm64|x64>.zip expected" ;;
esac
OUT=${2:-$HERE/dist/mac-$ARCH/smoke}
if ! command -v timeout >/dev/null; then   # not in macOS; Perl is
    timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

step "Agent Burn $VER for $ARCH on macOS $(sw_vers -productVersion) $(uname -m)"
rm -rf "$OUT" && mkdir -p "$OUT"
# Short HOME: the single-instance socket goes under it (Library/Caches/AgentBurn/AgentBurn.sock), 104 bytes at most.
H=$(mktemp -d /tmp/abhome.XXXXXX)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; cp -R "$H/Library/Logs" "$OUT/home-logs" 2>/dev/null; rm -rf "$H"' EXIT
ditto -x -k "$ZIP" "$OUT/unzipped"
[ -d "$OUT/unzipped/Agent Burn.app" ] || die "no Agent Burn.app at the top of $ZIP"
APP="$(cd "$OUT/unzipped" && pwd -P)/Agent Burn.app"   # the app records its exe with links resolved
EXE="$APP/Contents/MacOS/AgentBurn"
info() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist"; }
[ "$(info CFBundleIdentifier)" = $APPID ] || die "CFBundleIdentifier: $(info CFBundleIdentifier)"
[ "$(info CFBundleExecutable)" = AgentBurn ] && [ -x "$EXE" ] || die "executable: $(info CFBundleExecutable)"
[ "$(info CFBundleShortVersionString)" = "$VER" ] || die "CFBundleShortVersionString: $(info CFBundleShortVersionString)"
[ "$(info LSUIElement)" = true ] || die "LSUIElement: $(info LSUIElement), the app would have a Dock icon"
ok "Info.plist ($APPID $VER, menu bar app)"
codesign --verify --deep --strict "$APP" || die "signature broken once unzipped"
# No App Sandbox: the app reads the agents' logs through its CLI, and what it downloads must not be quarantined.
case $(codesign -d --entitlements - "$APP" 2>&1) in *com.apple.security.app-sandbox*) die "the app is sandboxed" ;; esac
ok "ad hoc signature, no sandbox"
CLI=$APP/Contents/Frameworks/bin/agent-burn
[ "$(lipo -archs "$EXE")" = $MACH ] && [ "$(lipo -archs "$CLI")" = $MACH ] ||
    die "not $MACH only: app $(lipo -archs "$EXE"), CLI $(lipo -archs "$CLI")"
[ "$("$CLI" --version)" = "$ABVER" ] || die "bundled CLI: --version ≠ “${ABVER}”"
grep -q "\"target\": \"macos-$ARCH\"" "$APP/Contents/Resources/build-info.json" || die "build-info.json: target ≠ macos-$ARCH"
ok "$MACH only, bundled CLI ($ABVER), build-info.json"

selftest() {   # NAME on|off: the exe serves the fixtures itself (fake CLI); start at login set by the app
    HOME=$H AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$EXE" AGENT_BURN_DATA="$H/data-$1" \
        AGENT_BURN_SELFTEST_AUTOSTART=$2 timeout 300 "$EXE" --selftest "$OUT/$1" >"$OUT/$1.log" 2>&1 ||
        die "selftest $1 (code $?): $OUT/$1.log"
    grep -q '"ok": true' "$OUT/$1/selftest.json" || die "selftest $1: ok ≠ true in $OUT/$1/selftest.json"
    # The app found its build-info.json (Contents/Resources): version and target, which also turn its updater on.
    grep -q "selftest: Agent Burn $VER (macos-$ARCH, " "$OUT/$1/agent-burn.log" ||
        die "selftest $1: build-info.json not read by the app (see $OUT/$1/agent-burn.log)"
    grep -q "\"autostart\": $([ "$2" = on ] && echo true || echo false)" "$OUT/$1/selftest.json" ||
        die "selftest $1: start at login not $2 (see $OUT/$1.log)"
    ok "selftest $1"
}
AGENT=$H/Library/LaunchAgents/$APPID.plist
job() { plutil -extract "$1" raw -o - "$AGENT"; }

step "Selftest of the unzipped app, start at login turned on"
selftest selftest-on on
plutil -lint -s "$AGENT" || die "$AGENT unreadable"
[ "$(job Label)" = $APPID ] && [ "$(job ProgramArguments.0)" = "$EXE" ] && [ "$(job RunAtLoad)" = true ] ||
    die "LaunchAgent: $(cat "$AGENT")"
ok "LaunchAgent $APPID: RunAtLoad, starts $EXE"
step "Selftest again, start at login turned off"
selftest selftest-off off
[ ! -e "$AGENT" ] || die "$AGENT still there"
ok "LaunchAgent removed"

step "Tray mode for 10 s, then a 2nd launch"
export HOME=$H AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$EXE" AGENT_BURN_DATA="$H/data-tray"
"$EXE" >"$OUT/tray.log" 2>&1 &
pid=$!
sleep 10
kill -0 "$pid" 2>/dev/null || die "tray mode stopped before 10 s: $OUT/tray.log, $OUT/home-logs"
[ -d "$H/Library/Caches/AgentBurn" ] || die "no QML cache in $H/Library/Caches/AgentBurn"
t=$SECONDS
timeout 20 "$EXE" >"$OUT/second.log" 2>&1 || die "2nd launch: code $?"
kill -0 "$pid" 2>/dev/null || die "the 1st instance stopped at the 2nd launch"
grep -q "opened the dashboard of the running instance" "$H/Library/Logs/AgentBurn/agent-burn.log" ||
    die "the 2nd launch did not reach the 1st (log: $OUT/home-logs)"
ok "tray mode alive after 10 s; 2nd launch handed over, code 0 in $((SECONDS - t)) s"
kill "$pid" && wait "$pid" || true
pid=
step "OK: zip, signature, bundled CLI, selftests, start at login, tray mode, 2nd launch"
