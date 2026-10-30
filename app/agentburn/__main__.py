# Agent Burn desktop app (Windows, Linux X11 and Wayland, macOS): tray icon, popover, dashboard and settings
# on the agent-burn CLI, with the QML of the Quickshell module. With AGENT_BURN_FAKE_DIR, the CLI calls
# (summary, harness) are served by the app itself, without Qt: the fake agent-burn of the tests and of
# the frozen selftest.
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
APP_ID = "io.github.magikdidi24.AgentBurn"   # .desktop file, Wayland app_id, XDG autostart
OWN_ENV = set()   # variables set by main() for the app only
log = logging.getLogger("agentburn")


def fake_cli(args):
    """Fixture shifted to end today, Claude account read now; None: not a CLI call."""
    src = os.environ.get("AGENT_BURN_FAKE_DIR")
    # --version too: "About" must not start a 2nd app when AGENT_BURN_BIN is the exe itself.
    if not src or not args or args[0] not in ("summary", "harness", "--version"):
        return None
    out = os.fdopen(1, "wb", closefd=False)   # sys.stdout is None in the windowed exe
    if args[0] == "--version":
        out.write(b"agent-burn (fixtures)\n")
        out.flush()
        return 0
    if args[0] == "harness" and (len(args) < 2 or args[1] not in ("claude", "codex")):
        return 2   # like the real CLI; and never a fixture path taken from argv
    quota = args[0] == "harness" and args[1] == "claude" and os.environ.get("AGENT_BURN_QUOTA_ONLY") == "1"
    path = Path(src) / ("summary-live.json" if args[0] == "summary" else "quota-claude-live.json" if quota
                        else f"harness-{args[1]}.json")
    if not path.is_file():
        return 2
    if quota:   # light reading of the 5-min tick: "now", like the summary's account
        reading = json.loads(path.read_text(encoding="utf-8"))
        reading["observedAt"] = int(time.time() * 1000)
        out.write(json.dumps(reading).encode("utf-8"))
        out.flush()
        return 0
    shift = datetime.date.today() - datetime.date(2026, 10, 23)   # day the fixtures were captured

    def shifted(o):
        if isinstance(o, dict):
            return {k: (datetime.date.fromisoformat(v) + shift).isoformat()
                    if k in ("date", "weekStart", "from", "to") and isinstance(v, str) else shifted(v)
                    for k, v in o.items()}
        return [shifted(x) for x in o] if isinstance(o, list) else o

    report = shifted(json.loads(path.read_text(encoding="utf-8")))
    account = report.get("claudeAccount")
    if account:   # reading "now"; resets keep their offset from the reading
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
    parser = argparse.ArgumentParser(prog="AgentBurn", description="Claude Code usage and live limits.")
    parser.add_argument("--selftest", metavar="DIR", help="render the views into DIR (PNG + selftest.json)")
    parser.add_argument("--show", choices=("popover", "dashboard"), help="dev: this window only, without the tray icon")
    args = parser.parse_args()
    if args.selftest:
        # Real renderer: the software one would ignore masks and shadows. Offscreen except on Windows and
        # macOS, where the offscreen platform has no native window for D3D11 or Metal (empty captures).
        if sys.platform not in ("win32", "darwin"):
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        os.environ.setdefault("QT_QUICK_BACKEND", "rhi")
    # Linux: render loop without a dedicated thread. Qt 6.12's threaded one crashes in QtWaylandClient
    # (QWaylandWindow::beginFrame) while a window is shown; the app animates little, nothing is lost.
    # Offscreen (selftest): no Wayland, and the basic loop only half captures the enlarged popover there.
    # The user's setting is kept; ours is not passed to launched processes (OWN_ENV → shim.APP_VARS).
    if (sys.platform.startswith("linux") and not os.environ.get("QT_QPA_PLATFORM", "").startswith("offscreen")
            and "QSG_RENDER_LOOP" not in os.environ):
        os.environ["QSG_RENDER_LOOP"] = "basic"
        OWN_ENV.add("QSG_RENDER_LOOP")
    if "AGENT_BURN_BIN" not in os.environ:   # read by Burn.qml at load time
        exe = "agent-burn.exe" if sys.platform == "win32" else "agent-burn"   # Linux bundle: no .exe
        # Frozen: bin/ of the bundle, next to the exe (macOS: Contents/Frameworks/bin).
        os.environ["AGENT_BURN_BIN"] = (str(Path(sys._MEIPASS) / "bin" / exe) if FROZEN
                                        else shutil.which("agent-burn") or str(Path.home() / ".local" / "bin" / "agent-burn"))
    if not args.selftest:
        return run(args)
    try:
        return run(args)
    except Exception:   # windowed exe: otherwise a bootloader modal dialog, build stuck until the timeout
        log.critical("selftest aborted", exc_info=True)
        return 1


