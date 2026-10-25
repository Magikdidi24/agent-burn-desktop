#!/usr/bin/env bash
# Smoke test des paquets Linux sur une distro, en root dans son conteneur (CI : « container: <image> » ; poste de
# dev : linux/smoke-local.sh IMAGE). Installe l'artefact natif (deb : apt ; rpm : dnf ou zypper ; Arch : tarball
# puis AppImage), vérifie PATH, lanceur, icônes et CLI embarqué, lance le selftest de l'app installée (rendu
# logiciel, puis OpenGL Mesa sous Xvfb) sur les fixtures du dépôt, désinstalle et vérifie qu'il ne reste rien.
#   bash linux/smoke.sh DIST [SORTIE]
# DIST : dist/linux d'un build. SORTIE (journaux, captures) : DIST/smoke-<distro> par défaut. Code ≠ 0 au 1er échec.
set -euo pipefail
APPID=io.github.magikdidi24.AgentBurn
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # racine du dépôt
DIST=$(cd "${1:?usage : smoke.sh DIST [SORTIE]}" && pwd)
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
(cd "$DIST" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS : artefact absent ou corrompu dans $DIST"
ok "sommes de contrôle"

# Par famille : pkg_install (paquet natif seul, sans ses Recommends), extras (Xvfb, Mesa, police), pkg_files,
# pkg_remove. Arch n'a pas de paquet : tarball installé à la main dans /opt et /usr/local.
case " $ID ${ID_LIKE:-} " in
*" debian "* | *" ubuntu "*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    pkg_install() { apt-get install -y -qq --no-install-recommends "$DIST/agent-burn-desktop_${VER}_amd64.deb"; }
    extras() { apt-get install -y -qq --no-install-recommends xvfb xauth libgl1-mesa-dri libglx-mesa0 libegl-mesa0 fonts-dejavu-core; }
    pkg_files() { dpkg -L agent-burn-desktop; }
    pkg_remove() { apt-get purge -y -qq agent-burn-desktop; }
    PREFIX=/usr
    COPYRIGHT=/usr/share/doc/agent-burn-desktop/copyright   # Policy Debian
    ;;
*" fedora "*)
    pkg_install() { dnf install -y -q --setopt=install_weak_deps=False "$DIST/agent-burn-desktop-$VER-1.x86_64.rpm"; }
    extras() { dnf install -y -q xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers mesa-libGL mesa-libEGL dejavu-sans-fonts; }
    pkg_files() { rpm -ql agent-burn-desktop; }
    pkg_remove() { dnf remove -y -q agent-burn-desktop; }
    PREFIX=/usr
    ;;
*" suse "*)
    pkg_install() { zypper -n -q install --no-recommends --allow-unsigned-rpm "$DIST/agent-burn-desktop-$VER-1.x86_64.rpm"; }
    extras() { zypper -n -q install --no-recommends xvfb-run xauth Mesa-dri Mesa-libGL1 Mesa-libEGL1 dejavu-fonts; }
    pkg_files() { rpm -ql agent-burn-desktop; }
    pkg_remove() { zypper -n -q remove agent-burn-desktop; }
    PREFIX=/usr
    ;;
*" arch "*)
    # Dépendances du tarball sur Arch (à installer à la main par l'utilisateur, comme ici).
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
*) die "distro non prise en charge : $ID" ;;
esac

selftest() {   # NOM EXE COMMANDE… : l'exe sert lui-même les fixtures (faux CLI), données dans SORTIE
    local name=$1 exe=$2
    shift 2
    env -u DISPLAY -u WAYLAND_DISPLAY "$@" AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$exe" \
        AGENT_BURN_DATA="$OUT/data-$name" HOME="$OUT/home" XDG_CACHE_HOME="$OUT/cache" \
        timeout 300 "$exe" --selftest "$OUT/$name" >"$OUT/$name.log" 2>&1 || die "selftest $name (code $?) : $OUT/$name.log"
    grep -q '"ok": true' "$OUT/$name/selftest.json" || die "selftest $name : ok ≠ true dans $OUT/$name/selftest.json"
    ok "selftest $name"
}
SOFT=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software)
GL=(xvfb-run -a -s '-screen 0 1920x1080x24 -nolisten tcp' env QT_QPA_PLATFORM=xcb)

