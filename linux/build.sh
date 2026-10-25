#!/usr/bin/env bash
# Construit Agent Burn pour Linux dans python:3.12-slim-bookworm, en root avec réseau (CI : job « container » ;
# poste de dev : linux/build-local.sh). CLI Rust statique, polices, licences, bundle PyInstaller allégé (glibc de
# bookworm : tourne sur toutes les distros plus récentes), selftests du bundle gelé, puis les paquets.
#   bash linux/build.sh      (SKIP_CLI=1 : réutilise build/cli-linux tel quel)
# Sorties dans dist/linux/ : tarball, AppImage, .deb, .rpm, SHA256SUMS, selftest/. CLI en cache dans
# build/cli-linux/ (clé : AB_REV), le reste dans build/linux/.
set -euo pipefail

APPID=io.github.magikdidi24.AgentBurn
APP_LICENSE=MIT   # licence de l'app (LICENSE) ; celles du CLI, de Qt, de Python et de la police sont dans licenses/
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # racine du dépôt
W=$HERE/build/linux CLI=$HERE/build/cli-linux OUT=$HERE/dist/linux T=$HERE/build/linux/tools
cd "$HERE"
export DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1

step() { printf '\n== [%ss] %s\n' "$SECONDS" "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }
fetch() {   # URL SHA256 FICHIER : téléchargé une fois, vérifié à chaque build
    [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet >/dev/null 2>&1 && return
    curl -fsSLo "$3" "$1" && echo "$2  $3" | sha256sum -c --quiet
}

[ "$(id -u)" = 0 ] || die "build.sh tourne en root dans python:3.12-slim-bookworm (sur un poste : linux/build-local.sh)"
. /etc/os-release
# bookworm (glibc 2.36, bundle à 2.35) : un build sur une distro plus récente ne tournerait plus sur les anciennes.
[ "$ID $VERSION_ID" = "debian 12" ] || die "image python:3.12-slim-bookworm attendue, pas $PRETTY_NAME"

# Révision du CLI : cli.env, source unique (AB_REV et AB_VER changent ensemble).
REV=$(sed -n 's/^AB_REV=\([0-9a-f]\{40\}\)$/\1/p' cli.env)
ABVER=$(sed -n 's/^AB_VER="\(.*\)"$/\1/p' cli.env)
VER=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' app/agentburn/__init__.py)
[ -n "$REV" ] && [ -n "$ABVER" ] && [ -n "$VER" ] || die "AB_REV / AB_VER (cli.env) ou __version__ (app) introuvable"

step "Paquets système"
apt-get update -qq
# Outils de build, Rust (gcc, musl), validation, Xvfb + Mesa (selftest OpenGL), et les bibliothèques que Qt
# demande : PyInstaller embarque celles que le spec garde (libxcb-*), le reste sert au selftest.
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git xz-utils binutils file gcc libc6-dev musl-tools appstream desktop-file-utils \
    xvfb xauth libgl1-mesa-dri fonts-dejavu-core \
    libgl1 libegl1 libopengl0 libxkbcommon0 libxkbcommon-x11-0 libfontconfig1 libfreetype6 libdbus-1-3 \
    libglib2.0-0 libx11-xcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
    libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libxcb-xkb1 libwayland-client0 libwayland-cursor0 \
    libwayland-egl1 >/dev/null
mkdir -p "$W" "$T"

build_cli() {
    local src=$W/cli-src rust t
    rm -rf "$src" "$CLI" && mkdir -p "$CLI/bin"
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 https://github.com/Melvynx/agent-burn "$REV"
    git -C "$src" checkout -q FETCH_HEAD
    # Toolchain épinglée par l'amont à cette révision (rust-toolchain.toml), sans ses composants de dev.
    rust=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$src/rust-toolchain.toml")
    [ -n "$rust" ] || die "rust-toolchain.toml de l'amont sans channel"
    # $HOME : /github/home dans un job « container » de la CI, celui que ses caches sauvegardent.
    export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo} RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}
    export PATH=$CARGO_HOME/bin:$PATH RUSTUP_TOOLCHAIN=$rust CARGO_TARGET_DIR=$W/cli-target
    if ! command -v rustup >/dev/null; then
        fetch https://static.rust-lang.org/rustup/archive/1.29.2/x86_64-unknown-linux-gnu/rustup-init \
            5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4 "$T/rustup-init"
        chmod +x "$T/rustup-init"
        "$T/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain none
    fi
    rustup -q toolchain install --profile minimal "$rust" --target x86_64-unknown-linux-musl
    # musl : binaire statique, sans glibc ni bibliothèque système. Repli glibc si l'amont casse ce build.
    t=x86_64-unknown-linux-musl
    if ! (cd "$src/rust" && cargo build -q --release --locked -p agent-burn --bin agent-burn --target $t); then
        echo "!! build musl en échec (erreur ci-dessus) : repli sur x86_64-unknown-linux-gnu, glibc de bookworm" >&2
        t=x86_64-unknown-linux-gnu
        (cd "$src/rust" && cargo build -q --release --locked -p agent-burn --bin agent-burn --target $t)
    fi
    cp "$CARGO_TARGET_DIR/$t/release/agent-burn" "$CLI/bin/"
    cp "$src/apps/agent-burn/LICENSE" "$CLI/LICENSE-agent-burn.txt"
    python3 tools/third_party_notices.py "$src" "$CLI/THIRD-PARTY-NOTICES.txt" --target $t
    echo $t > "$CLI/target"
    echo "$REV" > "$CLI/rev"   # en dernier : témoin d'un cache complet
}

