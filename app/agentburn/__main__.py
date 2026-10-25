# Agent Burn pour Windows : icône de notification, popover et dashboard sur le CLI agent-burn, avec
# les QML du module Quickshell. Avec AGENT_BURN_FAKE_DIR, les appels du CLI (summary, harness) sont
# servis par l'app elle-même, sans Qt : faux agent-burn des tests et du selftest gelé.
import argparse
import datetime
import json
import os
import shutil
import sys
import time
import traceback
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)


def fake_cli(args):
    """Fixture décalée pour finir aujourd'hui, compte Claude relevé maintenant ; None : pas un appel du CLI."""
    src = os.environ.get("AGENT_BURN_FAKE_DIR")
    # --version aussi : « À propos » ne doit pas lancer une 2e app quand AGENT_BURN_BIN est l'exe lui-même.
    if not src or not args or args[0] not in ("summary", "harness", "--version"):
        return None
    out = os.fdopen(1, "wb", closefd=False)   # sys.stdout vaut None dans l'exe fenêtré
    if args[0] == "--version":
        out.write(b"agent-burn (fixtures)\n")
        out.flush()
        return 0
    path = Path(src) / ("summary-live.json" if args[0] == "summary" else f"harness-{args[1] if len(args) > 1 else ''}.json")
    if not path.is_file():
        return 2
    shift = datetime.date.today() - datetime.date(2026, 10, 23)   # jour de capture des fixtures

    def shifted(o):
        if isinstance(o, dict):
            return {k: (datetime.date.fromisoformat(v) + shift).isoformat()
                    if k in ("date", "weekStart", "from", "to") and isinstance(v, str) else shifted(v)
                    for k, v in o.items()}
        return [shifted(x) for x in o] if isinstance(o, list) else o

    report = shifted(json.loads(path.read_text(encoding="utf-8")))
    account = report.get("claudeAccount")
    if account:   # relevé « maintenant » ; les resets gardent leur écart au relevé
        delta = int(time.time() * 1000) - account["observedAtMs"]
        for o in [account, *account.get("scoped", [])]:
            for k, v in o.items():
                if k.endswith("AtMs") and isinstance(v, (int, float)):
                    o[k] = v + delta
    out.write(json.dumps(report, ensure_ascii=False).encode("utf-8"))
    out.flush()
    return 0


def main():
    code = fake_cli(sys.argv[1:])
    if code is not None:
        return code
    parser = argparse.ArgumentParser(prog="AgentBurn", description="Consommation Claude Code et limites en direct.")
    parser.add_argument("--selftest", metavar="DIR", help="rendu des vues dans DIR (PNG + selftest.json)")
    parser.add_argument("--show", choices=("popover", "dashboard"), help="dev : cette fenêtre seule, sans icône")
    args = parser.parse_args()
    if args.selftest:
        # Vrai moteur de rendu : le moteur logiciel ignorerait masques et ombres. Hors écran sauf sous
        # Windows, où la plateforme offscreen n'a pas de fenêtre native pour D3D11 (captures vides).
        if sys.platform != "win32":
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        os.environ.setdefault("QT_QUICK_BACKEND", "rhi")
    if "AGENT_BURN_BIN" not in os.environ:   # lu par Burn.qml au chargement
        exe = "agent-burn.exe" if sys.platform == "win32" else "agent-burn"   # bundle Linux de test : sans .exe
        os.environ["AGENT_BURN_BIN"] = (str(Path(sys.executable).parent / "bin" / exe) if FROZEN
                                        else shutil.which("agent-burn") or str(Path.home() / ".local" / "bin" / "agent-burn"))
    data = os.environ.get("AGENT_BURN_DATA") or (Path(os.environ["APPDATA"]) / "AgentBurn" if sys.platform == "win32"
                                                 else Path.home() / ".local" / "share" / "agent-burn-win-dev")
    if not args.selftest:
        return run(args, data)
    try:
        return run(args, data)
    except Exception:   # exe fenêtré : sinon boîte modale du bootloader, build bloqué jusqu'au délai
        traceback.print_exc()
        return 1


