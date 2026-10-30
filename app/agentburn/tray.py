# System tray icon: % left of the tightest limit on a badge tinted by pace
# (the Linux bar's pill); click = popover or dashboard (setting), double-click =
# dashboard, middle click = refresh, right click = menu with the status on top.
import logging
import time

from PySide6.QtCore import QMetaObject, QObject, QPoint, QRect, QRectF, QSize, Qt, QTimer, Q_ARG
from PySide6.QtGui import QCursor, QFont, QGuiApplication, QIcon, QPainter, QPainterPath, QPixmap, QTransform
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

GAP = 16   # card ↔ taskbar; = PopoverWindow's shadow margin (pad), nothing spills onto it
# Actual icon sizes by display scale (100% → 16 px … 200% → 32 px): each one
# drawn at its size, never scaled.
SIZES = (16, 20, 24, 28, 32, 40, 48, 64)
LINES = 3   # status lines at the top of the menu (Main.menuLines)
log = logging.getLogger("agentburn.tray")


def place(icon, screen, avail, card):
    """Top-left corner of the card against the icon, on the taskbar side, and that edge (Qt.Edge)."""
    left, top = avail.x(), avail.y()
    right, bottom = left + avail.width(), top + avail.height()   # exclusive edges
    cx, cy = icon.x() + icon.width() // 2, icon.y() + icon.height() // 2   # QRect.center() rounds down
    if bottom < screen.y() + screen.height():
        edge = Qt.BottomEdge
    elif top > screen.y():
        edge = Qt.TopEdge
    elif left > screen.x():
        edge = Qt.LeftEdge
    elif right < screen.x() + screen.width():
        edge = Qt.RightEdge
    else:   # auto-hidden bar: the edge closest to the icon
        gaps = {Qt.BottomEdge: bottom - cy, Qt.TopEdge: cy - top, Qt.LeftEdge: cx - left, Qt.RightEdge: right - cx}
        edge = min(gaps, key=gaps.get)
    x = cx - card.width() // 2
    y = cy - card.height() // 2
    if edge == Qt.BottomEdge:
        y = min(bottom, icon.y()) - GAP - card.height()
    elif edge == Qt.TopEdge:
        y = max(top, icon.y() + icon.height()) + GAP
    elif edge == Qt.LeftEdge:
        x = max(left, icon.x() + icon.width()) + GAP
    else:
        x = min(right, icon.x()) - GAP - card.width()
    x = max(left + GAP, min(x, right - GAP - card.width()))
    y = max(top + GAP, min(y, bottom - GAP - card.height()))
    return QPoint(x, y), edge


def _fit(text, family, weight, rect):
    """Outline of the text, scaled to rect and centered in it."""
    font = QFont(family)
    font.setPixelSize(64)
    font.setWeight(weight)
    path = QPainterPath()
    path.addText(0, 0, font, text)
    path.setFillRule(Qt.WindingFill)   # overlapping outlines (variable fonts): no holes
    b = path.boundingRect()
    s = min(rect.width() / b.width(), rect.height() / b.height())
    t = QTransform().translate(rect.center().x(), rect.center().y()).scale(s, s).translate(-b.center().x(), -b.center().y())
    return t.map(path)


def pixmap(n, remaining, tone):
    """Icon of n px: % left on a tinted badge (stale reading: gray tint), readable from
    16 px on a light or dark bar, where digits drawn over the flame blur; without
    data, a solid gray flame (dimmed, it got lost on the taskbar)."""
    pm = QPixmap(n, n)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    if remaining < 0:
        p.fillPath(_fit("\uf06d", "JetBrainsMono Nerd Font", QFont.Normal, QRectF(0, 0, n, n)), tone)  # fire
    else:
        p.setPen(Qt.NoPen)
        p.setBrush(tone)
        p.drawRoundedRect(QRectF(0, 0, n, n), n / 5, n / 5)
        # Segoe UI Black (the dotted zero of JetBrains Mono blurs at 16 px), rounded like Math.round
        # as in the pill; black or white by the tint's luminance (not its HSL lightness), equal-contrast
        # threshold ≈ 0.18: the highest contrast for the 8 Colors tints.
        digits = _fit(str(int(remaining + 0.5)), "Segoe UI", QFont.Black, QRectF(n * 0.08, n * 0.2, n * 0.84, n * 0.6))
        y = 0.2126 * tone.redF() ** 2.2 + 0.7152 * tone.greenF() ** 2.2 + 0.0722 * tone.blueF() ** 2.2
        p.fillPath(digits, Qt.black if y > 0.18 else Qt.white)
    p.end()
    return pm


def open_popover(pop, icon):
    """Places the popover against the icon (or the pointer: icon tucked in the overflow menu). On
    Wayland the compositor ignores the requested position (and the pointer stays at 0,0): shown as is, its
    height capped by the screen it shows on."""
    wayland = QGuiApplication.platformName() == "wayland"
    r = icon if icon is not None and icon.isValid() else QRect(QCursor.pos(), QSize(1, 1))
    screen = pop.screen() if wayland else QGuiApplication.screenAt(r.center()) or QGuiApplication.primaryScreen()
    avail = screen.availableGeometry()
    pad = pop.property("pad")
    pop.setProperty("maxHeight", avail.height() - 2 * GAP)   # before reading the height: if taller, the card scrolls
    if wayland:
        return
    pos, edge = place(r, screen.geometry(), avail, QSize(pop.width() - 2 * pad, pop.height() - 2 * pad))
    pop.setScreen(screen)
    pop.setPosition(pos - QPoint(pad, pad))
    pop.setProperty("edge", edge.value)