step "CLI $ABVER ($REV)"
if [ "${SKIP_CLI:-}" = 1 ]; then
    [ -x "$CLI/bin/agent-burn" ] || die "SKIP_CLI=1 mais $CLI/bin/agent-burn absent"
    [ "$(cat "$CLI/rev" 2>/dev/null)" = "$REV" ] || echo "!! SKIP_CLI=1 : CLI compilé pour une autre révision que $REV"
elif [ "$(cat "$CLI/rev" 2>/dev/null)" != "$REV" ] || [ ! -x "$CLI/bin/agent-burn" ]; then
    build_cli
fi
# AB_VER doit décrire ce CLI : smoke.sh le vérifie sur chaque paquet installé.
[ "$("$CLI/bin/agent-burn" --version)" = "$ABVER" ] || die "le CLI ne répond pas « $ABVER » : AB_REV et AB_VER divergent (cli.env)"
file -b "$CLI/bin/agent-burn"

step "Polices JetBrainsMono Nerd Font v3.4.0 (glyphes du QML validés sur cette version)"
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
    fonts_ok || die "polices extraites différentes de celles épinglées"
fi

step "Python : venv, PySide6, PyInstaller"
V=$W/venv
# Verrou haché : versions et sha256 de tout l'arbre, PyInstaller compris. Venv recréé quand il change : un paquet
# retiré resterait sinon dans le venv (et le bundle).
if [ "$(cat "$V/stamp" 2>/dev/null)" != "$(cat app/requirements.lock)" ]; then
    rm -rf "$V" && python3 -m venv "$V"
    "$V/bin/pip" install -q --disable-pip-version-check --root-user-action=ignore --require-hashes -r app/requirements.lock
    cp app/requirements.lock "$V/stamp"
fi

step "Icônes, licences, build-info.json"
rm -rf "$W/icons" && "$V/bin/python" linux/icons.py assets/agent-burn.png "$W/icons" "$APPID"
X=$HERE/build/bundle-extra   # copié à la racine du bundle par agentburn.spec
rm -rf "$X" && mkdir -p "$X/licenses"
cp "$CLI/LICENSE-agent-burn.txt" "$CLI/THIRD-PARTY-NOTICES.txt" tools/licenses/LGPL-3.0.txt tools/licenses/GPL-3.0.txt "$X/licenses/"
cp LICENSE "$X/licenses/LICENSE-agent-burn-desktop.txt"
cp app/fonts/OFL.txt "$X/licenses/LICENSE-JetBrainsMono-NerdFont.txt"
COMMIT=$(git -C "$HERE" -c safe.directory='*' rev-parse HEAD 2>/dev/null || echo "${GITHUB_SHA:-unknown}")
"$V/bin/python" - "$X" "$VER" "$COMMIT" "$REV" "$ABVER" "$(cat "$CLI/target")" <<'EOF'
import datetime, json, platform, sys, sysconfig
from pathlib import Path
import PySide6, PyInstaller
from PySide6.QtCore import qVersion
out, version, commit, rev, cli_version, cli_target = sys.argv[1:]
notice = Path("tools/licenses/NOTICE-Qt-PySide6.txt").read_text(encoding="utf-8")
Path(out, "licenses", "NOTICE-Qt-PySide6.txt").write_text(
    notice.replace("@QT@", qVersion()).replace("@PYSIDE6@", PySide6.__version__), encoding="utf-8")
# Composants tiers de Qt et logiciels incorporés à Python : relevés pour ces versions, à refaire quand elles changent.
qt_third = Path("tools/licenses/QT-THIRD-PARTY.txt").read_text(encoding="utf-8")
py_third = Path("tools/licenses/PYTHON-THIRD-PARTY.txt").read_text(encoding="utf-8")
if not qt_third.startswith(f"Qt {qVersion()} et PySide6 {PySide6.__version__} :"):
    sys.exit(f"tools/licenses/QT-THIRD-PARTY.txt ne décrit pas Qt {qVersion()} et PySide6 {PySide6.__version__} : à refaire")
