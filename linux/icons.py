# Icônes hicolor de l'app depuis assets/agent-burn.png : python icons.py SOURCE DOSSIER ID
# → DOSSIER/hicolor/<n>x<n>/apps/ID.png. Jamais d'agrandissement : la source fait 256 px, donc pas de 512.
import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QImage

SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)

src, out, app_id = sys.argv[1:]
image = QImage(src)
if image.isNull() or image.width() != image.height():
    sys.exit(f"{src} : image carrée attendue")
for n in (n for n in SIZES if n <= image.width()):
    path = Path(out, "hicolor", f"{n}x{n}", "apps", f"{app_id}.png")
    path.parent.mkdir(parents=True, exist_ok=True)
    scaled = image.scaled(n, n, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
    if not scaled.save(str(path)):
        sys.exit(f"{path} : écriture impossible")
