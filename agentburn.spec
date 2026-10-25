# PyInstaller, onedir fenêtré : AgentBurn.exe sous Windows (build.ps1), agent-burn-desktop sous Linux
# (linux/build.sh, bundle allégé pour toutes les distros).
import os
import re
import sys

win = sys.platform == 'win32'
here = SPECPATH
app = os.path.join(here, 'app')
qs = os.path.join(here, '..', '..', 'config', 'quickshell')
fonts = os.path.join(app, 'fonts')
name = 'AgentBurn' if win else 'agent-burn-desktop'
cli = os.path.join(here, 'build', *(('cli', 'bin', 'agent-burn.exe') if win else ('cli-linux', 'bin', 'agent-burn')))
extra = os.path.join(here, 'build', 'bundle-extra')   # build-info.json et licenses/, posés par le script de build
version = os.path.join(here, 'build', 'version_info.txt')   # écrit par build.ps1

sys.path.insert(0, app)
from agentburn.runtime import SHARED  # noqa: E402  (la liste que l'app assemble au lancement)

# Entrée = « python -m agentburn » : le __main__ du paquet garde ses imports relatifs une fois gelé.
entry = os.path.join(workpath, 'agentburn-main.py')
with open(entry, 'w') as f:
    f.write('import runpy\nrunpy.run_module("agentburn", run_name="__main__")\n')

# QML partagés avec le module Quickshell : lus dans le dépôt, jamais dupliqués dans git.
datas = [(os.path.join(qs, f), 'shared') for f in SHARED]
datas += [(os.path.join(qs, 'assets', 'burn'), 'shared/assets/burn'), (os.path.join(app, 'qml'), 'qml'),
          (os.path.join(here, 'assets', 'agent-burn.png'), 'assets')]  # icône de fenêtre hors thème (Linux)
if os.path.isdir(fonts):  # rempli par le script de build ; absent en dev (police système)
    datas.append((fonts, 'fonts'))
if os.path.isdir(extra):
    datas.append((extra, '.'))

a = Analysis(
    [entry],
    pathex=[app],
    hiddenimports=['agentburn.__main__'],
    binaries=[(cli, 'bin')] if os.path.isfile(cli) else [],
    datas=datas,
)

# Le hook QtQml embarque TOUT le dossier qml de PySide6 et les bibliothèques que ses plugins tirent
# (WebEngine seul ≈ 200 Mo) : on retire par nom les modules Qt que l'app n'importe jamais.
# QtTest reste (léger, un selftest peut s'en servir). Un module retiré à tort fait échouer le selftest du build.
unused = ('WebEngine', 'WebView', 'WebChannel', 'WebSockets', '3D', 'Quick3D', 'Scene2D', 'Scene3D',
          'Multimedia', 'SpatialAudio', 'TextToSpeech', 'Charts', 'Graphs', 'DataVisualization', 'Pdf',
          'Location', 'Positioning', 'Sensors', 'VirtualKeyboard', 'Scxml', 'StateMachine', 'RemoteObjects',
          'Sql', 'LocalStorage', 'StyleKit')
# Plugins d'images que l'app (PNG seulement, lus par QtGui) n'ouvre jamais : sans eux, ni libjpeg, ni libtiff, ni
# libwebp ne sont livrés (leurs licences exigent une notice). opengl32sw (Windows, Mesa + LLVM) : OpenGL logiciel,
# inutile à Qt Quick qui rend en Direct3D 11.
drop = re.compile(r'(?i)(Qt6?|Qt6Qml|Labs|qml/Qt|qml/QtQuick/|qml/QtQml/|qml/Qt/labs/|imageformats/(lib)?q)(%s)'
                  r'|plugins/qmltooling/|imageformats/(lib)?q(jpeg|tiff|webp|gif|tga|wbmp|icns)\b|opengl32sw'
                  % '|'.join(unused))
if not win:
    # Toutes les distros les fournissent (dépendances des paquets) : celles de bookworm embarquées masquaient
    # celles du système (libstdc++ trop vieux : GLX de Mesa KO sur Fedora 44, Debian 13, Ubuntu 24.04, Arch,
    # Tumbleweed). Une famille part en entier : libxkbcommon-x11 de bookworm sur le libxkbcommon d'Arch plantait.
    # Restent libpython, libbz2 (nom différent selon les distros) et les libxcb-* (xcb-util souvent absent).
    # Une bibliothèque tirée par un module retiré plus bas (libgbm de Mesa, libudev…) reste embarquée sans
    # personne pour la demander et masque quand même celle du système : à lister ici aussi.
    system = re.compile(
        r'(^|/)(libstdc\+\+|libgcc_s|libfontconfig|libfreetype|libexpat|libharfbuzz|libgraphite2|libpng16'
        r'|libglib-2\.0|libgio-2\.0|libgobject-2\.0|libgmodule-2\.0|libgthread-2\.0|libffi|libpcre2-8|libpcre'
        r'|libdbus-1|libsystemd|libX[\w-]*|libxkbcommon|libxkbcommon-x11|libz|libzstd|liblzma|liblz4'
        r'|libbrotli\w*|libcrypto|libssl|libgssapi_krb5|libkrb5\w*|libk5crypto|libcom_err|libkeyutils'
        r'|libmount|libblkid|libselinux|libcap|libgcrypt|libgpg-error|libbsd|libmd|libxml2|libudev|libxkbfile'
        r'|libgbm)\.so')
    # platformthemes/libqgtk3 tire GTK 3 (l'app suit le thème par xdgdesktopportal) ; les plugins Wayland
    # côté compositeur tirent libwayland-server, inutile à un client.
    drop = re.compile(drop.pattern + r'|platformthemes/libqgtk3|wayland-graphics-integration-server/'
                      r'|WaylandCompositor|qml/QtWayland/Compositor')
    a.binaries = [e for e in a.binaries if not system.search(e[0])]
a.binaries = [e for e in a.binaries if not drop.search(e[0].replace('\\', '/'))]
a.datas = [e for e in a.datas if not drop.search(e[0].replace('\\', '/'))]

pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    exclude_binaries=True,
    name=name,
    console=False,
    upx=False,
    icon=os.path.join(here, 'assets', 'agent-burn.ico') if win else None,
    version=version if win and os.path.isfile(version) else None,
    # Tout à côté de l'exe : bin/agent-burn(.exe), shared/ et qml/ sont à <dossier de l'exe>/…
    contents_directory='.',
)
coll = COLLECT(exe, a.binaries, a.datas, upx=False, name=name)
