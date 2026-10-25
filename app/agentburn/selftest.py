# --selftest DIR : rendu de l'icône, du popover et du dashboard avec les données du CLI (vrai ou faux) ;
# selftest.json liste erreurs et avertissements QML et la dernière erreur du CLI. Code 0 : tout propre,
# chargé et capturé.
import json
import time

from PySide6.QtCore import QCoreApplication, QEventLoop, QMetaObject
from PySide6.QtQml import QQmlEngine, QQmlExpression

from agentburn import tray


def run(root, out, problems):
    out.mkdir(parents=True, exist_ok=True)
    context = QQmlEngine.contextForObject(root)

    def js(code):
        return QQmlExpression(context, root, code).evaluate()[0]

    def wait(code, seconds):
        end = time.monotonic() + seconds
        while not js(code) and time.monotonic() < end:
            QCoreApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 50)
        return bool(js(code))

    def settle(seconds):   # animations, chargements des Loader, mise en page
        wait("false", seconds)

    def save(image, name):   # image nulle : vue que la plateforme n'a pas pu rendre
        if not image.save(str(out / name)):
            problems["warnings"].append(f"capture vide ou non écrite : {name}")

    js("Burn.refresh(false)")   # sans attendre le 1er tour à 3 s
    loaded = wait("Burn.summary !== null && !Burn.loading", 150)
    for n in (16, 24, 32):
        save(tray.pixmap(n, root.property("remaining"), root.property("tone")), f"tray-{n}.png")

    pop = root.property("popover")
    for tab in ("claude", "general"):
        pop.setProperty("tab", tab)
        QMetaObject.invokeMethod(pop, "open")
        settle(0.6)
        save(pop.grabWindow(), f"popover-{tab}.png")
    QMetaObject.invokeMethod(pop, "dismiss")

    dash = root.property("dashboard")
    dash.resize(1200, 800)
    js("Burn.dashboardPage = 'all'; Burn.dashboardOpen = true")
    harness = wait("!!Burn.harnesses.claude && !Burn.loading", 60)   # économie du forfait : harness lancé à l'ouverture
    settle(0.8)
    save(dash.grabWindow(), "dashboard-all.png")
    js("Burn.dashboardPage = 'claude'")
    settle(0.8)
    save(dash.grabWindow(), "dashboard-claude.png")
    js("Burn.dashboardOpen = false")
    wait("!Burn.loading", 120)   # pas de CLI tué en plein run (il écrit son relevé partagé)

    cli = js("Burn.error")   # un appel du CLI en échec ne laisse aucun avertissement QML, seulement ce texte
    ok = loaded and harness and not cli and not problems["qmlErrors"] and not problems["warnings"]
    (out / "selftest.json").write_text(json.dumps({"ok": ok, **problems, "dataLoaded": loaded, "cliError": cli},
                                                  ensure_ascii=False, indent=2),
                                       encoding="utf-8")
    return 0 if ok else 1
