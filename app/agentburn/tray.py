# Icône de la zone de notification : % restant de la limite la plus serrée sur une pastille teintée
# selon le rythme (le pill de la barre Linux) ; clic = aperçu ou dashboard (réglage), double-clic =
# dashboard, clic du milieu = rafraîchir, clic droit = menu avec l'état en tête.
import time

from PySide6.QtCore import QMetaObject, QObject, QPoint, QRect, QRectF, QSize, Qt, QTimer, Q_ARG
from PySide6.QtGui import QCursor, QFont, QGuiApplication, QIcon, QPainter, QPainterPath, QPixmap, QTransform
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

GAP = 16   # carte ↔ barre des tâches ; = marge d'ombre (pad) de PopoverWindow, rien ne déborde dessus
# Tailles réelles de l'icône selon l'échelle d'affichage (100 % → 16 px … 200 % → 32 px) : chacune
# dessinée à sa taille, jamais mise à l'échelle.
SIZES = (16, 20, 24, 28, 32, 40, 48, 64)
LINES = 3   # lignes d'état en tête du menu (Main.menuLines)


def place(icon, screen, avail, card):
    """Coin haut-gauche de la carte contre l'icône, côté barre des tâches, et ce bord (Qt.Edge)."""
    left, top = avail.x(), avail.y()
    right, bottom = left + avail.width(), top + avail.height()   # bords exclusifs
    cx, cy = icon.x() + icon.width() // 2, icon.y() + icon.height() // 2   # QRect.center() arrondit en dessous
    if bottom < screen.y() + screen.height():
        edge = Qt.BottomEdge
    elif top > screen.y():
        edge = Qt.TopEdge
    elif left > screen.x():
        edge = Qt.LeftEdge
    elif right < screen.x() + screen.width():
        edge = Qt.RightEdge
    else:   # barre masquée automatiquement : le bord le plus proche de l'icône
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
    """Contour du texte, à l'échelle de rect et centré dedans."""
    font = QFont(family)
    font.setPixelSize(64)
    font.setWeight(weight)
    path = QPainterPath()
    path.addText(0, 0, font, text)
    path.setFillRule(Qt.WindingFill)   # contours qui se chevauchent (polices variables) : pas de trous
    b = path.boundingRect()
    s = min(rect.width() / b.width(), rect.height() / b.height())
    t = QTransform().translate(rect.center().x(), rect.center().y()).scale(s, s).translate(-b.center().x(), -b.center().y())
    return t.map(path)


def pixmap(n, remaining, tone):
    """Icône de n px : % restant sur une pastille teintée (relevé ancien : teinte grise), lisible dès
    16 px sur barre claire ou sombre, là où des chiffres posés sur la flamme se brouillent ; sans
    données, flamme grise pleine (atténuée, elle se perdait sur la barre des tâches)."""
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
        # Segoe UI Black (le zéro pointé de JetBrains Mono se brouille à 16 px), arrondi de Math.round
        # comme le pill ; noir ou blanc selon la luminance de la teinte (pas sa clarté HSL), seuil d'égal
        # contraste ≈ 0,18 : le plus contrasté pour les 8 teintes de Colors.
        digits = _fit(str(int(remaining + 0.5)), "Segoe UI", QFont.Black, QRectF(n * 0.08, n * 0.2, n * 0.84, n * 0.6))
        y = 0.2126 * tone.redF() ** 2.2 + 0.7152 * tone.greenF() ** 2.2 + 0.0722 * tone.blueF() ** 2.2
        p.fillPath(digits, Qt.black if y > 0.18 else Qt.white)
    p.end()
    return pm


def open_popover(pop, icon):
    """Pose le popover contre l'icône (ou le pointeur : icône rangée dans le menu de débordement). Sous
    Wayland le compositeur ignore la position demandée (et le pointeur reste à 0,0) : affiché tel quel."""
    r = icon if icon is not None and icon.isValid() else QRect(QCursor.pos(), QSize(1, 1))
    screen = QGuiApplication.screenAt(r.center()) or QGuiApplication.primaryScreen()
    avail = screen.availableGeometry()
    pad = pop.property("pad")
    pop.setProperty("maxHeight", avail.height() - 2 * GAP)   # avant de lire la hauteur : plus haute, la carte défile
    if QGuiApplication.platformName() == "wayland":
        return
    pos, edge = place(r, screen.geometry(), avail, QSize(pop.width() - 2 * pad, pop.height() - 2 * pad))
    pop.setScreen(screen)
    pop.setPosition(pos - QPoint(pad, pad))
    pop.setProperty("edge", edge.value)


