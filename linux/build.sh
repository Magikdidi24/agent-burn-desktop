#!/usr/bin/env bash
# Builds Agent Burn for Linux in python:3.12-slim-bookworm, as root with network access (CI: "container" job;
# dev workstation: linux/build-local.sh). Static Rust CLI, fonts, licenses, slimmed PyInstaller bundle (bookworm
# glibc: runs on every newer distro), frozen bundle selftests, then the packages.
#   bash linux/build.sh      (SKIP_CLI=1: reuses build/cli-linux as is)
# Outputs in dist/linux/: tarball, AppImage, .deb, .rpm, SHA256SUMS, selftest/. CLI cached in
# build/cli-linux/ (key: AB_REV), the rest in build/linux/.
set -euo pipefail

APPID=io.github.magikdidi24.AgentBurn
APP_LICENSE=MIT   # app license (LICENSE); those of the CLI, Qt, Python and the font are in licenses/
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
W=$HERE/build/linux CLI=$HERE/build/cli-linux OUT=$HERE/dist/linux T=$HERE/build/linux/tools
cd "$HERE"
export DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1

step() { printf '\n== [%ss] %s\n' "$SECONDS" "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }
fetch() {   # URL SHA256 FILE: downloaded once, verified on every build
    [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet >/dev/null 2>&1 && return
    curl -fsSLo "$3" "$1" && echo "$2  $3" | sha256sum -c --quiet
}

[ "$(id -u)" = 0 ] || die "build.sh runs as root in python:3.12-slim-bookworm (on a workstation: linux/build-local.sh)"
. /etc/os-release
# bookworm (glibc 2.36, bundle at 2.35): a build on a newer distro would no longer run on older ones.
[ "$ID $VERSION_ID" = "debian 12" ] || die "python:3.12-slim-bookworm image expected, not $PRETTY_NAME"

# CLI revision: cli.env, single source (AB_REV and AB_VER change together).
REV=$(sed -n 's/^AB_REV=\([0-9a-f]\{40\}\)$/\1/p' cli.env)
ABVER=$(sed -n 's/^AB_VER="\(.*\)"$/\1/p' cli.env)
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' app/agentburn/__init__.py)
[ -n "$REV" ] && [ -n "$ABVER" ] && [ -n "$VER" ] || die "AB_REV / AB_VER (cli.env) or __version__ (app) not found"

step "System packages"
apt-get update -qq
# Build and validation tools, Xvfb + Mesa (OpenGL selftest), and the libraries Qt needs: PyInstaller
# bundles the ones the spec keeps (libxcb-*), the rest serves the selftest. gcc and musl: in build_cli.
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git xz-utils binutils file appstream desktop-file-utils \
    xvfb xauth libgl1-mesa-dri fonts-dejavu-core \
    libgl1 libegl1 libopengl0 libxkbcommon0 libxkbcommon-x11-0 libfontconfig1 libfreetype6 libdbus-1-3 \
    libglib2.0-0 libx11-xcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
    libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libxcb-xkb1 libwayland-client0 libwayland-cursor0 \
    libwayland-egl1 >/dev/null
mkdir -p "$W" "$T"

build_cli() {
    local src=$W/cli-src rust t
    # C compilers for the CLI crates (aws-lc, SQLite…): only when the CLI has to be built.
    apt-get install -y -qq --no-install-recommends gcc libc6-dev musl-tools >/dev/null
    rm -rf "$src" "$CLI" && mkdir -p "$CLI/bin"
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 https://github.com/Melvynx/agent-burn "$REV"
    git -C "$src" checkout -q FETCH_HEAD
    # Toolchain pinned by upstream at this revision (rust-toolchain.toml), without its dev components.
    rust=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$src/rust-toolchain.toml")
    [ -n "$rust" ] || die "upstream rust-toolchain.toml has no channel"
    # $HOME: /github/home in a CI "container" job, the one its caches save.
    export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo} RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}
    export PATH=$CARGO_HOME/bin:$PATH RUSTUP_TOOLCHAIN=$rust CARGO_TARGET_DIR=$W/cli-target
    if ! command -v rustup >/dev/null; then
        fetch https://static.rust-lang.org/rustup/archive/1.29.2/x86_64-unknown-linux-gnu/rustup-init \
            5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4 "$T/rustup-init"
        chmod +x "$T/rustup-init"
        # root's HOME: with the CI one (/github/home), rustup-init assumes sudo and reports it as an "error:".
        HOME=/root "$T/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain none
    fi
    rustup -q toolchain install --profile minimal "$rust" --target x86_64-unknown-linux-musl
    # musl: static binary, without glibc or any system library. glibc fallback if upstream breaks this build.
    t=x86_64-unknown-linux-musl
    if ! (cd "$src/rust" && cargo build -q --release --locked -p agent-burn --bin agent-burn --target $t); then
        echo "!! musl build failed (error above): falling back to x86_64-unknown-linux-gnu, bookworm glibc" >&2
        t=x86_64-unknown-linux-gnu
        (cd "$src/rust" && cargo build -q --release --locked -p agent-burn --bin agent-burn --target $t)
    fi
    cp "$CARGO_TARGET_DIR/$t/release/agent-burn" "$CLI/bin/"
    cp "$src/apps/agent-burn/LICENSE" "$CLI/LICENSE-agent-burn.txt"
    python3 tools/third_party_notices.py "$src" "$CLI/THIRD-PARTY-NOTICES.txt" --target $t
    echo $t > "$CLI/target"
    echo "$REV" > "$CLI/rev"   # last: marker of a complete cache
}

