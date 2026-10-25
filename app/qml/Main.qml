import QtQuick
import AgentBurn

// Root of the desktop app: popover, dashboard, settings and tray icon state (read by
// tray.py); wires the app settings to the shared core (Burn) and the theme (Colors).
QtObject {
    id: root

    // Like BurnPill: a stale Claude reading is kept but flagged, tinted by pace.
    readonly property bool stale: Burn.remainingAgent === "claude" && Burn.limitsStale
    // CLI failed: the cause (Burn.error) is in Settings, the icon and its menu point there.
    readonly property string cliFailed: "CLI failed (see Settings › Diagnostics)"
    readonly property real remaining: Burn.remaining
    readonly property color tone: Burn.tone(stale || Burn.remaining < 0 ? ""
        : Burn.pace(Burn.remainingAgent, Burn.remainingWindow).status)
    readonly property string tooltip: {
        const w = Burn.tightest?.w;
        if (!w)
            return "Agent Burn — " + Burn.stateText(Burn.dataState) + " · " + (Burn.cliMissing ? "agent-burn CLI not found"
                : Burn.loading ? "reading usage…" : Burn.error ? root.cliFailed : "no limits read");
        return "Agent Burn — " + w.label + ": " + Math.round(w.remaining) + "% left"
            + (w.resetsAtMs > 0 ? " · resets " + Burn.until(w.resetsAtMs) : "") + (stale ? " · stale" : "");
    }
    // Status lines at the top of the tray icon menu (on Wayland, the only information shown next to the icon):
    // the 3 tightest limits, otherwise the state of each known agent.
    readonly property list<string> menuLines: {
        const all = [];
        for (const a of new Set(Burn.knownProviders.concat(Burn.agents)))
            for (const w of Burn.windows(a))
                all.push({ agent: a, w: w });
        all.sort((x, y) => x.w.remaining - y.w.remaining);
        if (all.length)
            return all.slice(0, 3).map(x => Burn.agentName(x.agent) + " · " + x.w.label + ": " + Math.round(x.w.remaining)
                + "% left" + (x.w.resetsAtMs > 0 ? " · resets " + Burn.until(x.w.resetsAtMs) : "")
                + (Burn.providerState(x.agent).state === "stale" ? " · stale" : ""));
        if (Burn.dataState === "unavailable")
            return ["Data unavailable" + (Burn.cliMissing ? ": agent-burn CLI not found" : Burn.loading ? ": reading…"
                : Burn.error ? ": " + root.cliFailed : "")];
        return Burn.knownProviders.map(a => Burn.agentName(a) + ": " + Burn.providerState(a).label);
    }

    // Typed as QtObject: PySide does not convert QML types (nor Window), it gets the QQuickWindow back.
    readonly property QtObject popover: PopoverWindow {}
    readonly property QtObject dashboard: DashboardWindow { onSettingsRequested: prefs.open("general") }
    readonly property QtObject settingsWindow: SettingsWindow { id: prefs }

    // App settings applied to the shared core and the theme (a list: QtObject has no children).
    readonly property list<QtObject> bindings: [
        Binding { target: Burn; property: "refreshInterval"; value: Settings.refreshMinutes * 60000 },
        Binding { target: Burn; property: "cliHint"; value: "Agent Burn can't find its CLI (" + Burn.bin + "): reinstall the app." },
        Binding { target: Colors; property: "theme"; value: Settings.theme },
        // Shared view texts read by screen readers: safe here, the basic render loop on Linux
        // (__main__) avoids the crash that exposing them caused in the Qt 6.12 threaded loop on Wayland.
        Binding { target: Burn; property: "accessibleText"; value: true }
    ]

    function openDashboard() { Burn.openDashboard(Burn.dashboardPage); }
    function refresh() { Burn.refresh(true); }
    function openSettings(section: string) { prefs.open(section); }
}
