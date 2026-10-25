# PyInstaller, windowed onedir: AgentBurn.exe on Windows (build.ps1), agent-burn-desktop on Linux
# (linux/build.sh, slimmed bundle for every distro).
import os
import re
import sys

win = sys.platform == 'win32'
here = SPECPATH
app = os.path.join(here, 'app')
shared = os.path.join(here, 'shared')
fonts = os.path.join(app, 'fonts')
name = 'AgentBurn' if win else 'agent-burn-desktop'
cli = os.path.join(here, 'build', *(('cli', 'bin', 'agent-burn.exe') if win else ('cli-linux', 'bin', 'agent-burn')))
extra = os.path.join(here, 'build', 'bundle-extra')   # build-info.json and licenses/, written by the build script
version = os.path.join(here, 'build', 'version_info.txt')   # written by build.ps1

sys.path.insert(0, app)
from agentburn.runtime import SHARED  # noqa: E402  (the list the app assembles at launch)

# Entry = "python -m agentburn": the package's __main__ keeps its relative imports once frozen.
entry = os.path.join(workpath, 'agentburn-main.py')
with open(entry, 'w') as f:
    f.write('import runpy\nrunpy.run_module("agentburn", run_name="__main__")\n')

# Shared QML (shared/), in the same place where runtime.sources() looks for it once frozen.
datas = [(os.path.join(shared, f), 'shared') for f in SHARED]
datas += [(os.path.join(shared, 'assets', 'burn'), 'shared/assets/burn'), (os.path.join(app, 'qml'), 'qml'),
          (os.path.join(here, 'assets', 'agent-burn.png'), 'assets')]  # window icon outside the icon theme (Linux)
if os.path.isdir(fonts):  # filled by the build script; missing in dev (system font)
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

# The QtQml hook bundles the WHOLE PySide6 qml directory and the libraries its plugins pull in
# (WebEngine alone ≈ 200 MB): the Qt modules the app never imports are removed by name.
# QtTest stays (light, a selftest can use it). A module removed by mistake makes the build selftest fail.
unused = ('WebEngine', 'WebView', 'WebChannel', 'WebSockets', '3D', 'Quick3D', 'Scene2D', 'Scene3D',
          'Multimedia', 'SpatialAudio', 'TextToSpeech', 'Charts', 'Graphs', 'DataVisualization', 'Pdf',
          'Location', 'Positioning', 'Sensors', 'VirtualKeyboard', 'Scxml', 'StateMachine', 'RemoteObjects',
          'Sql', 'LocalStorage', 'StyleKit')
# Image plugins the app (PNG only, read by QtGui) never opens: without them, neither libjpeg, libtiff nor
# libwebp is shipped (their licenses require a notice). opengl32sw (Windows, Mesa + LLVM): software OpenGL,
# useless to Qt Quick, which renders with Direct3D 11.
drop = re.compile(r'(?i)(Qt6?|Qt6Qml|Labs|qml/Qt|qml/QtQuick/|qml/QtQml/|qml/Qt/labs/|imageformats/(lib)?q)(%s)'
                  r'|plugins/qmltooling/|imageformats/(lib)?q(jpeg|tiff|webp|gif|tga|wbmp|icns)\b|opengl32sw'
                  % '|'.join(unused))
if not win:
    # Every distro provides them (package dependencies): the bundled bookworm ones hid the system ones
    # (libstdc++ too old: Mesa GLX broken on Fedora 44, Debian 13, Ubuntu 24.04, Arch, Tumbleweed).
    # A family goes as a whole: bookworm's libxkbcommon-x11 on top of Arch's libxkbcommon crashed.
    # What remains: libpython, libbz2 (name differs between distros) and the libxcb-* (xcb-util often missing).
    # A library pulled in by a module removed below (Mesa's libgbm, libudev…) stays bundled with nobody
    # asking for it and still hides the system one: list it here too.
    system = re.compile(
        r'(^|/)(libstdc\+\+|libgcc_s|libfontconfig|libfreetype|libexpat|libharfbuzz|libgraphite2|libpng16'
        r'|libglib-2\.0|libgio-2\.0|libgobject-2\.0|libgmodule-2\.0|libgthread-2\.0|libffi|libpcre2-8|libpcre'
        r'|libdbus-1|libsystemd|libX[\w-]*|libxkbcommon|libxkbcommon-x11|libz|libzstd|liblzma|liblz4'
        r'|libbrotli\w*|libcrypto|libssl|libgssapi_krb5|libkrb5\w*|libk5crypto|libcom_err|libkeyutils'
        r'|libmount|libblkid|libselinux|libcap|libgcrypt|libgpg-error|libbsd|libmd|libxml2|libudev|libxkbfile'
        r'|libgbm)\.so')
    # platformthemes/libqgtk3 pulls in GTK 3 (the app follows the theme through xdgdesktopportal); the
    # compositor-side Wayland plugins pull in libwayland-server, useless to a client.
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
    # Everything next to the exe: bin/agent-burn(.exe), shared/ and qml/ are in <exe directory>/…
    contents_directory='.',
)
coll = COLLECT(exe, a.binaries, a.datas, upx=False, name=name)