step "CLI $ABVER ($REV)"
if [ "${SKIP_CLI:-}" = 1 ]; then
    [ -x "$CLI/bin/agent-burn" ] || die "SKIP_CLI=1 but $CLI/bin/agent-burn missing"
    [ "$(cat "$CLI/rev" 2>/dev/null)" = "$REV" ] || echo "!! SKIP_CLI=1: CLI built for a revision other than $REV"
elif [ "$(cat "$CLI/rev" 2>/dev/null)" != "$REV" ] || [ ! -x "$CLI/bin/agent-burn" ]; then
    build_cli
fi
# AB_VER must describe this CLI: smoke.sh checks it on every installed package.
[ "$("$CLI/bin/agent-burn" --version)" = "$ABVER" ] || die "the CLI does not answer “${ABVER}”: AB_REV and AB_VER disagree (cli.env)"
file -b "$CLI/bin/agent-burn"

step "JetBrainsMono Nerd Font v3.4.0 fonts (QML glyphs validated on this version)"
fonts_ok() {
    (cd app/fonts 2>/dev/null && sha256sum -c --quiet >/dev/null 2>&1 <<'EOF'
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
    rm -rf "$V" && python3 -m venv "$V"
    "$V/bin/pip" install -q --disable-pip-version-check --root-user-action=ignore --require-hashes -r app/requirements.lock
    cp app/requirements.lock "$V/stamp"
fi

step "Icons, licenses, build-info.json"
rm -rf "$W/icons" && "$V/bin/python" linux/icons.py assets/agent-burn.png "$W/icons" "$APPID"
X=$HERE/build/bundle-extra   # copied to the bundle root by agentburn.spec
rm -rf "$X" && mkdir -p "$X/licenses"
cp "$CLI/LICENSE-agent-burn.txt" "$CLI/THIRD-PARTY-NOTICES.txt" tools/licenses/LGPL-3.0.txt tools/licenses/GPL-3.0.txt "$X/licenses/"
cp LICENSE "$X/licenses/LICENSE-agent-burn-desktop.txt"
cp app/fonts/OFL.txt "$X/licenses/LICENSE-JetBrainsMono-NerdFont.txt"
# Without .git (CI checkout without git): the CI commit, a PR's head commit rather than its merge commit.
COMMIT=$(git -C "$HERE" -c safe.directory='*' rev-parse HEAD 2>/dev/null || echo "${PR_HEAD_SHA:-${GITHUB_SHA:-unknown}}")
"$V/bin/python" - "$X" "$VER" "$COMMIT" "$REV" "$ABVER" "$(cat "$CLI/target")" <<'EOF'
import datetime, json, platform, sys, sysconfig
from pathlib import Path
import PySide6, PyInstaller
from PySide6.QtCore import qVersion
out, version, commit, rev, cli_version, cli_target = sys.argv[1:]
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
    "appVersion": version, "commit": commit, "target": "linux-x86_64",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cliRev": rev, "cliVersion": cli_version, "cliTarget": cli_target,
    "python": platform.python_version(), "pyside6": PySide6.__version__, "qt": qVersion(),
    "pyinstaller": PyInstaller.__version__}, indent=2) + "\n", encoding="utf-8")
