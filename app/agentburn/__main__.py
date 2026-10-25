# Agent Burn de bureau (Windows, Linux X11 et Wayland) : icône de notification, popover, dashboard et
# réglages sur le CLI agent-burn, avec les QML du module Quickshell. Avec AGENT_BURN_FAKE_DIR, les
# appels du CLI (summary, harness) sont servis par l'app elle-même, sans Qt : faux agent-burn des tests
# et du selftest gelé.
import argparse
import datetime
import json
import logging
import os
import shutil
import sys
import time
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)
APP_ID = "io.github.magikdidi24.AgentBurn"   # fichier .desktop, app_id Wayland, autostart XDG
OWN_ENV = set()   # variables posées par main() pour l'app seule
log = logging.getLogger("agentburn")


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
    if args[0] == "harness" and (len(args) < 2 or args[1] not in ("claude", "codex")):
        return 2   # comme le vrai CLI ; et jamais un chemin de fixture tiré d'argv
    quota = args[0] == "harness" and args[1] == "claude" and os.environ.get("AGENT_BURN_QUOTA_ONLY") == "1"
    path = Path(src) / ("summary-live.json" if args[0] == "summary" else "quota-claude-live.json" if quota
                        else f"harness-{args[1]}.json")
    if not path.is_file():
        return 2
    if quota:   # relevé léger du tick de 5 min : « maintenant », comme le compte du summary
        reading = json.loads(path.read_text(encoding="utf-8"))
        reading["observedAt"] = int(time.time() * 1000)
        out.write(json.dumps(reading).encode("utf-8"))
        out.flush()
        return 0
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
    # Linux : boucle de rendu sans fil dédié. Celle à fil de Qt 6.12 plante dans QtWaylandClient
    # (QWaylandWindow::beginFrame) pendant l'affichage d'une fenêtre ; l'app anime peu, rien n'y est perdu.
    # Hors écran (selftest), rien de Wayland, et la boucle basique y capture à moitié le popover agrandi.
    # Réglage de l'utilisateur gardé ; le nôtre ne passe pas aux process lancés (OWN_ENV → shim.APP_VARS).
    if (sys.platform.startswith("linux") and not os.environ.get("QT_QPA_PLATFORM", "").startswith("offscreen")
            and "QSG_RENDER_LOOP" not in os.environ):
        os.environ["QSG_RENDER_LOOP"] = "basic"
        OWN_ENV.add("QSG_RENDER_LOOP")
    if "AGENT_BURN_BIN" not in os.environ:   # lu par Burn.qml au chargement
        exe = "agent-burn.exe" if sys.platform == "win32" else "agent-burn"   # bundle Linux : sans .exe
        os.environ["AGENT_BURN_BIN"] = (str(Path(sys.executable).parent / "bin" / exe) if FROZEN
                                        else shutil.which("agent-burn") or str(Path.home() / ".local" / "bin" / "agent-burn"))
    if not args.selftest:
        return run(args)
    try:
        return run(args)
    except Exception:   # exe fenêtré : sinon boîte modale du bootloader, build bloqué jusqu'au délai
        log.critical("selftest interrompu", exc_info=True)
        return 1


def register(qml, data, cfg, desktop):
    """Types Quickshell du shim et singletons de l'app (import AgentBurn, QML de bureau seulement). Une
    seule fois par process : un 2e enregistrement rend les types incompatibles (PySide)."""
    from PySide6.QtQml import qmlRegisterSingletonInstance

    from agentburn import diagnostics, settings, shim
    shim.register(qml, data)
    qmlRegisterSingletonInstance(settings.Settings, "AgentBurn", 1, 0, "Settings", cfg)
    qmlRegisterSingletonInstance(diagnostics.Desktop, "AgentBurn", 1, 0, "Desktop", desktop)