def run(args, data):
    import getpass

    from PySide6.QtCore import (QCoreApplication, QFileInfo, QMetaObject, QPoint, Qt, QtMsgType, QTimer, QUrl,
                                qInstallMessageHandler)
    from PySide6.QtGui import QFontDatabase, QGuiApplication, QIcon
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtQuick import QQuickWindow
    from PySide6.QtWidgets import QApplication, QFileIconProvider, QSystemTrayIcon

    from agentburn import runtime, shim, tray

    mode = "selftest" if args.selftest else args.show or "tray"
    QCoreApplication.setApplicationName("AgentBurn")
    QQuickWindow.setDefaultAlphaBuffer(True)   # popover transparent autour de sa carte
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)   # dashboard fermé : l'icône de notification reste

    server = None
    if mode == "tray":
        name = f"AgentBurn-{getpass.getuser()}"
        # Avant connectToServer : l'instance déjà lancée la reçoit aussitôt, puis demande le premier plan.
        if sys.platform == "win32":
            from agentburn import platform_win
            platform_win.allow_foreground()
        probe = QLocalSocket()
        probe.connectToServer(name)
        if probe.waitForConnected(1000):   # déjà lancée : elle ouvre son dashboard, on s'arrête là
            probe.disconnectFromServer()
            return 0
        QLocalServer.removeServer(name)   # socket laissé par une instance plantée (Unix)
        server = QLocalServer()
        server.listen(name)
        if not QSystemTrayIcon.isSystemTrayAvailable():
            print("Pas de zone de notification : dashboard seul (--show popover|dashboard en dev).", file=sys.stderr)
            mode = "dashboard"

    base = Path(sys._MEIPASS) if FROZEN else Path(__file__).resolve().parents[1]
    for font in sorted((base / "fonts").glob("*.ttf")):   # absent en dev : police du système
        QFontDatabase.addApplicationFont(str(font))
    app.setWindowIcon(QFileIconProvider().icon(QFileInfo(sys.executable)) if FROZEN   # icône de l'exe
                      else QIcon(str(Path(__file__).resolve().parents[2] / "assets" / "agent-burn.png")))

    problems = {"qmlErrors": [], "warnings": []}
    if mode == "selftest":
        def collect(kind, context, message):
            print(message, file=sys.stderr)
            # Avertissements QML seulement : la plateforme hors écran signale ses limites (raise()…).
            qml = (context.category in ("qml", "js") or context.category.startswith(("qt.qml", "qt.quick"))
                   or (context.file or "").endswith(".qml"))
            if qml and kind not in (QtMsgType.QtDebugMsg, QtMsgType.QtInfoMsg):
                problems["warnings"].append(message)
        qInstallMessageHandler(collect)

    qml = runtime.assemble()
    shim.register(qml, data)
    engine = QQmlApplicationEngine()
    engine.warnings.connect(lambda errors: problems["qmlErrors"].extend(e.toString() for e in errors))
    engine.load(QUrl.fromLocalFile(str(qml / "Main.qml")))
    if not engine.rootObjects():
        return 1
    root = engine.rootObjects()[0]
    pop, dash = root.property("popover"), root.property("dashboard")

    # Dashboard centré, réduit sur les petits écrans (sa taille minimale l'emporte).
    area = QGuiApplication.primaryScreen().availableGeometry()
    dash.resize(min(1200, area.width() - 48), min(800, area.height() - 48))
    dash.setPosition(area.center() - QPoint(dash.width() // 2, dash.height() // 2))

    if mode == "selftest":
        from agentburn import selftest
        code = selftest.run(root, Path(args.selftest), problems)
        del engine   # QML détruit avant les objets Python du shim : pas d'erreurs de bindings à la sortie
        return code

    if sys.platform == "win32":
        from agentburn import platform_win
        hints = QGuiApplication.styleHints()

        def title_bar():
            platform_win.dark_title_bar(int(dash.winId()), hints.colorScheme() != Qt.ColorScheme.Light)

        title_bar()
        hints.colorSchemeChanged.connect(title_bar)

    if mode == "tray":
        icon = tray.Tray(root)  # noqa: F841 (gardée en vie jusqu'à la sortie)
    else:
        # Sans icône, l'app vit tant qu'une fenêtre est ouverte. 500 ms : Burn.openDashboard referme
        # puis rouvre la fenêtre pour la ramener devant.
        def quit_if_hidden(*_):
            QTimer.singleShot(500, lambda: pop.isVisible() or dash.isVisible() or app.quit())

        pop.visibleChanged.connect(quit_if_hidden)
        dash.visibleChanged.connect(quit_if_hidden)
        if mode == "popover":
            tray.open_popover(pop, None)
            QMetaObject.invokeMethod(pop, "open")
        else:
            QMetaObject.invokeMethod(root, "openDashboard")
    if server:   # 2e lancement de l'app : le dashboard de celle-ci s'ouvre
        server.newConnection.connect(lambda: (server.nextPendingConnection().deleteLater(),
                                              QMetaObject.invokeMethod(root, "openDashboard")))
    code = app.exec()
    del engine
    return code


if __name__ == "__main__":
    sys.exit(main())