def register(qml, data, cfg, desktop, upd):
    """Quickshell types of the shim and singletons of the app (import AgentBurn, desktop QML only). Only
    once per process: a 2nd registration makes the types incompatible (PySide)."""
    from PySide6.QtQml import qmlRegisterSingletonInstance

    from agentburn import diagnostics, settings, shim, updater
    shim.register(qml, data)
    qmlRegisterSingletonInstance(settings.Settings, "AgentBurn", 1, 0, "Settings", cfg)
    qmlRegisterSingletonInstance(diagnostics.Desktop, "AgentBurn", 1, 0, "Desktop", desktop)
    qmlRegisterSingletonInstance(updater.Updater, "AgentBurn", 1, 0, "Updater", upd)


def fit(w, width, height, area):
    """Window of width×height centered in area, shrunk on a small screen (48 px margin for the frame)
    but never below its minimum size; screen smaller than that minimum: minimum brought down to the
    screen, the window fits there whole (the content scrolls) instead of overflowing it."""
    from PySide6.QtCore import QPoint, QSize

    room = area.size() - QSize(48, 48)
    w.setMinimumSize(w.minimumSize().boundedTo(room))
    w.resize(QSize(width, height).boundedTo(room).expandedTo(w.minimumSize()))
    w.setPosition(area.topLeft() + QPoint((area.width() - w.width()) // 2, (area.height() - w.height()) // 2))


def quit_when_closed(app, dash, prefs, cfg, desktop):
    """Windows closed: the app stays in the system tray, unless no icon is in place or the setting refuses
    it for the dashboard, closed before or after the settings. 500 ms: Burn.openDashboard closes then
    reopens the window to bring it to the front."""
    from PySide6.QtCore import QTimer

    asked = False   # dashboard closed with closeToTray off: quit once everything is closed

    def check():
        if not (dash.isVisible() or prefs.isVisible()) and (asked or not desktop.property("trayAvailable")):
            app.quit()

    def dash_changed(*_):
        nonlocal asked
        asked = not dash.isVisible() and (asked or not cfg.closeToTray)   # reopened: the intent is dropped
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

    from agentburn import diagnostics, logs, paths, runtime, settings, shim, tray, updater

    shim.APP_VARS.update(OWN_ENV)

    mode = "selftest" if args.selftest else args.show or "tray"
    QCoreApplication.setApplicationName("AgentBurn")

    # Log before anything else: Qt and QML messages, CLI, exceptions. Selftest: log in its directory
    # (build artifact) and on stderr, also for the frozen exe.
    problems = {"qmlErrors": [], "warnings": []}

    def collect(kind, context, message):
        # QML warnings only: the offscreen platform reports its limits (raise()…).
        qml = (context.category in ("qml", "js") or context.category.startswith(("qt.qml", "qt.quick"))
               or (context.file or "").endswith(".qml"))
        if qml and kind not in (QtMsgType.QtDebugMsg, QtMsgType.QtInfoMsg):
            problems["warnings"].append(message)

    stderr = sys.stderr
    if stderr is None and mode == "selftest":   # windowed exe: stderr redirected by build.ps1
        stderr = open(2, "w", encoding="utf-8", errors="replace", closefd=False)
    logs.setup(Path(args.selftest) if args.selftest else paths.log_dir(),
               stderr if not FROZEN or mode == "selftest" else None, collect if mode == "selftest" else None)
    if os.environ.get("AGENT_BURN_FAKE_DIR") and mode != "selftest":
        log.warning("AGENT_BURN_FAKE_DIR set outside the selftest: a fake CLI may serve fixtures")

    QQuickWindow.setDefaultAlphaBuffer(True)   # popover transparent around its card
    QGuiApplication.setDesktopFileName(APP_ID)   # Wayland app_id: portals, icon and taskbar grouping
    argv = list(sys.argv)
    # Light/dark theme through the XDG portal: accurate under GNOME (Qt otherwise takes gtk3 there), followed
    # live under KDE. Not in the selftest: blocking D-Bus call at startup, pointless offscreen.
    if sys.platform.startswith("linux") and not os.environ.get("QT_QPA_PLATFORMTHEME") and mode != "selftest":
        argv += ["-platformtheme", "xdgdesktopportal"]
    app = QApplication(argv)
    app.setQuitOnLastWindowClosed(False)   # dashboard closed: the tray icon stays

    server = None
    if mode == "tray":
        name = paths.instance_name()
        # Before connectToServer: the running instance receives the connection at once, then asks for the foreground.
        if sys.platform == "win32":
            from agentburn import platform_win
            platform_win.allow_foreground()
        # Lock first: two simultaneous launches each probed before the other's listen(), and
        # listen() is not exclusive on Windows (two servers on the same pipe).
        lock_file = Path(name + ".lock") if sys.platform != "win32" else paths.cache_dir() / f"{name}.lock"
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        lock = QLockFile(str(lock_file))   # held until exit
        lock.setStaleLockTime(0)   # stale only if its process is dead
        # Lock cannot be taken (read-only directory…): start anyway, as without a lock.
        locked = lock.tryLock(0) or lock.error() != QLockFile.LockError.LockFailedError
        probe = QLocalSocket()
        for attempt in range(1 if locked else 30):   # loser: the winner's server is up in a moment
            time.sleep(0.1 if attempt else 0)
            probe.connectToServer(name)
            if probe.waitForConnected(1000):   # already running: it opens its dashboard, we stop here
                probe.disconnectFromServer()
                log.info("already running: opened the dashboard of the running instance")
                return 0
        if not locked:
            log.warning("already running (lock %s) but unreachable: exiting", lock_file)
            return 0
        QLocalServer.removeServer(name)   # socket left by a crashed instance (Unix)
        server = QLocalServer()
        server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        if not server.listen(name):
            log.warning("single instance disabled (%s): %s", name, server.errorString())

    base = Path(sys._MEIPASS) if FROZEN else Path(__file__).resolve().parents[1]
    for font in sorted((base / "fonts").glob("*.ttf")):   # missing in dev: system font
        QFontDatabase.addApplicationFont(str(font))
    # Windows: the exe's icon; Linux: the theme's (packages), otherwise the bundled PNG (tarball, AppImage, dev).
    png = (base if FROZEN else Path(__file__).resolve().parents[2]) / "assets" / "agent-burn.png"
    app.setWindowIcon(QFileIconProvider().icon(QFileInfo(sys.executable)) if FROZEN and sys.platform == "win32"
                      else QIcon.fromTheme(APP_ID, QIcon(str(png))))

    # Settings (in memory for the selftest: same rendering everywhere) and diagnostics before the QML engine.
    system = None
    if FROZEN:   # dev: no installed exe to start at login
        if sys.platform == "win32":
            from agentburn import platform_win as system
        elif sys.platform == "darwin":
            from agentburn import platform_mac
            # The .app only, not the bare onedir folder PyInstaller leaves next to it.
            system = platform_mac if Path(sys.executable).parent.match("*.app/Contents/MacOS") else None
        else:
            from agentburn import platform_linux as system
    settings_file = None if mode == "selftest" else paths.settings_file()
    cfg = settings.Settings(settings_file, system)
    data = paths.data_dir()
    desktop = diagnostics.Desktop(os.environ["AGENT_BURN_BIN"], data, settings_file,
                                  Path(args.selftest) if args.selftest else paths.log_dir(), paths.cache_dir())
    # Frozen Windows builds only (their build-info.json target); checks start with the tray icon.
    upd = updater.Updater(desktop.buildInfo["target"], Path(sys.executable).parent, cfg)
    hints = QGuiApplication.styleHints()

    def apply_settings():
        # Native menus and dialogs; Colors.qml follows the setting itself (platforms that ignore the request).
        hints.setColorScheme({"light": Qt.ColorScheme.Light, "dark": Qt.ColorScheme.Dark}.get(cfg.theme, Qt.ColorScheme.Unknown))
        logs.debug(cfg.debugLogging)
        log.debug("settings: %s; system theme %s", {k: cfg.property(k) for k in settings.CHOICES},
                  hints.colorScheme().name)

    cfg.changed.connect(apply_settings)
    apply_settings()
    hints.colorSchemeChanged.connect(lambda scheme: log.debug("system theme: %s", scheme.name))

    qml = runtime.assemble()
    register(qml, data, cfg, desktop, upd)
    engine = QQmlApplicationEngine()
    engine.warnings.connect(lambda errors: problems["qmlErrors"].extend(e.toString() for e in errors))
    engine.load(QUrl.fromLocalFile(str(qml / "Main.qml")))
    if not engine.rootObjects():
        log.error("Main.qml not loaded: %s", "; ".join(problems["qmlErrors"]) or "see the Qt messages")
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
        log.info("selftest: %s", "; ".join(f"{k} {v}" for k, v in desktop.facts()))
        code = selftest.run(root, Path(args.selftest), problems)
        del engine   # QML destroyed before the shim's Python objects: no binding errors on exit
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
        icon = tray.Tray(root, cfg, desktop, upd)  # noqa: F841 (kept alive until exit)
        upd.start()
        if not icon.docked:   # no system tray (yet): the dashboard in the meantime
            log.warning("no system tray (%s): dashboard opened, checked again every 5 s",
                        QGuiApplication.platformName())
            QMetaObject.invokeMethod(root, "openDashboard")

        quit_when_closed(app, dash, prefs, cfg, desktop)
        if sys.platform == "darwin":
            # Opened again from Finder, Spotlight or Launchpad: macOS activates this instance (reopen event)
            # instead of starting a 2nd one. Activated with no window shown (the menu counts: a click on it
            # activates the app), the app was opened that way.
            app.applicationStateChanged.connect(lambda state: state == Qt.ApplicationState.ApplicationActive
                                                and not any(w.isVisible() for w in app.topLevelWindows())
                                                and QMetaObject.invokeMethod(root, "openDashboard"))
    else:
        # Without an icon (dev), the app lives as long as a window is open.
        def quit_if_hidden(*_):
            QTimer.singleShot(500, lambda: pop.isVisible() or dash.isVisible() or prefs.isVisible() or app.quit())

        for w in (pop, dash, prefs):
            w.visibleChanged.connect(quit_if_hidden)
        if mode == "popover":
            tray.open_popover(pop, None)
            QMetaObject.invokeMethod(pop, "open")
        else:
            QMetaObject.invokeMethod(root, "openDashboard")
    if server:   # 2nd launch of the app: this one's dashboard opens
        server.newConnection.connect(lambda: (log.debug("2nd launch: dashboard opened here"),
                                              server.nextPendingConnection().deleteLater(),
                                              QMetaObject.invokeMethod(root, "openDashboard")))
    log.info("startup: %s", "; ".join(f"{k} {v}" for k, v in desktop.facts()))
    code = app.exec()
    # CLI mid-run (it may be rewriting a renewed Claude token): wait for it to end, 5 s at most, before
    # destroying the engine kills it.
    shim.wait_for_runs(5000)
    del engine
    return code


if __name__ == "__main__":
    sys.exit(main())
