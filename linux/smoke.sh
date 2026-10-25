#!/usr/bin/env bash
# Smoke test of the Linux packages on one distro, as root in its container (CI: "container: <image>"; dev
# workstation: linux/smoke-local.sh IMAGE). Installs the native artifact (deb: apt; rpm: dnf or zypper; Arch: tarball
# then AppImage), checks PATH, launcher, icons and bundled CLI, runs the installed app's selftest (software
# rendering, then OpenGL Mesa under Xvfb) on the repo fixtures, uninstalls and checks that nothing is left.
#   bash linux/smoke.sh DIST [OUTPUT]
# DIST: dist/linux of a build. OUTPUT (logs, captures): DIST/smoke-<distro> by default. Code ≠ 0 at the 1st failure.
set -euo pipefail
APPID=io.github.magikdidi24.AgentBurn
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # repo root
DIST=$(cd "${1:?usage: smoke.sh DIST [OUTPUT]}" && pwd)
. /etc/os-release
OUT=${2:-$DIST/smoke-$ID-${VERSION_ID:-rolling}}
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$HERE/app/agentburn/__init__.py")
ABVER=$(sed -n 's/^AB_VER="\(.*\)"$/\1/p' "$HERE/cli.env")
TB=agent-burn-desktop-$VER-x86_64

step() { printf '\n== [%ss] %s\n' "$SECONDS" "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

step "$PRETTY_NAME (glibc $(ldd --version | head -1 | grep -o '[0-9.]*$')), Agent Burn $VER"
rm -rf "$OUT" && mkdir -p "$OUT/home"
(cd "$DIST" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS: artifact missing or corrupted in $DIST"
ok "checksums"

# Per family: pkg_install (native package alone, without its Recommends), extras (Xvfb, Mesa, font), pkg_files,
# pkg_remove. Arch has no package: tarball installed by hand in /opt and /usr/local.
case " $ID ${ID_LIKE:-} " in
*" debian "* | *" ubuntu "*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    pkg_install() { apt-get install -y -qq --no-install-recommends "$DIST/agent-burn-desktop_${VER}_amd64.deb"; }
    extras() { apt-get install -y -qq --no-install-recommends xvfb xauth libgl1-mesa-dri libglx-mesa0 libegl-mesa0 fonts-dejavu-core; }
    pkg_files() { dpkg -L agent-burn-desktop; }
    pkg_remove() { apt-get purge -y -qq agent-burn-desktop; }
    PREFIX=/usr
    COPYRIGHT=/usr/share/doc/agent-burn-desktop/copyright   # Debian Policy
    ;;
*" fedora "*)
    pkg_install() { dnf install -y -q --setopt=install_weak_deps=False "$DIST/agent-burn-desktop-$VER-1.x86_64.rpm"; }
    extras() { dnf install -y -q xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers mesa-libGL mesa-libEGL dejavu-sans-fonts; }
    pkg_files() { rpm -ql agent-burn-desktop; }
    pkg_remove() { dnf remove -y -q agent-burn-desktop; }
    PREFIX=/usr
    ;;
*" suse "*)
    zypper -n -q install --no-recommends findutils >/dev/null   # find missing from the image: ldd check
    pkg_install() { zypper -n -q install --no-recommends --allow-unsigned-rpm "$DIST/agent-burn-desktop-$VER-1.x86_64.rpm"; }
    extras() { zypper -n -q install --no-recommends xvfb-run xauth Mesa-dri Mesa-libGL1 Mesa-libEGL1 dejavu-fonts; }
    pkg_files() { rpm -ql agent-burn-desktop; }
    pkg_remove() { zypper -n -q remove agent-burn-desktop; }
    PREFIX=/usr
    ;;
*" arch "*)
    # Tarball dependencies on Arch (the user installs them by hand, as here).
    pacman -Syu --noconfirm --needed -q fontconfig freetype2 libdrm libglvnd libx11 libxcb libxkbcommon \
        libxkbcommon-x11 wayland >/dev/null
    pkg_install() {
        mkdir /opt/agent-burn-desktop
        tar -xzf "$DIST/$TB.tar.gz" -C /opt/agent-burn-desktop --strip-components=1 --exclude="$TB/share"
        ln -s /opt/agent-burn-desktop/agent-burn-desktop /usr/local/bin/agent-burn-desktop
        mkdir -p /usr/local/share && tar -xzf "$DIST/$TB.tar.gz" -C /usr/local --strip-components=1 "$TB/share"
    }
    extras() { pacman -S --noconfirm --needed -q xorg-server-xvfb xorg-xauth mesa ttf-dejavu >/dev/null; }
    pkg_files() {
        echo /usr/local/bin/agent-burn-desktop
        tar -tzf "$DIST/$TB.tar.gz" | sed -n "s|^$TB/share/\(.*[^/]\)$|/usr/local/share/\1|p"
        find /opt/agent-burn-desktop
    }
    pkg_remove() { pkg_files | grep -v '^/opt/' | xargs rm -f && rm -rf /opt/agent-burn-desktop; }
    PREFIX=/usr/local
    ;;