step "Installation"
pkg_install >"$OUT/install.log" 2>&1 || die "installation : $OUT/install.log"
ok "installé ($(du -sh /opt/agent-burn-desktop | cut -f1) dans /opt/agent-burn-desktop)"
exe=$(command -v agent-burn-desktop) || die "agent-burn-desktop absent du PATH"
[ "$(readlink -f "$exe")" = /opt/agent-burn-desktop/agent-burn-desktop ] || die "$exe ne mène pas au bundle de /opt"
desktop=$PREFIX/share/applications/$APPID.desktop
[ -f "$desktop" ] || die "$desktop absent"
cmd=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")
[ "$(command -v "$cmd")" = "$exe" ] || die "Exec=$cmd du lanceur ne donne pas $exe"
icon=$(sed -n 's/^Icon=//p' "$desktop")
for n in 16 22 24 32 48 64 128 256; do
    [ -f "$PREFIX/share/icons/hicolor/${n}x$n/apps/$icon.png" ] || die "icône $icon ${n}px absente"
done
[ -f "$PREFIX/share/metainfo/$APPID.metainfo.xml" ] || die "AppStream $APPID.metainfo.xml absent"
[ -z "${COPYRIGHT:-}" ] || grep -q 'licence MIT' "$COPYRIGHT" || die "$COPYRIGHT absent ou sans la licence"
[ "$(/opt/agent-burn-desktop/bin/agent-burn --version)" = "$ABVER" ] || die "CLI embarqué : --version ≠ « $ABVER »"
ok "PATH ($exe), lanceur, icônes, AppStream, CLI embarqué ($ABVER)"
# Le selftest ne charge pas tous les plugins (Wayland, EGL…) : ldd vérifie que les dépendances du paquet
# fournissent tout ce que le bundle demande (LD_LIBRARY_PATH = celui que pose le lanceur PyInstaller).
missing=$(find /opt/agent-burn-desktop -type f -name '*.so*' -exec env LD_LIBRARY_PATH=/opt/agent-burn-desktop ldd {} + \
    2>/dev/null | grep 'not found' | sort -u || true)
[ -z "$missing" ] || die "bibliothèques introuvables avec les seules dépendances du paquet : ${missing//$'\n'/ }"
ok "toutes les bibliothèques du bundle se résolvent"

step "Selftest de l'app installée (dépendances du paquet seules : rendu logiciel)"
selftest software "$exe" "${SOFT[@]}"
step "Selftest OpenGL (Mesa) sous Xvfb"
extras >"$OUT/extras.log" 2>&1 || die "Xvfb, Mesa, police : $OUT/extras.log"
selftest opengl "$exe" "${GL[@]}"

step "Désinstallation"
files=$(pkg_files)
pkg_remove >"$OUT/remove.log" 2>&1 || die "désinstallation : $OUT/remove.log"
left=$(echo "$files" | while read -r f; do if [ -L "$f" ] || [ -f "$f" ]; then echo "$f"; fi; done)
[ -z "$left" ] || die "fichiers restés après désinstallation : $(head -c 500 <<<"$left")"
[ ! -e /opt/agent-burn-desktop ] || die "/opt/agent-burn-desktop reste après désinstallation"
ok "plus aucun fichier du paquet ($(echo "$files" | wc -l) entrées vérifiées)"

if [ "$ID" = arch ]; then
    step "AppImage (--appimage-extract-and-run : pas de FUSE dans un conteneur)"
    # Copie exécutable : un artefact de CI téléchargé perd son bit x.
    cp "$DIST/$TB.AppImage" "$OUT/" && chmod +x "$OUT/$TB.AppImage"
    export APPIMAGE_EXTRACT_AND_RUN=1
    selftest appimage-software "$OUT/$TB.AppImage" "${SOFT[@]}"
    selftest appimage-opengl "$OUT/$TB.AppImage" "${GL[@]}"
    rm "$OUT/$TB.AppImage"
fi
step "OK : $PRETTY_NAME"