EOF

step "PyInstaller bundle"
rm -rf "$W/dist"
"$V/bin/python" -m PyInstaller --noconfirm --log-level WARN --workpath "$W/pyinstaller" --distpath "$W/dist" agentburn.spec
B=$W/dist/agent-burn-desktop
# System libraries kept in the bundle (libbz2, libxcb-*): their license requires shipping their notice.
mkdir -p "$B/licenses/debian"
for f in "$B"/lib*.so*; do
    [ -L "$f" ] && continue
    pkg=$(dpkg -S "*/${f##*/}" 2>/dev/null) || continue   # libpython, outside dpkg: LICENSE-Python.txt
    pkg=${pkg%%:*}
    cp "/usr/share/doc/$pkg/copyright" "$B/licenses/debian/$pkg.copyright"
done
# Any library the bundle needs without containing it must be in the .rpm Requires (linux/nfpm.yaml):
# otherwise the app does not start where that library is missing.
needed=$({ find "$B" -type f -exec readelf -d {} + 2>/dev/null || true; } | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' | sort -u)
have=$({ find "$B" -printf '%f\n'; sed -n 's/^ *- "\(lib[^"(]*\)()(64bit)"$/\1/p' linux/nfpm.yaml
         printf '%s\n' libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 libresolv.so.2 \
            ld-linux-x86-64.so.2; } | sort -u)
undeclared=$(comm -23 <(echo "$needed") <(echo "$have"))
[ -z "$undeclared" ] || die "libraries neither bundled nor declared in linux/nfpm.yaml: ${undeclared//$'\n'/ }"
GLIBC=$({ find "$B" -type f -exec objdump -p {} + 2>/dev/null || true; } | grep -o 'GLIBC_2\.[0-9.]*' | sort -uV | tail -1)
GLIBC=${GLIBC#GLIBC_}
[ -n "$GLIBC" ] || die "minimum glibc version not found"
echo "bundle: $(du -sh "$B" | cut -f1), glibc >= $GLIBC"

step "Frozen bundle selftest: software rendering, then OpenGL (Mesa) under Xvfb"
rm -rf "$OUT" && mkdir -p "$OUT/selftest"
selftest() {   # NAME COMMAND…: the exe serves the fixtures itself (fake CLI), data outside any real HOME
    local name=$1
    shift
    env -u DISPLAY -u WAYLAND_DISPLAY "$@" AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$B/agent-burn-desktop" \
        AGENT_BURN_DATA="$W/selftest-data/$name" XDG_CACHE_HOME="$W/selftest-cache" \
        timeout 300 "$B/agent-burn-desktop" --selftest "$OUT/selftest/$name" >"$OUT/selftest/$name.log" 2>&1 ||
        die "selftest $name failed (code $?): dist/linux/selftest/$name.log and $name/selftest.json"
}
rm -rf "$W/selftest-data" "$W/selftest-cache"
selftest software QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
selftest opengl xvfb-run -a -s '-screen 0 1920x1080x24 -nolisten tcp' env QT_QPA_PLATFORM=xcb

step "Packages"
# .rpm license: SPDX expression of the whole content, from the bundle notices (CLI crates, Qt components) and,
# for the rest: app and CLI, Qt and PySide6, Python, font, libbz2 and libxcb-* (licenses/debian/).
PKG_LICENSE=$("$V/bin/python" tools/package_license.py "$B/licenses" Linux \
    "$APP_LICENSE" LGPL-3.0-only PSF-2.0 OFL-1.1 bzip2-1.0.6 X11)
render() {
    # shortcut: release date = build day; replace it with the tag date once there are releases
    sed -e "s|@VERSION@|$VER|g" -e "s|@DATE@|$(date -u +%F)|g" -e "s|@APP_LICENSE@|$APP_LICENSE|g" -e "s|@GLIBC@|$GLIBC|g" \
        -e "s|@PKG_LICENSE@|$PKG_LICENSE|g" "$1"
}
render "linux/$APPID.metainfo.xml" >"$W/$APPID.metainfo.xml"
desktop-file-validate "linux/$APPID.desktop"
appstreamcli validate --no-net "$W/$APPID.metainfo.xml"
share() {   # DIR: desktop entry, hicolor icons and AppStream under DIR/{applications,icons,metainfo}
    mkdir -p "$1/applications" "$1/metainfo"
    cp "linux/$APPID.desktop" "$1/applications/"
    mkdir -p "$1/icons" && cp -a "$W/icons/hicolor" "$1/icons/"
    cp "$W/$APPID.metainfo.xml" "$1/metainfo/"
}
fetch https://github.com/goreleaser/nfpm/releases/download/v2.48.0/nfpm_2.48.0_Linux_x86_64.tar.gz \
    6d7f9a28b2f397934403950fcbba83f598b08d02edbe79a0815b3b4897341750 "$T/nfpm.tar.gz"
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
    ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 "$T/appimagetool"
# Pinned runtime, passed to appimagetool: otherwise it downloads the current "continuous" version. It links libfuse,
# squashfuse, zstd, zlib, mimalloc and musl: their notice, collected for this version, goes into the AppImage.
RUNTIME=20251108
fetch "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME/runtime-x86_64" \
    2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d "$T/runtime-x86_64"
grep -q "^AppImage runtime type2-runtime $RUNTIME " tools/licenses/NOTICE-AppImage-runtime.txt ||
    die "tools/licenses/NOTICE-AppImage-runtime.txt does not describe runtime $RUNTIME: redo it"
tar -xzf "$T/nfpm.tar.gz" -C "$T" nfpm
chmod +x "$T/appimagetool"

# .deb / .rpm: /opt/agent-burn-desktop (CLI in bin/, never in /usr/bin: no conflict with a separately
# installed agent-burn), link /usr/bin/agent-burn-desktop. Hard links: no copy of the bundle.
R=$W/pkgroot
rm -rf "$R" && mkdir -p "$R/opt" "$R/usr/share"
cp -al "$B" "$R/opt/agent-burn-desktop"
share "$R/usr/share"
# .deb: Debian Policy copyright file (the .rpm has none); the other texts stay in licenses/.
mkdir -p "$R/usr/share/doc/agent-burn-desktop"
{
    echo "Agent Burn (desktop app) $VER: MIT license, text below."
    echo "Components bundled in /opt/agent-burn-desktop (agent-burn CLI, Qt and PySide6, Python, font, libraries):"
    echo "licenses and notices in /opt/agent-burn-desktop/licenses/."
    echo
    cat LICENSE
} >"$R/usr/share/doc/agent-burn-desktop/copyright"
render linux/nfpm.yaml >"$W/nfpm.yaml"
(cd "$R" && "$T/nfpm" pkg -f "$W/nfpm.yaml" -p deb -t "$OUT/agent-burn-desktop_${VER}_amd64.deb")
(cd "$R" && "$T/nfpm" pkg -f "$W/nfpm.yaml" -p rpm -t "$OUT/agent-burn-desktop-$VER-1.x86_64.rpm")

# Tarball: self-contained folder, to extract anywhere; share/ for menu integration.
TB=agent-burn-desktop-$VER-x86_64
rm -rf "${W:?}/$TB" && cp -al "$B" "$W/$TB"
share "$W/$TB/share"
tar -C "$W" --owner=0 --group=0 --numeric-owner -czf "$OUT/$TB.tar.gz" "$TB"

A=$W/AppDir
rm -rf "$A" && mkdir -p "$A/usr/lib"
cp -al "$B" "$A/usr/lib/agent-burn-desktop"
cp tools/licenses/NOTICE-AppImage-runtime.txt "$A/usr/lib/agent-burn-desktop/licenses/"   # the runtime is only there
share "$A/usr/share"
mv "$A/usr/share/metainfo/$APPID.metainfo.xml" "$A/usr/share/metainfo/$APPID.appdata.xml"   # name appimagetool looks for
install -m 755 linux/AppRun "$A/AppRun"
cp "linux/$APPID.desktop" "$W/icons/hicolor/256x256/apps/$APPID.png" "$A/"
# -n: AppStream already validated above, offline; appimagetool would test the URLs online.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$T/appimagetool" -n --runtime-file "$T/runtime-x86_64" "$A" "$OUT/$TB.AppImage"

(cd "$OUT" && sha256sum -- *.tar.gz *.AppImage *.deb *.rpm >SHA256SUMS)
step "OK"
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
