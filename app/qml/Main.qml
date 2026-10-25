import QtQuick
import AgentBurn

// Racine de l'app de bureau : popover, dashboard, réglages et état de l'icône de notification (lus par
// tray.py) ; branche les réglages de l'app sur le cœur partagé (Burn) et le thème (Colors).
QtObject {
    id: root

    // Comme BurnPill : relevé Claude ancien gardé mais signalé, teinte selon le rythme.
    readonly property bool stale: Burn.remainingAgent === "claude" && Burn.limitsStale
    // CLI en échec : la cause (Burn.error) est dans Paramètres, l'icône et son menu y renvoient.
    readonly property string cliFailed: "échec du CLI (voir Paramètres › Diagnostic)"
    readonly property real remaining: Burn.remaining
    readonly property color tone: Burn.tone(stale || Burn.remaining < 0 ? ""
        : Burn.pace(Burn.remainingAgent, Burn.remainingWindow).status)
    readonly property string tooltip: {
        const w = Burn.tightest?.w;
        if (!w)
            return "Agent Burn — " + Burn.stateText(Burn.dataState) + " · " + (Burn.cliMissing ? "CLI agent-burn introuvable"
                : Burn.loading ? "lecture de l'usage…" : Burn.error ? root.cliFailed : "aucune limite relevée");
        return "Agent Burn — " + w.label + " : " + Math.round(w.remaining) + " % restant"
            + (w.resetsAtMs > 0 ? " · réinit. " + Burn.until(w.resetsAtMs) : "") + (stale ? " · ancien" : "");
    }
    // Lignes d'état en tête du menu de l'icône (sous Wayland, seule information affichée contre l'icône) :
    // les 3 limites les plus serrées, sinon l'état de chaque agent connu.
    readonly property list<string> menuLines: {
        const all = [];
        for (const a of new Set(Burn.knownProviders.concat(Burn.agents)))
            for (const w of Burn.windows(a))
                all.push({ agent: a, w: w });
        all.sort((x, y) => x.w.remaining - y.w.remaining);
        if (all.length)
            return all.slice(0, 3).map(x => Burn.agentName(x.agent) + " · " + x.w.label + " : " + Math.round(x.w.remaining)
                + " % restant" + (x.w.resetsAtMs > 0 ? " · réinit. " + Burn.until(x.w.resetsAtMs) : "")
                + (Burn.providerState(x.agent).state === "stale" ? " · ancien" : ""));
        if (Burn.dataState === "unavailable")
            return ["Données indisponibles" + (Burn.cliMissing ? " : CLI agent-burn introuvable" : Burn.loading ? " : lecture…"
                : Burn.error ? " : " + root.cliFailed : "")];
        return Burn.knownProviders.map(a => Burn.agentName(a) + " : " + Burn.providerState(a).label);
    }

    // Typées QtObject : PySide ne convertit pas les types QML (ni Window), il retrouve QQuickWindow.
    readonly property QtObject popover: PopoverWindow {}
    readonly property QtObject dashboard: DashboardWindow { onSettingsRequested: prefs.open("general") }
    readonly property QtObject settingsWindow: SettingsWindow { id: prefs }

    // Réglages de l'app appliqués au cœur partagé et au thème (liste : QtObject n'a pas d'enfants).
    readonly property list<QtObject> bindings: [
        Binding { target: Burn; property: "refreshInterval"; value: Settings.refreshMinutes * 60000 },
        Binding { target: Burn; property: "cliHint"; value: "Agent Burn ne trouve pas son CLI (" + Burn.bin + ") : réinstalle l'application." },
        Binding { target: Colors; property: "theme"; value: Settings.theme },
        // Textes des vues partagées lus par les lecteurs d'écran : sûr ici, la boucle de rendu basique de Linux
        // (__main__) évite le plantage que l'exposition provoquait dans la boucle à fil de Qt 6.12 sous Wayland.
        Binding { target: Burn; property: "accessibleText"; value: true }
    ]

    function openDashboard() { Burn.openDashboard(Burn.dashboardPage); }
    function refresh() { Burn.refresh(true); }
    function openSettings(section: string) { prefs.open(section); }
}