class Tray(QObject):
    """Icône et son menu. Créée même sans zone de notification : revérifiée toutes les 5 s pendant 2 min
    (panneau lancé après l'app à l'ouverture de session), l'icône recréée sous xcb dès qu'un hôte apparaît."""

    def __init__(self, root, settings, desktop):
        super().__init__()
        self.root, self.settings, self.desktop = root, settings, desktop
        self.pop = root.property("popover")
        menu = self.menu = QMenu()
        self.lines = [menu.addAction("") for _ in range(LINES)]   # état : lignes inactives
        for line in self.lines:
            line.setEnabled(False)
        menu.addSeparator()
        menu.addAction("Ouvrir l'aperçu", self.popover)
        menu.addAction("Ouvrir le dashboard", self.dashboard)
        menu.addAction("Rafraîchir", self.refresh)
        menu.addSeparator()
        boot = self.boot = menu.addAction("Lancer à l'ouverture de session")
        boot.setCheckable(True)
        boot.setEnabled(settings.property("autostartAvailable"))   # dev : pas d'exe installé à lancer
        boot.triggered.connect(lambda on: settings.setProperty("autostart", on))
        menu.addAction("Paramètres…", lambda: self.open_settings("general"))
        menu.addAction("Journaux", lambda: desktop.openLogs())
        menu.addAction("À propos", lambda: self.open_settings("about"))
        menu.addSeparator()
        menu.addAction("Quitter", QApplication.quit)
        # Coche relue à l'ouverture (l'installeur ou le bureau a pu la changer) ; lignes tenues à jour.
        menu.aboutToShow.connect(lambda: boot.setChecked(settings.property("autostart")))
        root.menuLinesChanged.connect(self.show_lines)
        self.show_lines()

        for name in ("remainingChanged", "toneChanged"):
            getattr(root, name).connect(self.paint)
        root.tooltipChanged.connect(self.tip)
        self.pop.heightChanged.connect(lambda: self.pop.isVisible() and open_popover(self.pop, self.icon.geometry()))
        self.icon = None
        self.dock()
        self.docked = QSystemTrayIcon.isSystemTrayAvailable()
        desktop.setTrayAvailable(self.docked)
        self.waited = 0
        self.timer = QTimer(self, interval=5000, timeout=self.recheck)
        if not self.docked:
            self.timer.start()

    def dock(self):
        """(Re)crée l'icône : sous xcb, une icône créée sans zone de notification reste sur XEmbed et ne
        s'enregistre jamais auprès de l'hôte SNI apparu ensuite."""
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
        self.waited += 5
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.timer.stop()
            if QGuiApplication.platformName() == "xcb":   # Wayland : déjà enregistrée seule, rien à refaire
                self.dock()
            self.docked = True
            self.desktop.setTrayAvailable(True)
        elif self.waited >= 120:
            self.timer.stop()

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

    def clicked(self, reason):
        R = QSystemTrayIcon.ActivationReason
        if reason == R.Trigger:
            self.dashboard() if self.settings.property("trayClick") == "dashboard" else self.popover()
        elif reason == R.DoubleClick:   # Windows : le 1er clic a déjà fait son effet
            self.dashboard()
        elif reason == R.MiddleClick:
            self.refresh()

    def popover(self):
        if self.pop.isVisible():
            QMetaObject.invokeMethod(self.pop, "dismiss")
        # Ce clic vient de fermer le popover (perte du focus) : il ne le rouvre pas.
        elif time.time() * 1000 - self.pop.property("closedAt") > 400:
            open_popover(self.pop, self.icon.geometry())
            QMetaObject.invokeMethod(self.pop, "open")

    def dashboard(self):
        QMetaObject.invokeMethod(self.root, "openDashboard")

    def refresh(self):
        QMetaObject.invokeMethod(self.root, "refresh")

    def open_settings(self, section):
        QMetaObject.invokeMethod(self.root, "openSettings", Q_ARG(str, section))