class Tray(QObject):
    """Icon and its menu. Created even without a system tray; the tray is rechecked every 5 s: host
    appearing after the app (panel started later, AppIndicator extension enabled), gone or back (panel
    restarted). The icon is recreated on xcb when a host appears."""

    def __init__(self, root, settings, desktop, updater):
        super().__init__()
        self.root, self.settings, self.desktop, self.updater = root, settings, desktop, updater
        self.pop = root.property("popover")
        menu = self.menu = QMenu()
        self.lines = [menu.addAction("") for _ in range(LINES)]   # status: disabled lines
        for line in self.lines:
            line.setEnabled(False)
        menu.addSeparator()
        self.upgrade = menu.addAction("", lambda: updater.update())   # shown while an update is available
        menu.addAction("Open popover", self.popover)
        menu.addAction("Open dashboard", self.dashboard)
        menu.addAction("Refresh", self.refresh)
        menu.addSeparator()
        boot = self.boot = menu.addAction("Start at login")
        boot.setCheckable(True)
        boot.setEnabled(settings.property("autostartAvailable"))   # dev: no installed exe to launch
        boot.triggered.connect(lambda on: settings.setProperty("autostart", on))
        menu.addAction("Settings…", lambda: self.open_settings("general"))
        menu.addAction("Logs", lambda: desktop.openLogs())
        menu.addAction("About", lambda: self.open_settings("about"))
        menu.addSeparator()
        menu.addAction("Quit", QApplication.quit)
        # Check mark reread on opening (the installer or the desktop may have changed it); lines kept up to date.
        menu.aboutToShow.connect(lambda: boot.setChecked(settings.property("autostart")))
        root.menuLinesChanged.connect(self.show_lines)
        self.show_lines()

        for name in ("remainingChanged", "toneChanged"):
            getattr(root, name).connect(self.paint)
        root.tooltipChanged.connect(self.tip)
        # Placed again when its height or its screen changes (Wayland: the one chosen by the compositor).
        follow = lambda *_: self.pop.isVisible() and open_popover(self.pop, self.icon.geometry())  # noqa: E731
        self.pop.heightChanged.connect(follow)
        self.pop.screenChanged.connect(follow)
        self.icon = None
        self.dock()
        self.docked = QSystemTrayIcon.isSystemTrayAvailable()
        desktop.setTrayAvailable(self.docked)
        self.timer = QTimer(self, interval=5000, timeout=self.recheck)
        self.timer.start()
        self.notified = ""   # last version announced by a notification (needs the icon)
        updater.changed.connect(self.show_update)
        self.show_update()

    def dock(self):
        """(Re)creates the icon: on xcb, an icon created without a system tray stays on XEmbed and never
        registers with the SNI host that appears later."""
        if self.icon:
            self.icon.hide()
            self.icon.deleteLater()
        self.icon = QSystemTrayIcon(self)
        self.icon.setContextMenu(self.menu)
        self.icon.activated.connect(self.clicked)
        self.paint()
        self.tip()
        self.icon.show()

    def recheck(self):
        available = QSystemTrayIcon.isSystemTrayAvailable()
        if available == self.docked:
            return
        log.info("system tray %s", "available" if available else "gone")
        if available and QGuiApplication.platformName() == "xcb":   # Wayland: re-registered by itself, nothing to redo
            self.dock()
        self.docked = available
        self.desktop.setTrayAvailable(available)   # missing: closing the last window quits the app

    def paint(self):
        icon = QIcon()
        for n in SIZES:
            icon.addPixmap(pixmap(n, self.root.property("remaining"), self.root.property("tone")))
        self.icon.setIcon(icon)

    def tip(self):
        self.icon.setToolTip(self.root.property("tooltip"))

    def show_lines(self):
        lines = self.root.property("menuLines")
        for i, action in enumerate(self.lines):
            action.setText(lines[i] if i < len(lines) else "")
            action.setVisible(i < len(lines))

    def show_update(self):
        version, found = self.updater.property("version"), self.updater.property("state") == "available"
        self.upgrade.setText(f"Update to Agent Burn {version}")
        self.upgrade.setVisible(found)
        # Once per version and run: the menu item alone goes unnoticed.
        if found and version != self.notified:
            self.notified = version
            self.icon.showMessage(f"Agent Burn {version} is available",
                                  "Update from this icon's menu or from Settings › About.")

    def clicked(self, reason):
        R = QSystemTrayIcon.ActivationReason
        log.debug("icon: %s", reason.name)
        if reason == R.Trigger:
            self.dashboard() if self.settings.property("trayClick") == "dashboard" else self.popover()
        elif reason == R.DoubleClick:   # Windows: the 1st click already took effect
            self.dashboard()
        elif reason == R.MiddleClick:
            self.refresh()

    def popover(self):
        if self.pop.isVisible():
            QMetaObject.invokeMethod(self.pop, "dismiss")
        # This click just closed the popover (focus loss): it does not reopen it.
        elif time.time() * 1000 - self.pop.property("closedAt") > 400:
            open_popover(self.pop, self.icon.geometry())
            QMetaObject.invokeMethod(self.pop, "open")

    def dashboard(self):
        QMetaObject.invokeMethod(self.root, "openDashboard")

    def refresh(self):
        QMetaObject.invokeMethod(self.root, "refresh")

    def open_settings(self, section):
        QMetaObject.invokeMethod(self.root, "openSettings", Q_ARG(str, section))
