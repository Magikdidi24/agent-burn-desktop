import QtQuick

// Racine de l'app Windows : popover, dashboard et état de l'icône de notification (lu par tray.py).
QtObject {
    id: root

    // Comme BurnPill : relevé Claude ancien gardé mais signalé, teinte selon le rythme.
    readonly property bool stale: Burn.remainingAgent === "claude" && Burn.limitsStale
    readonly property real remaining: Burn.remaining
    readonly property color tone: Burn.tone(stale || Burn.remaining < 0 ? ""
        : Burn.pace(Burn.remainingAgent, Burn.remainingWindow).status)
    readonly property string tooltip: {
        const w = Burn.tightest?.w;
        if (!w)
            return "Agent Burn — " + (Burn.cliMissing ? "CLI agent-burn introuvable"
                : Burn.loading ? "lecture de l'usage…" : "aucune limite relevée");
        return "Agent Burn — " + w.label + " : " + Math.round(w.remaining) + " % restant"
            + (w.resetsAtMs > 0 ? " · réinit. " + Burn.until(w.resetsAtMs) : "") + (stale ? " · ancien" : "");
    }

    // Typées QtObject : PySide ne convertit pas les types QML (ni Window), il retrouve QQuickWindow.
    readonly property QtObject popover: PopoverWindow {}
    readonly property QtObject dashboard: DashboardWindow {}

    function openDashboard() { Burn.openDashboard(Burn.dashboardPage); }
    function refresh() { Burn.refresh(true); }
}
