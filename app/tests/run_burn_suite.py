# Fidélité du shim : la suite headless de Burn.qml écrite pour qs (burn-suite : shell.qml + faux CLI)
# tourne ici sous PySide6 et doit donner les mêmes résultats. Code 1 si une assertion échoue ou si la
# suite n'aboutit pas.
#   [BURN_TEST=corrupt|timeout] python tests/run_burn_suite.py [<dossier>]
# <dossier> : celui d'un autre shell.qml (défaut : burn-suite) ; son Burn.qml, s'il en a un (mutant),
# remplace celui du dépôt.
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parent))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QCoreApplication, QMetaObject, QTimer, QUrl, qInstallMessageHandler  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine  # noqa: E402

from agentburn import runtime, shim  # noqa: E402

suite = Path(sys.argv[1] if len(sys.argv) > 1 else here / "burn-suite").resolve()
tmp = Path(tempfile.mkdtemp(prefix="burn-suite-"))
QCoreApplication.setApplicationName("AgentBurn")
app = QGuiApplication(sys.argv)

# Faux CLI et fixtures datées du jour, comme sous qs.
(tmp / "fake").mkdir()
subprocess.run([sys.executable, "-I", str(here / "burn-suite" / "fake" / "gen.py"), str(tmp / "fake")], check=True)
os.environ["AGENT_BURN_BIN"] = str(tmp / "fake" / "agent-burn")

# Dossier QML de l'app, plus le shell.qml de la suite.
qml = tmp / "qml"
shutil.copytree(runtime.assemble(), qml)
shutil.copyfile(suite / "shell.qml", qml / "shell.qml")
if (suite / "Burn.qml").is_file():
    shutil.copyfile(suite / "Burn.qml", qml / "Burn.qml")

# `qs ipc call <cible> <fonction>` : un faux qs note l'appel, puis on appelle la fonction déclarée
# dans l'IpcHandler de cette cible, comme le ferait qs.
handlers = []
created = shim.IpcHandler.__init__


def track(self, parent=None):
    created(self, parent)
    handlers.append(self)


shim.IpcHandler.__init__ = track
calls = tmp / "ipc.log"
(tmp / "bin").mkdir()
(tmp / "bin" / "qs").write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\n')
(tmp / "bin" / "qs").chmod(0o755)
os.environ["PATH"] = f"{tmp / 'bin'}{os.pathsep}{os.environ['PATH']}"


def ipc():
    if not calls.exists():
        return
    lines = calls.read_text().splitlines()
    calls.unlink()
    for words in (line.split() for line in lines):
        target, function = words[words.index("call") + 1:][:2]
        for h in handlers:
            if h.property("target") == target:
                QMetaObject.invokeMethod(h, function)


poll = QTimer(interval=100, timeout=ipc)
poll.start()

failed = []   # échecs de chaque ligne « RESULT: N ok, M échec(s) » (une seule attendue)


def log(mode, context, message):
    print(message, flush=True)
    failed.extend(int(m) for m in re.findall(r"^RESULT: \d+ ok, (\d+) échec", message))


qInstallMessageHandler(log)
shim.register(qml, tmp / "data")
engine = QQmlEngine()
engine.quit.connect(app.quit)
component = QQmlComponent(engine, QUrl.fromLocalFile(str(qml / "shell.qml")))
root = component.create()
if root is None:
    print("\n".join(e.toString() for e in component.errors()), flush=True)
    sys.exit(1)
code = app.exec()
del root, component, engine
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(0 if code == 0 and failed == [0] else 1)