*) die "unsupported distro: $ID" ;;
esac

selftest() {   # NAME EXE COMMAND…: the exe serves the fixtures itself (fake CLI), data in OUTPUT
    local name=$1 exe=$2
    shift 2
    env -u DISPLAY -u WAYLAND_DISPLAY "$@" AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$exe" \
        AGENT_BURN_DATA="$OUT/data-$name" HOME="$OUT/home" XDG_CACHE_HOME="$OUT/cache" \
        timeout 300 "$exe" --selftest "$OUT/$name" >"$OUT/$name.log" 2>&1 || die "selftest $name (code $?): $OUT/$name.log"
    grep -q '"ok": true' "$OUT/$name/selftest.json" || die "selftest $name: ok ≠ true in $OUT/$name/selftest.json"
    ok "selftest $name"
}
SOFT=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software)
GL=(xvfb-run -a -s '-screen 0 1920x1080x24 -nolisten tcp' env QT_QPA_PLATFORM=xcb)

step "Installation"
pkg_install >"$OUT/install.log" 2>&1 || die "installation: $OUT/install.log"
ok "installed ($(du -sh /opt/agent-burn-desktop | cut -f1) in /opt/agent-burn-desktop)"
exe=$(command -v agent-burn-desktop) || die "agent-burn-desktop missing from PATH"
[ "$(readlink -f "$exe")" = /opt/agent-burn-desktop/agent-burn-desktop ] || die "$exe does not lead to the /opt bundle"
desktop=$PREFIX/share/applications/$APPID.desktop
[ -f "$desktop" ] || die "$desktop missing"
cmd=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")
[ "$(command -v "$cmd")" = "$exe" ] || die "launcher Exec=$cmd does not resolve to $exe"
icon=$(sed -n 's/^Icon=//p' "$desktop")
for n in 16 22 24 32 48 64 128 256; do
    [ -f "$PREFIX/share/icons/hicolor/${n}x$n/apps/$icon.png" ] || die "icon $icon ${n}px missing"
done
[ -f "$PREFIX/share/metainfo/$APPID.metainfo.xml" ] || die "AppStream $APPID.metainfo.xml missing"
[ -z "${COPYRIGHT:-}" ] || grep -q 'MIT license' "$COPYRIGHT" || die "$COPYRIGHT missing or without the license"
[ "$(/opt/agent-burn-desktop/bin/agent-burn --version)" = "$ABVER" ] || die "bundled CLI: --version ≠ “${ABVER}”"
ok "PATH ($exe), launcher, icons, AppStream, bundled CLI ($ABVER)"
# The selftest does not load every plugin (Wayland, EGL…): ldd checks that the package dependencies
# provide everything the bundle needs (LD_LIBRARY_PATH = the one the PyInstaller launcher sets).
command -v find >/dev/null || die "find missing: cannot run the ldd check"   # otherwise "ok" without checking anything
missing=$(find /opt/agent-burn-desktop -type f -name '*.so*' -exec env LD_LIBRARY_PATH=/opt/agent-burn-desktop ldd {} + \
    2>/dev/null | grep 'not found' | sort -u || true)
[ -z "$missing" ] || die "libraries not found with the package dependencies alone: ${missing//$'\n'/ }"
ok "all bundle libraries resolve ($(find /opt/agent-burn-desktop -type f -name '*.so*' | wc -l) files)"

step "Installed app selftest (package dependencies only: software rendering)"
selftest software "$exe" "${SOFT[@]}"
step "OpenGL (Mesa) selftest under Xvfb"
extras >"$OUT/extras.log" 2>&1 || die "Xvfb, Mesa, font: $OUT/extras.log"
selftest opengl "$exe" "${GL[@]}"

step "Uninstallation"
files=$(pkg_files)
pkg_remove >"$OUT/remove.log" 2>&1 || die "uninstallation: $OUT/remove.log"
left=$(echo "$files" | while read -r f; do if [ -L "$f" ] || [ -f "$f" ]; then echo "$f"; fi; done)
[ -z "$left" ] || die "files left after uninstallation: $(head -c 500 <<<"$left")"
[ ! -e /opt/agent-burn-desktop ] || die "/opt/agent-burn-desktop remains after uninstallation"
ok "no package file left ($(echo "$files" | wc -l) entries checked)"

if [ "$ID" = arch ]; then
    step "AppImage (--appimage-extract-and-run: no FUSE in a container)"
    # Executable copy: a downloaded CI artifact loses its x bit.
    cp "$DIST/$TB.AppImage" "$OUT/" && chmod +x "$OUT/$TB.AppImage"
    export APPIMAGE_EXTRACT_AND_RUN=1
    selftest appimage-software "$OUT/$TB.AppImage" "${SOFT[@]}"
    selftest appimage-opengl "$OUT/$TB.AppImage" "${GL[@]}"
    rm "$OUT/$TB.AppImage"
fi
step "OK: $PRETTY_NAME"
