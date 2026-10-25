import QtQuick

// "Agent Burn" window (the Mac app's dashboard): single instance, opened by Burn.dashboardOpen
// (popover, tray icon menu, 2nd launch of the app); the close button or Esc closes it, then __main__
// decides between staying in the system tray and quitting.
Window {
    id: win
    title: "Agent Burn"
    width: 1200
    height: 800
    minimumWidth: 900
    minimumHeight: 600
    color: Colors.background
    visible: Burn.dashboardOpen

    signal settingsRequested()   // "Settings" button of the shared view, opened by Main.qml

    // Closed with the close button: the visible binding holds, only the state needs resetting.
    onClosing: Burn.dashboardOpen = false

    // poke() reruns only if the data is over 60 s old, loadHarness() over 5 min; at the settings interval.
    function load() {
        Burn.poke();
        for (const a of Burn.agents)
            if (Burn.subEntry(a)) Burn.loadHarness(a);
    }
    // Reopened by Burn.openDashboard (closed then reopened): comes back to the front.
    onVisibleChanged: if (visible) {
        raise();
        requestActivate();
        load();
    }
    Timer { interval: Burn.refreshInterval; repeat: true; running: win.visible; onTriggered: win.load() }

    // Content created only on opening: closed window = no bindings, no clock.
    Loader {
        anchors.fill: parent
        active: win.visible
        focus: true
        sourceComponent: BurnDashboardView {
            focus: true
            settingsAvailable: true
            onSettingsRequested: win.settingsRequested()
            Keys.onEscapePressed: Burn.dashboardOpen = false
        }
    }
}
