# Icône de la zone de notification : % restant de la limite la plus serrée sur une pastille teintée
# selon le rythme (le pill de la barre Linux) ; clic = popover posé contre l'icône, clic droit = menu.
import os
import sys
import time

from PySide6.QtCore import QMetaObject, QPoint, QProcess, QRect, QRectF, QSize, Qt
from PySide6.QtGui import QCursor, QFont, QGuiApplication, QIcon, QPainter, QPainterPath, QPixmap, QTransform
from PySide6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from agentburn import __version__

GAP = 16   # carte ↔ barre des tâches ; = marge d'ombre (pad) de PopoverWindow, rien ne déborde dessus
# Tailles réelles de l'icône selon l'échelle d'affichage (100 % → 16 px … 200 % → 32 px) : chacune
# dessinée à sa taille, jamais mise à l'échelle.
SIZES = (16, 20, 24, 28, 32, 40, 48, 64)


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
    """Pose le popover contre l'icône (ou le pointeur : icône rangée dans le menu de débordement)."""
    r = icon if icon is not None and icon.isValid() else QRect(QCursor.pos(), QSize(1, 1))
    screen = QGuiApplication.screenAt(r.center()) or QGuiApplication.primaryScreen()
    avail = screen.availableGeometry()
    pad = pop.property("pad")
    pop.setProperty("maxHeight", avail.height() - 2 * GAP)   # avant de lire la hauteur : plus haute, la carte défile
    pos, edge = place(r, screen.geometry(), avail, QSize(pop.width() - 2 * pad, pop.height() - 2 * pad))
    pop.setScreen(screen)
    pop.setPosition(pos - QPoint(pad, pad))
    pop.setProperty("edge", edge.value)


class Tray(QSystemTrayIcon):
    def __init__(self, root):
        super().__init__()
        self.root = root
        self.pop = root.property("popover")
        menu = self.menu = QMenu()
        menu.addAction("Ouvrir le dashboard", lambda: QMetaObject.invokeMethod(root, "openDashboard"))
        menu.addAction("Rafraîchir", lambda: QMetaObject.invokeMethod(root, "refresh"))
        menu.addSeparator()
        boot = menu.addAction("Lancer au démarrage de Windows")
        boot.setCheckable(True)
        boot.setEnabled(sys.platform == "win32" and getattr(sys, "frozen", False))   # dev : pas d'exe à lancer
        if boot.isEnabled():
            from agentburn import platform_win
            boot.triggered.connect(platform_win.set_autostart)
            menu.aboutToShow.connect(lambda: boot.setChecked(platform_win.autostart()))   # l'installeur a pu l'écrire
        menu.addAction("À propos", self.about)
        menu.addSeparator()
        menu.addAction("Quitter", QApplication.quit)
        self.setContextMenu(menu)

        self.activated.connect(self.clicked)
        for name in ("remainingChanged", "toneChanged"):
            getattr(root, name).connect(self.paint)
        root.tooltipChanged.connect(lambda: self.setToolTip(root.property("tooltip")))
        self.pop.heightChanged.connect(lambda: self.pop.isVisible() and open_popover(self.pop, self.geometry()))
        self.paint()
        self.setToolTip(root.property("tooltip"))
        self.show()

    def paint(self):
        icon = QIcon()
        for n in SIZES:
            icon.addPixmap(pixmap(n, self.root.property("remaining"), self.root.property("tone")))
        self.setIcon(icon)

    def clicked(self, reason):
        if reason != QSystemTrayIcon.ActivationReason.Trigger:
            return
        if self.pop.isVisible():
            QMetaObject.invokeMethod(self.pop, "dismiss")
        # Ce clic vient de fermer le popover (perte du focus) : il ne le rouvre pas.
        elif time.time() * 1000 - self.pop.property("closedAt") > 400:
            open_popover(self.pop, self.geometry())
            QMetaObject.invokeMethod(self.pop, "open")

    def about(self):
        p = QProcess()
        p.start(os.environ["AGENT_BURN_BIN"], ["--version"])
        cli = bytes(p.readAllStandardOutput()).decode().strip() if p.waitForFinished(5000) else ""
        QMessageBox.about(None, "À propos d'Agent Burn",
                          f"Agent Burn {__version__} pour Windows\nCLI : {cli or 'introuvable'}\n\n"
                          "Consommation Claude Code et limites en direct, d'après l'app macOS agent-burn de Melvynx.")
