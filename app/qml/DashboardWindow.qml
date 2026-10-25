import QtQuick

// Fenêtre « Agent Burn » (dashboard de l'app Mac) : instance unique, ouverte par Burn.dashboardOpen
// (popover, menu de l'icône, 2e lancement de l'app) ; la croix ou Échap la referment, __main__ décide
// alors entre rester dans la zone de notification et quitter.
Window {
    id: win
    title: "Agent Burn"
    width: 1200
    height: 800
    minimumWidth: 900
    minimumHeight: 600
    color: Colors.background
    visible: Burn.dashboardOpen

    // Fermée par la croix : le binding de visible tient, seul l'état est à remettre.
    onClosing: Burn.dashboardOpen = false

    // poke() ne relance que si les données ont plus de 60 s, loadHarness() plus de 5 min ; au rythme des réglages.
    function load() {
        Burn.poke();
        for (const a of Burn.agents)
            if (Burn.subEntry(a)) Burn.loadHarness(a);
    }
    // Rouverte par Burn.openDashboard (fermée puis rouverte) : repasse au premier plan.
    onVisibleChanged: if (visible) {
        raise();
        requestActivate();
        load();
    }
    Timer { interval: Burn.refreshInterval; repeat: true; running: win.visible; onTriggered: win.load() }

    // Contenu créé à l'ouverture seulement : fenêtre fermée = ni bindings ni horloge.
    Loader {
        anchors.fill: parent
        active: win.visible
        focus: true
        sourceComponent: BurnDashboardView {
            focus: true
            Keys.onEscapePressed: Burn.dashboardOpen = false
        }
    }
}