if not py_third.startswith("Python %d.%d :" % sys.version_info[:2]):
    sys.exit(f"tools/licenses/PYTHON-THIRD-PARTY.txt ne décrit pas Python {platform.python_version()} : à refaire")
Path(out, "licenses", "QT-THIRD-PARTY.txt").write_text(qt_third, encoding="utf-8")
# LICENSE.txt de Python sans les logiciels incorporés (Doc/license.rst) : ajoutés à la suite.
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

step "Bundle PyInstaller"
rm -rf "$W/dist"
"$V/bin/python" -m PyInstaller --noconfirm --log-level WARN --workpath "$W/pyinstaller" --distpath "$W/dist" agentburn.spec
B=$W/dist/agent-burn-desktop
# Bibliothèques système gardées dans le bundle (libbz2, libxcb-*) : leur licence exige d'en livrer la notice.
mkdir -p "$B/licenses/debian"
for f in "$B"/lib*.so*; do
    [ -L "$f" ] && continue
    pkg=$(dpkg -S "*/${f##*/}" 2>/dev/null) || continue   # libpython, hors dpkg : LICENSE-Python.txt
    pkg=${pkg%%:*}
    cp "/usr/share/doc/$pkg/copyright" "$B/licenses/debian/$pkg.copyright"
done
# Toute bibliothèque demandée par le bundle sans y être doit figurer dans les Requires du .rpm (linux/nfpm.yaml) :
# sinon l'app ne démarre pas là où elle manque.
needed=$({ find "$B" -type f -exec readelf -d {} + 2>/dev/null || true; } | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' | sort -u)
have=$({ find "$B" -printf '%f\n'; sed -n 's/^ *- "\(lib[^"(]*\)()(64bit)"$/\1/p' linux/nfpm.yaml
         printf '%s\n' libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 libresolv.so.2 \
            ld-linux-x86-64.so.2; } | sort -u)
undeclared=$(comm -23 <(echo "$needed") <(echo "$have"))
[ -z "$undeclared" ] || die "bibliothèques ni embarquées ni déclarées dans linux/nfpm.yaml : ${undeclared//$'\n'/ }"
GLIBC=$({ find "$B" -type f -exec objdump -p {} + 2>/dev/null || true; } | grep -o 'GLIBC_2\.[0-9.]*' | sort -uV | tail -1)
GLIBC=${GLIBC#GLIBC_}
[ -n "$GLIBC" ] || die "version minimale de glibc introuvable"
echo "bundle : $(du -sh "$B" | cut -f1), glibc >= $GLIBC"

step "Selftest du bundle gelé : rendu logiciel, puis OpenGL (Mesa) sous Xvfb"
rm -rf "$OUT" && mkdir -p "$OUT/selftest"
selftest() {   # NOM COMMANDE… : l'exe sert lui-même les fixtures (faux CLI), données hors de tout HOME réel
    local name=$1
    shift
    env -u DISPLAY -u WAYLAND_DISPLAY "$@" AGENT_BURN_FAKE_DIR="$HERE/tests/fixtures" AGENT_BURN_BIN="$B/agent-burn-desktop" \
        AGENT_BURN_DATA="$W/selftest-data/$name" XDG_CACHE_HOME="$W/selftest-cache" \
        timeout 300 "$B/agent-burn-desktop" --selftest "$OUT/selftest/$name" >"$OUT/selftest/$name.log" 2>&1 ||
        die "selftest $name en échec (code $?) : dist/linux/selftest/$name.log et $name/selftest.json"
}
rm -rf "$W/selftest-data" "$W/selftest-cache"
selftest software QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
selftest opengl xvfb-run -a -s '-screen 0 1920x1080x24 -nolisten tcp' env QT_QPA_PLATFORM=xcb

step "Paquets"
# Licence du .rpm : expression SPDX de tout le contenu, d'après les notices du bundle (crates du CLI, composants de
# Qt) et, pour le reste : app et CLI, Qt et PySide6, Python, police, libbz2 et libxcb-* (licenses/debian/).
PKG_LICENSE=$("$V/bin/python" tools/package_license.py "$B/licenses" Linux \
    "$APP_LICENSE" LGPL-3.0-only PSF-2.0 OFL-1.1 bzip2-1.0.6 X11)
render() {
    # shortcut: date de release = jour du build ; à remplacer par celle du tag quand il y aura des releases
    sed -e "s|@VERSION@|$VER|g" -e "s|@DATE@|$(date -u +%F)|g" -e "s|@APP_LICENSE@|$APP_LICENSE|g" -e "s|@GLIBC@|$GLIBC|g" \
        -e "s|@PKG_LICENSE@|$PKG_LICENSE|g" "$1"
}
render "linux/$APPID.metainfo.xml" >"$W/$APPID.metainfo.xml"
desktop-file-validate "linux/$APPID.desktop"
appstreamcli validate --no-net "$W/$APPID.metainfo.xml"
share() {   # DOSSIER : desktop, icônes hicolor et AppStream sous DOSSIER/{applications,icons,metainfo}
    mkdir -p "$1/applications" "$1/metainfo"
    cp "linux/$APPID.desktop" "$1/applications/"
    mkdir -p "$1/icons" && cp -a "$W/icons/hicolor" "$1/icons/"
    cp "$W/$APPID.metainfo.xml" "$1/metainfo/"
}
fetch https://github.com/goreleaser/nfpm/releases/download/v2.48.0/nfpm_2.48.0_Linux_x86_64.tar.gz \
    6d7f9a28b2f397934403950fcbba83f598b08d02edbe79a0815b3b4897341750 "$T/nfpm.tar.gz"
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
    ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 "$T/appimagetool"
# Runtime épinglé, passé à appimagetool : sinon il télécharge la version « continuous » du moment. Il lie libfuse,
# squashfuse, zstd, zlib, mimalloc et musl : leur notice, relevée pour cette version, va dans l'AppImage.
RUNTIME=20251108
fetch "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME/runtime-x86_64" \
    2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d "$T/runtime-x86_64"
grep -q "^Runtime AppImage type2-runtime $RUNTIME " tools/licenses/NOTICE-AppImage-runtime.txt ||
    die "tools/licenses/NOTICE-AppImage-runtime.txt ne décrit pas le runtime $RUNTIME : à refaire"
tar -xzf "$T/nfpm.tar.gz" -C "$T" nfpm
chmod +x "$T/appimagetool"

# .deb / .rpm : /opt/agent-burn-desktop (CLI dans bin/, jamais dans /usr/bin : pas de conflit avec un
# agent-burn installé à part), lien /usr/bin/agent-burn-desktop. Liens durs : pas de copie du bundle.
R=$W/pkgroot
rm -rf "$R" && mkdir -p "$R/opt" "$R/usr/share"
cp -al "$B" "$R/opt/agent-burn-desktop"
share "$R/usr/share"
# .deb : fichier copyright de la Policy Debian (le .rpm n'en a pas) ; les autres textes restent dans licenses/.
mkdir -p "$R/usr/share/doc/agent-burn-desktop"
{
    echo "Agent Burn (app de bureau) $VER : licence MIT, texte ci-dessous."
    echo "Composants embarqués dans /opt/agent-burn-desktop (CLI agent-burn, Qt et PySide6, Python, police, bibliothèques) :"
    echo "licences et notices dans /opt/agent-burn-desktop/licenses/."
    echo
    cat LICENSE
} >"$R/usr/share/doc/agent-burn-desktop/copyright"
render linux/nfpm.yaml >"$W/nfpm.yaml"
(cd "$R" && "$T/nfpm" pkg -f "$W/nfpm.yaml" -p deb -t "$OUT/agent-burn-desktop_${VER}_amd64.deb")
(cd "$R" && "$T/nfpm" pkg -f "$W/nfpm.yaml" -p rpm -t "$OUT/agent-burn-desktop-$VER-1.x86_64.rpm")

# Tarball : dossier autonome, à décompresser n'importe où ; share/ pour l'intégration au menu.
TB=agent-burn-desktop-$VER-x86_64
rm -rf "${W:?}/$TB" && cp -al "$B" "$W/$TB"
share "$W/$TB/share"
tar -C "$W" --owner=0 --group=0 --numeric-owner -czf "$OUT/$TB.tar.gz" "$TB"

A=$W/AppDir
rm -rf "$A" && mkdir -p "$A/usr/lib"
cp -al "$B" "$A/usr/lib/agent-burn-desktop"
cp tools/licenses/NOTICE-AppImage-runtime.txt "$A/usr/lib/agent-burn-desktop/licenses/"   # le runtime n'est que là
share "$A/usr/share"
mv "$A/usr/share/metainfo/$APPID.metainfo.xml" "$A/usr/share/metainfo/$APPID.appdata.xml"   # nom cherché par appimagetool
install -m 755 linux/AppRun "$A/AppRun"
cp "linux/$APPID.desktop" "$W/icons/hicolor/256x256/apps/$APPID.png" "$A/"
# -n : AppStream déjà validé plus haut, hors ligne ; appimagetool, lui, testerait les URL en ligne.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$T/appimagetool" -n --runtime-file "$T/runtime-x86_64" "$A" "$OUT/$TB.AppImage"

(cd "$OUT" && sha256sum -- *.tar.gz *.AppImage *.deb *.rpm >SHA256SUMS)
step "OK"
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
