# App hicolor icons from assets/agent-burn.png: python icons.py SOURCE DIR ID
# → DIR/hicolor/<n>x<n>/apps/ID.png. Never upscaled: the source is 256 px, so no 512.
import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QImage

SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)

src, out, app_id = sys.argv[1:]
image = QImage(src)
if image.isNull() or image.width() != image.height():
    sys.exit(f"{src}: square image expected")
for n in (n for n in SIZES if n <= image.width()):
    path = Path(out, "hicolor", f"{n}x{n}", "apps", f"{app_id}.png")
    path.parent.mkdir(parents=True, exist_ok=True)
    scaled = image.scaled(n, n, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
    if not scaled.save(str(path)):
        sys.exit(f"{path}: cannot write")
