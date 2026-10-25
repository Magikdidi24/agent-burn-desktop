# PyInstaller (lancé par build.ps1) : AgentBurn.exe en onedir fenêtré. Le même spec construit
# un bundle Linux pour tester l'empaquetage hors Windows.
import os
import re
import sys

win = sys.platform == 'win32'
here = SPECPATH
app = os.path.join(here, 'app')
qs = os.path.join(here, '..', '..', 'config', 'quickshell')
fonts = os.path.join(app, 'fonts')
cli = os.path.join(here, 'build', 'cli', 'bin', 'agent-burn.exe' if win else 'agent-burn')

# Entrée = « python -m agentburn » : le __main__ du paquet garde ses imports relatifs une fois gelé.
entry = os.path.join(workpath, 'agentburn-main.py')
with open(entry, 'w') as f:
    f.write('import runpy\nrunpy.run_module("agentburn", run_name="__main__")\n')

# QML partagés avec le module Quickshell : lus dans le dépôt, jamais dupliqués dans git.
datas = [(os.path.join(qs, f), 'shared') for f in (
    'Burn.qml', 'BurnPopover.qml', 'BurnDashboardView.qml', 'BurnQuotaChart.qml', 'BurnBarChart.qml')]
datas += [(os.path.join(qs, 'assets', 'burn'), 'shared/assets/burn'), (os.path.join(app, 'qml'), 'qml')]
if os.path.isdir(fonts):  # rempli par build.ps1 ; absent en dev Linux (police système)
    datas.append((fonts, 'fonts'))

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
drop = re.compile(r'(?i)(Qt6?|Qt6Qml|Labs|qml/Qt|qml/QtQuick/|qml/QtQml/|qml/Qt/labs/|imageformats/(lib)?q)(%s)'
                  r'|plugins/qmltooling/' % '|'.join(unused))
a.binaries = [e for e in a.binaries if not drop.search(e[0].replace('\\', '/'))]
a.datas = [e for e in a.datas if not drop.search(e[0].replace('\\', '/'))]

pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    exclude_binaries=True,
    name='AgentBurn',
    console=False,
    upx=False,
    icon=os.path.join(here, 'assets', 'agent-burn.ico') if win else None,
    # Tout à côté de l'exe : bin/agent-burn.exe, shared/ et qml/ sont à <dossier de l'exe>/…
    contents_directory='.',
)
coll = COLLECT(exe, a.binaries, a.datas, upx=False, name='AgentBurn')
