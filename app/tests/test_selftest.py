# Tests du contrôle des captures du selftest : vide, d'une seule couleur (fenêtre non rendue, transparente),
# mauvaise taille (fenêtre × devicePixelRatio), coin transparent d'une fenêtre opaque, capture correcte.
#   cd desktop/agent-burn/app && python -m unittest discover -s tests -v
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import gui  # noqa: E402

from PySide6.QtCore import QSize, Qt  # noqa: E402
from PySide6.QtGui import QColor, QImage, QPainter  # noqa: E402

from agentburn.selftest import flaw  # noqa: E402


def image(w, h, fill=Qt.transparent, card=True):
    img = QImage(w, h, QImage.Format.Format_ARGB32_Premultiplied)
    img.fill(fill)
    if card:   # une carte dessinée au milieu
        p = QPainter(img)
        p.fillRect(w // 4, h // 4, w // 2, h // 2, QColor("#363638"))
        p.end()
    return img


class Capture(unittest.TestCase):
    def setUp(self):
        gui()

    def test_good_captures(self):
        self.assertEqual(flaw(image(200, 100), QSize(200, 100), 1, False), "")          # popover : bords transparents
        self.assertEqual(flaw(image(300, 150, QColor("#1c1c1e")), QSize(200, 100), 1.5, True), "")   # 1,5 ×
        self.assertEqual(flaw(image(152, 77), QSize(101, 51), 1.5, False), "")           # arrondi de Qt

    def test_blank_or_single_colour(self):
        self.assertEqual(flaw(QImage(), QSize(200, 100), 1, False), "capture vide")
        self.assertEqual(flaw(image(200, 100, card=False), QSize(200, 100), 1, False), "une seule couleur")
        self.assertEqual(flaw(image(200, 100, QColor("#1c1c1e"), card=False), QSize(200, 100), 1, True),
                         "une seule couleur")

    def test_size_other_than_window_times_ratio(self):
        self.assertEqual(flaw(image(200, 100), QSize(200, 100), 2, False), "200×100 au lieu de 400×200")

    def test_opaque_window_drawn_in_a_corner(self):
        # Hors écran à 1,5 × : contenu 1× dans le coin haut gauche d'une image à la bonne taille.
        img = image(300, 150, Qt.transparent, card=False)
        p = QPainter(img)
        p.fillRect(0, 0, 200, 100, QColor("#1c1c1e"))
        p.fillRect(20, 20, 50, 20, QColor("#f5f5f7"))
        p.end()
        self.assertEqual(flaw(img, QSize(200, 100), 1.5, True), "coin bas droit transparent")
        self.assertEqual(flaw(img, QSize(200, 100), 1.5, False), "")


if __name__ == "__main__":
    unittest.main()
