# --selftest DIR: renders the icon, the popover, the dashboard and the settings with the CLI data (real
# or fake); selftest.json lists QML errors and warnings, failed captures and the last CLI error.
# Exit code 0: everything clean, loaded and captured.
import json
import time

from PySide6.QtCore import QCoreApplication, QEventLoop, QMetaObject
from PySide6.QtGui import QImage
from PySide6.QtQml import QQmlEngine, QQmlExpression

from agentburn import tray


def flaw(image, size, dpr, opaque):
    """Defect of a capture, '' if it is good: empty or a single color (nothing rendered), size other
    than window × devicePixelRatio, or a transparent corner on an opaque window (content rendered in a corner)."""
    if image.isNull():
        return "empty capture"
    want = size * dpr   # Qt rounding (qRound), like the capture
    if image.size() != want:
        return f"{image.width()}×{image.height()} instead of {want.width()}×{want.height()}"
    argb = image.convertToFormat(QImage.Format.Format_ARGB32)
    raw = bytes(argb.constBits())   # ARGB32: 4 bytes per pixel, rows without padding
    if raw == raw[:4] * (len(raw) // 4):
        return "single color"
    if opaque and argb.pixelColor(argb.width() - 1, argb.height() - 1).alpha() < 255:
        return "transparent bottom-right corner"
    return ""


def run(root, out, problems):
    out.mkdir(parents=True, exist_ok=True)
    context = QQmlEngine.contextForObject(root)
    captures = []

    def js(code):
        return QQmlExpression(context, root, code).evaluate()[0]

    def wait(code, seconds):
        end = time.monotonic() + seconds
        while not js(code) and time.monotonic() < end:
            QCoreApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 50)
        return bool(js(code))

    def settle(seconds):   # animations, Loader loads, layout
        wait("false", seconds)

    def save(win, name):
        # Two identical captures in a row: nothing moves anymore (sliding tab, opening fade).
        last = None
        for _ in range(20):
            image = win.grabWindow()
            if last is not None and image == last:
                break
            last = image
            settle(0.15)
        else:
            captures.append(f"{name}: rendering never stable")
        defect = flaw(image, win.size(), win.devicePixelRatio(), win.color().alpha() == 255)
        if defect:
            captures.append(f"{name}: {defect}")
        if not image.save(str(out / name)):
            captures.append(f"{name}: not written")

    js("Burn.refresh(false)")   # without waiting for the 1st round at 3 s
    loaded = wait("Burn.summary !== null && !Burn.loading", 150)
    for n in (16, 24, 32):
        if not tray.pixmap(n, root.property("remaining"), root.property("tone")).save(str(out / f"tray-{n}.png")):
            captures.append(f"tray-{n}.png: not written")
    codex = bool(js("!!Burn.subEntry('codex')"))   # fixtures with Codex: its tab and its page too

    pop = root.property("popover")
    for tab in ("claude", "general") + (("codex",) if codex else ()):
        pop.setProperty("tab", tab)
        QMetaObject.invokeMethod(pop, "open")
        settle(0.6)
        save(pop, f"popover-{tab}.png")
    QMetaObject.invokeMethod(pop, "dismiss")

    dash = root.property("dashboard")
    dash.resize(1200, 800)
    js("Burn.dashboardPage = 'all'; Burn.dashboardOpen = true")
    # Plan economics: harnesses launched on opening.
    harness = wait("!!Burn.harnesses.claude && !Burn.loading" + (" && !!Burn.harnesses.codex" if codex else ""), 60)
    settle(0.8)
    save(dash, "dashboard-all.png")
    for page in ("claude",) + (("codex",) if codex else ()):
        js(f"Burn.dashboardPage = '{page}'")
        settle(0.8)
        save(dash, f"dashboard-{page}.png")
    js("Burn.dashboardOpen = false")

    prefs = root.property("settingsWindow")
    js("openSettings('general')")
    wait("Desktop.cliVersion !== ''", 10)   # version read in the background on opening
    for i, name in enumerate(("", "-providers", "-diagnostic", "-about")):
        prefs.setProperty("section", i)
        settle(0.5)
        save(prefs, f"selftest-settings{name}.png")
    prefs.close()
    wait("!Burn.loading", 120)   # no CLI killed mid-run (it writes its shared reading)

    cli = js("Burn.error")   # a failed CLI call leaves no QML warning, only this text
    ok = loaded and harness and not cli and not captures and not problems["qmlErrors"] and not problems["warnings"]
    (out / "selftest.json").write_text(json.dumps({"ok": ok, **problems, "captureErrors": captures, "dataLoaded": loaded,
                                                   "cliError": cli}, ensure_ascii=False, indent=2),
                                       encoding="utf-8")
    return 0 if ok else 1
