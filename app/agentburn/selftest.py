# --selftest DIR : rendu de l'icône, du popover, du dashboard et des réglages avec les données du CLI (vrai
# ou faux) ; selftest.json liste erreurs et avertissements QML, captures ratées et dernière erreur du CLI.
# Code 0 : tout propre, chargé et capturé.
import json
import time

from PySide6.QtCore import QCoreApplication, QEventLoop, QMetaObject
from PySide6.QtGui import QImage
from PySide6.QtQml import QQmlEngine, QQmlExpression

from agentburn import tray


def flaw(image, size, dpr, opaque):
    """Défaut d'une capture, '' si elle est bonne : vide ou d'une seule couleur (rien de rendu), taille autre
    que fenêtre × devicePixelRatio, ou coin transparent sur une fenêtre opaque (contenu rendu dans un coin)."""
    if image.isNull():
        return "capture vide"
    want = size * dpr   # arrondi de Qt (qRound), comme la capture
    if image.size() != want:
        return f"{image.width()}×{image.height()} au lieu de {want.width()}×{want.height()}"
    argb = image.convertToFormat(QImage.Format.Format_ARGB32)
    raw = bytes(argb.constBits())   # ARGB32 : 4 octets par pixel, lignes sans remplissage
    if raw == raw[:4] * (len(raw) // 4):
        return "une seule couleur"
    if opaque and argb.pixelColor(argb.width() - 1, argb.height() - 1).alpha() < 255:
        return "coin bas droit transparent"
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

    def settle(seconds):   # animations, chargements des Loader, mise en page
        wait("false", seconds)

    def save(win, name):
        # Deux captures identiques de suite : rien ne bouge plus (onglet qui glisse, fondu d'ouverture).
        last = None
        for _ in range(20):
            image = win.grabWindow()
            if last is not None and image == last:
                break
            last = image
            settle(0.15)
        else:
            captures.append(f"{name} : rendu jamais stable")
        defect = flaw(image, win.size(), win.devicePixelRatio(), win.color().alpha() == 255)
        if defect:
            captures.append(f"{name} : {defect}")
        if not image.save(str(out / name)):
            captures.append(f"{name} : non écrite")

    js("Burn.refresh(false)")   # sans attendre le 1er tour à 3 s
    loaded = wait("Burn.summary !== null && !Burn.loading", 150)
    for n in (16, 24, 32):
        if not tray.pixmap(n, root.property("remaining"), root.property("tone")).save(str(out / f"tray-{n}.png")):
            captures.append(f"tray-{n}.png : non écrite")
    codex = bool(js("!!Burn.subEntry('codex')"))   # fixtures avec Codex : son onglet et sa page aussi

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
    # Économie du forfait : harness lancés à l'ouverture.
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
    wait("Desktop.cliVersion !== ''", 10)   # version lue en tâche de fond à l'ouverture
    for i, name in enumerate(("", "-providers", "-diagnostic", "-about")):
        prefs.setProperty("section", i)
        settle(0.5)
        save(prefs, f"selftest-settings{name}.png")
    prefs.close()
    wait("!Burn.loading", 120)   # pas de CLI tué en plein run (il écrit son relevé partagé)

    cli = js("Burn.error")   # un appel du CLI en échec ne laisse aucun avertissement QML, seulement ce texte
    ok = loaded and harness and not cli and not captures and not problems["qmlErrors"] and not problems["warnings"]
    (out / "selftest.json").write_text(json.dumps({"ok": ok, **problems, "captureErrors": captures, "dataLoaded": loaded,
                                                   "cliError": cli}, ensure_ascii=False, indent=2),
                                       encoding="utf-8")
    return 0 if ok else 1