def fit(w, width, height, area):
    """Fenêtre de width×height centrée dans area, réduite sur un petit écran (48 px de marge pour le cadre)
    mais jamais sous sa taille minimale ; écran plus petit que ce minimum : minimum ramené à l'écran, la
    fenêtre y tient entière (le contenu défile) au lieu d'en déborder."""
    from PySide6.QtCore import QPoint, QSize

    room = area.size() - QSize(48, 48)
    w.setMinimumSize(w.minimumSize().boundedTo(room))
    w.resize(QSize(width, height).boundedTo(room).expandedTo(w.minimumSize()))
    w.setPosition(area.topLeft() + QPoint((area.width() - w.width()) // 2, (area.height() - w.height()) // 2))


def quit_when_closed(app, dash, prefs, cfg, desktop):
    """Fenêtres fermées : l'app reste dans la zone de notification, sauf sans icône posée ou si le réglage le
    refuse pour le dashboard, fermé avant ou après les réglages. 500 ms : Burn.openDashboard referme puis
    rouvre la fenêtre pour la ramener devant."""
    from PySide6.QtCore import QTimer

    asked = False   # dashboard fermé avec closeToTray désactivé : quitter une fois tout fermé

    def check():
        if not (dash.isVisible() or prefs.isVisible()) and (asked or not desktop.property("trayAvailable")):
            app.quit()

    def dash_changed(*_):
        nonlocal asked
        asked = not dash.isVisible() and (asked or not cfg.closeToTray)   # rouvert : l'intention tombe
        if not dash.isVisible():
            QTimer.singleShot(500, check)

    dash.visibleChanged.connect(dash_changed)
    prefs.visibleChanged.connect(lambda *_: prefs.isVisible() or QTimer.singleShot(500, check))


def run(args):
    from PySide6.QtCore import QCoreApplication, QFileInfo, QLockFile, QMetaObject, Qt, QtMsgType, QTimer, QUrl
    from PySide6.QtGui import QFontDatabase, QGuiApplication, QIcon
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtQuick import QQuickWindow
    from PySide6.QtWidgets import QApplication, QFileIconProvider

    from agentburn import diagnostics, logs, paths, runtime, settings, shim, tray

    shim.APP_VARS.update(OWN_ENV)

    mode = "selftest" if args.selftest else args.show or "tray"
    QCoreApplication.setApplicationName("AgentBurn")

    # Journal avant tout le reste : messages Qt et QML, CLI, exceptions. Selftest : journal dans son
    # dossier (artefact du build) et sur stderr, aussi pour l'exe gelé.
    problems = {"qmlErrors": [], "warnings": []}

    def collect(kind, context, message):
        # Avertissements QML seulement : la plateforme hors écran signale ses limites (raise()…).
        qml = (context.category in ("qml", "js") or context.category.startswith(("qt.qml", "qt.quick"))
               or (context.file or "").endswith(".qml"))
        if qml and kind not in (QtMsgType.QtDebugMsg, QtMsgType.QtInfoMsg):
            problems["warnings"].append(message)

    stderr = sys.stderr
    if stderr is None and mode == "selftest":   # exe fenêtré : stderr redirigé par build.ps1
        stderr = open(2, "w", encoding="utf-8", errors="replace", closefd=False)
    logs.setup(Path(args.selftest) if args.selftest else paths.log_dir(),
               stderr if not FROZEN or mode == "selftest" else None, collect if mode == "selftest" else None)
    if os.environ.get("AGENT_BURN_FAKE_DIR") and mode != "selftest":
        log.warning("AGENT_BURN_FAKE_DIR défini hors selftest : un faux CLI peut servir des fixtures")

    QQuickWindow.setDefaultAlphaBuffer(True)   # popover transparent autour de sa carte
    QGuiApplication.setDesktopFileName(APP_ID)   # app_id Wayland : portails, icône et groupement de la barre
    argv = list(sys.argv)
    # Thème clair/sombre par le portail XDG : juste sous GNOME (Qt y prend sinon gtk3), suivi en direct
    # sous KDE. Pas en selftest : appel D-Bus bloquant au démarrage, sans intérêt hors écran.
    if sys.platform.startswith("linux") and not os.environ.get("QT_QPA_PLATFORMTHEME") and mode != "selftest":
        argv += ["-platformtheme", "xdgdesktopportal"]
    app = QApplication(argv)
    app.setQuitOnLastWindowClosed(False)   # dashboard fermé : l'icône de notification reste

    server = None
    if mode == "tray":
        name = paths.instance_name()
        # Avant connectToServer : l'instance déjà lancée la reçoit aussitôt, puis demande le premier plan.
        if sys.platform == "win32":
            from agentburn import platform_win
            platform_win.allow_foreground()
        # Verrou d'abord : deux lancements simultanés sondaient chacun avant le listen() de l'autre, et
        # listen() n'est pas exclusif sous Windows (deux serveurs sur un même pipe).
        lock_file = Path(name + ".lock") if sys.platform != "win32" else paths.cache_dir() / f"{name}.lock"
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        lock = QLockFile(str(lock_file))   # tenu jusqu'à la sortie
        lock.setStaleLockTime(0)   # périmé seulement si son process est mort
        # Verrou impossible à poser (dossier en lecture seule…) : démarrage quand même, comme sans verrou.
        locked = lock.tryLock(0) or lock.error() != QLockFile.LockError.LockFailedError
        probe = QLocalSocket()
        for attempt in range(1 if locked else 30):   # perdant : le serveur du gagnant arrive dans l'instant
            time.sleep(0.1 if attempt else 0)
            probe.connectToServer(name)
            if probe.waitForConnected(1000):   # déjà lancée : elle ouvre son dashboard, on s'arrête là
                probe.disconnectFromServer()
                log.info("déjà lancée : dashboard de l'instance en cours ouvert")
                return 0
        if not locked:
            log.warning("déjà lancée (verrou %s) mais injoignable : arrêt", lock_file)
            return 0
        QLocalServer.removeServer(name)   # socket laissé par une instance plantée (Unix)
        server = QLocalServer()
        server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        if not server.listen(name):
            log.warning("instance unique inactive (%s) : %s", name, server.errorString())

    base = Path(sys._MEIPASS) if FROZEN else Path(__file__).resolve().parents[1]
    for font in sorted((base / "fonts").glob("*.ttf")):   # absent en dev : police du système
        QFontDatabase.addApplicationFont(str(font))
    # Windows : icône de l'exe ; Linux : celle du thème (paquets), sinon le PNG embarqué (tarball, AppImage, dev).
    png = (base if FROZEN else Path(__file__).resolve().parents[2]) / "assets" / "agent-burn.png"
    app.setWindowIcon(QFileIconProvider().icon(QFileInfo(sys.executable)) if FROZEN and sys.platform == "win32"
                      else QIcon.fromTheme(APP_ID, QIcon(str(png))))

    # Réglages (en mémoire pour le selftest : rendu identique partout) et diagnostic avant le moteur QML.
    system = None
    if FROZEN:   # dev : pas d'exe installé à lancer à l'ouverture de session
        if sys.platform == "win32":
            from agentburn import platform_win as system
        else:
            from agentburn import platform_linux as system
    settings_file = None if mode == "selftest" else paths.settings_file()
    cfg = settings.Settings(settings_file, system)
    data = paths.data_dir()
    desktop = diagnostics.Desktop(os.environ["AGENT_BURN_BIN"], data, settings_file,
                                  Path(args.selftest) if args.selftest else paths.log_dir(), paths.cache_dir())
    hints = QGuiApplication.styleHints()

    def apply_settings():
        # Menus et boîtes natifs ; Colors.qml suit le réglage lui-même (plateformes qui ignorent la demande).
        hints.setColorScheme({"light": Qt.ColorScheme.Light, "dark": Qt.ColorScheme.Dark}.get(cfg.theme, Qt.ColorScheme.Unknown))
        logs.debug(cfg.debugLogging)
        log.debug("réglages : %s ; thème du système %s", {k: cfg.property(k) for k in settings.CHOICES},
                  hints.colorScheme().name)

    cfg.changed.connect(apply_settings)
    apply_settings()
    hints.colorSchemeChanged.connect(lambda scheme: log.debug("thème du système : %s", scheme.name))

    qml = runtime.assemble()
    register(qml, data, cfg, desktop)
    engine = QQmlApplicationEngine()
    engine.warnings.connect(lambda errors: problems["qmlErrors"].extend(e.toString() for e in errors))
    engine.load(QUrl.fromLocalFile(str(qml / "Main.qml")))
    if not engine.rootObjects():
        log.error("Main.qml non chargé : %s", "; ".join(problems["qmlErrors"]) or "voir les messages Qt")
        return 1
    root = engine.rootObjects()[0]
    desktop.attach(root)
    desktop.probeCli()
    pop, dash, prefs = root.property("popover"), root.property("dashboard"), root.property("settingsWindow")

    area = QGuiApplication.primaryScreen().availableGeometry()
    fit(dash, 1200, 800, area)
    fit(prefs, 620, 680, area)

    if mode == "selftest":
        from agentburn import selftest
        log.info("selftest : %s", "; ".join(f"{k} {v}" for k, v in desktop.facts()))
        code = selftest.run(root, Path(args.selftest), problems)
        del engine   # QML détruit avant les objets Python du shim : pas d'erreurs de bindings à la sortie
        return code

    if sys.platform == "win32":
        from agentburn import platform_win

        def title_bars():
            dark = cfg.theme == "dark" or cfg.theme != "light" and hints.colorScheme() != Qt.ColorScheme.Light
            for w in (dash, prefs):
                platform_win.dark_title_bar(int(w.winId()), dark)

        title_bars()
        hints.colorSchemeChanged.connect(title_bars)
        cfg.changed.connect(title_bars)

    if mode == "tray":
        icon = tray.Tray(root, cfg, desktop)  # noqa: F841 (gardée en vie jusqu'à la sortie)
        if not icon.docked:   # pas (encore) de zone de notification : le dashboard en attendant
            log.warning("pas de zone de notification (%s) : dashboard ouvert, revérifiée toutes les 5 s",
                        QGuiApplication.platformName())
            QMetaObject.invokeMethod(root, "openDashboard")

        quit_when_closed(app, dash, prefs, cfg, desktop)
    else:
        # Sans icône (dev), l'app vit tant qu'une fenêtre est ouverte.
        def quit_if_hidden(*_):
            QTimer.singleShot(500, lambda: pop.isVisible() or dash.isVisible() or prefs.isVisible() or app.quit())

        for w in (pop, dash, prefs):
            w.visibleChanged.connect(quit_if_hidden)
        if mode == "popover":
            tray.open_popover(pop, None)
            QMetaObject.invokeMethod(pop, "open")
        else:
            QMetaObject.invokeMethod(root, "openDashboard")
    if server:   # 2e lancement de l'app : le dashboard de celle-ci s'ouvre
        server.newConnection.connect(lambda: (log.debug("2e lancement : dashboard ouvert ici"),
                                              server.nextPendingConnection().deleteLater(),
                                              QMetaObject.invokeMethod(root, "openDashboard")))
    log.info("démarrage : %s", "; ".join(f"{k} {v}" for k, v in desktop.facts()))
    code = app.exec()
    # CLI en plein run (il réécrit peut-être un jeton Claude renouvelé) : sa fin attendue, 5 s au plus, avant
    # que la destruction du moteur ne le tue.
    shim.wait_for_runs(5000)
    del engine
    return code


if __name__ == "__main__":
    sys.exit(main())
