pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Fusion
import QtQuick.Layouts
import AgentBurn

// Fenêtre « Paramètres » de l'app de bureau : réglages, état des fournisseurs, diagnostic, à propos.
// Contrôles Qt Quick (Tab, flèches, Espace, lecteurs d'écran) aux couleurs de Colors : lisible en clair
// et en sombre. Échap la ferme ; ouverte par le menu de l'icône (Main.openSettings).
ApplicationWindow {
    id: win

    readonly property var sections: ["general", "providers", "diagnostic", "about"]
    property int section: 0
    readonly property color card: Qt.tint(Colors.background, Colors.withAlpha(Colors.surface, 0.55))
    readonly property var agents: Array.from(new Set(Burn.knownProviders.concat(Burn.agents)))
    // Origine d'une erreur de Burn.recentErrors, en clair.
    readonly property var sources: ({ summary: "Rapport", range: "Période du dashboard", "harness:claude": "Détail Claude Code",
                                      "harness:codex": "Détail Codex", quota: "Relevé des limites", cli: "Lancement du CLI" })

    function open(name) {
        section = Math.max(0, sections.indexOf(name));
        tabs.currentItem.forceActiveFocus();   // pas sur un contrôle de la section quittée, caché : Espace le changerait
        visible = true;
        raise();
        requestActivate();
    }
    // Entrée comme Espace sur le contrôle focalisé : bouton, interrupteur, option ou onglet.
    function activate(event) {
        const f = win.activeFocusItem;
        if (typeof f?.click === "function")
            f.click();
        else
            event.accepted = false;
    }
    function stateColor(s) {
        return s === "live" ? Colors.good : s === "unavailable" ? Colors.danger
             : s === "none" || s === "unknown" ? Colors.muted : Colors.warn;
    }

    title: "Paramètres — Agent Burn"
    width: 620
    height: 680
    minimumWidth: 520
    minimumHeight: 480
    color: Colors.background
    font.family: "JetBrainsMono Nerd Font"
    font.pixelSize: 13
    palette {
        window: Colors.background
        windowText: Colors.foreground
        base: win.card
        alternateBase: Colors.background
        text: Colors.foreground
        button: win.card
        buttonText: Colors.foreground
        brightText: Colors.foreground
        highlight: Colors.accent
        highlightedText: Colors.background
        placeholderText: Colors.muted
        toolTipBase: win.card
        toolTipText: Colors.foreground
        mid: Colors.withAlpha(Colors.muted, 0.5)
        dark: Colors.withAlpha(Colors.muted, 0.7)
        light: Colors.withAlpha(Colors.foreground, 0.15)
        midlight: Colors.withAlpha(Colors.foreground, 0.08)
        disabled.text: Colors.muted
        disabled.windowText: Colors.muted
        disabled.buttonText: Colors.muted
    }

    onVisibleChanged: if (visible) Desktop.probeCli()
    Shortcut { sequence: "Esc"; onActivated: win.close() }

    header: TabBar {
        id: tabs
        currentIndex: win.section
        onCurrentIndexChanged: win.section = currentIndex
        Accessible.name: "Sections des paramètres"
        Keys.onReturnPressed: event => win.activate(event)
        Keys.onEnterPressed: event => win.activate(event)
        Tab { text: "Général" }
        Tab { text: "Fournisseurs" }
        Tab { text: "Diagnostic" }
        Tab { text: "À propos" }
    }

    // Anneau de focus au clavier, celui des vues partagées (BurnButton) : le style n'en dessine aucun sur
    // les onglets, à peine un sur les cases d'option.
    component Ring: Rectangle {
        z: 1
        anchors.fill: parent
        color: "transparent"
        border.width: 2
        border.color: Colors.accent
        radius: 4
    }
    // Onglet : section courante soulignée et en gras, pas seulement teintée.
    component Tab: TabButton {
        id: tab
        font.bold: checked
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 3
            visible: tab.checked
            color: Colors.accent
        }
        Ring { visible: tab.visualFocus }
    }
    // Option d'une rangée : flèche gauche ou droite vers la voisine, cochée aussitôt, comme sous Windows ou GTK.
    component Choice: RadioButton {
        id: choice
        function step(d) {
            const row = Array.from(parent.children).filter(c => c instanceof RadioButton);
            const next = row[row.indexOf(choice) + d];
            if (next) {
                next.forceActiveFocus(Qt.TabFocusReason);   // anneau gardé, comme au Tab
                next.click();
            }
        }
        Keys.onLeftPressed: step(-1)
        Keys.onRightPressed: step(1)
        Ring { visible: choice.visualFocus }
    }

    // Texte des sections ; textes du CLI (erreurs, chemins, versions) jamais interprétés.
    component Txt: Label {
        Layout.fillWidth: true
        color: Colors.foreground
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
    }
    component Hint: Txt {
        color: Colors.muted
        font.pixelSize: 11
    }
    // Intitulé : valeur, coupée entre les mots, ou n'importe où pour un chemin long.
    component Field: RowLayout {
        id: field
        property string label
        property string value
        Layout.fillWidth: true
        spacing: 12
        Txt {
            text: field.label
            color: Colors.muted
            Layout.fillWidth: false
            Layout.preferredWidth: 170
            Layout.alignment: Qt.AlignTop
        }
        Txt { text: field.value; wrapMode: Text.WrapAtWordBoundaryOrAnywhere }
    }
    component Section: GroupBox {
        Layout.fillWidth: true
        // GroupBox de Fusion : titre et cadre aux couleurs de la palette.
        default property alias content: box.data
        ColumnLayout {
            id: box
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 10
        }
    }
    // Page défilante d'une section.
    component Page: ScrollView {
        id: page
        default property alias content: col.data
        contentWidth: availableWidth
        padding: 20
        ColumnLayout {
            id: col
            width: page.availableWidth
            spacing: 16
        }
    }

    // Contenu créé à l'ouverture seulement : fenêtre fermée = ni bindings ni horloge.
    Loader {
        anchors.fill: parent
        active: win.visible
        sourceComponent: StackLayout {
            id: stack
            currentIndex: tabs.currentIndex
            Keys.onReturnPressed: event => win.activate(event)
            Keys.onEnterPressed: event => win.activate(event)

            // Contrôle atteint au clavier hors de la vue : la page défile jusqu'à lui.
            Connections {
                target: win
                function onActiveFocusItemChanged() {
                    const f = stack.children[stack.currentIndex]?.contentItem;   // Flickable du ScrollView affiché
                    const item = win.activeFocusItem;
                    let inside = false;
                    for (let p = item; p && !inside; p = p.parent)
                        inside = p === f;
                    if (!inside)
                        return;
                    const y = item.mapToItem(f.contentItem, 0, 0).y, top = y - 12, bottom = y + item.height + 12;
                    if (top < f.contentY)
                        f.contentY = Math.max(0, top);
                    else if (bottom > f.contentY + f.height)
                        f.contentY = Math.min(bottom - f.height, Math.max(0, f.contentHeight - f.height));
                }
            }

            // ── Général ──
            Page {
                Section {
                    title: "Données"
                    RowLayout {
                        spacing: 12
                        Txt { text: "Rafraîchissement automatique" }
                        ComboBox {
                            readonly property var minutes: [1, 5, 15, 30]
                            model: ["1 min", "5 min", "15 min", "30 min"]
                            currentIndex: minutes.indexOf(Settings.refreshMinutes)
                            onActivated: i => Settings.refreshMinutes = minutes[i]
                            Accessible.name: "Rafraîchissement automatique"
                        }
                    }
                    Hint { text: "Limites relevées à ce rythme, rapport complet au moins une fois par heure." }
                }
                Section {
                    title: "Apparence"
                    RowLayout {
                        spacing: 12
                        Txt { text: "Thème"; Layout.fillWidth: false; Layout.preferredWidth: 170 }
                        Repeater {
                            model: [["system", "Système"], ["light", "Clair"], ["dark", "Sombre"]]
                            Choice {
                                required property var modelData
                                text: modelData[1]
                                checked: Settings.theme === modelData[0]
                                onToggled: Settings.theme = modelData[0]
                                Accessible.name: "Thème " + text
                            }
                        }
                    }
                }
                Section {
                    title: "Démarrage et zone de notification"
                    Switch {
                        text: "Lancer à l'ouverture de session"
                        enabled: Settings.autostartAvailable
                        opacity: enabled ? 1 : 0.5   // le style garde le libellé en couleur normale
                        checked: Settings.autostart
                        onToggled: Settings.autostart = checked
                    }
                    Hint { visible: !Settings.autostartAvailable; text: "Disponible dans l'application installée." }
                    Switch {
                        text: "Garder dans la zone de notification à la fermeture"
                        checked: Settings.closeToTray
                        onToggled: Settings.closeToTray = checked
                    }
                    RowLayout {
                        spacing: 12
                        Txt { text: "Clic sur l'icône"; Layout.fillWidth: false; Layout.preferredWidth: 170 }
                        Repeater {
                            model: [["popover", "Aperçu"], ["dashboard", "Dashboard"]]
                            Choice {
                                required property var modelData
                                text: modelData[1]
                                checked: Settings.trayClick === modelData[0]
                                onToggled: Settings.trayClick = modelData[0]
                                Accessible.name: "Clic sur l'icône : " + text
                            }
                        }
                    }
                    Hint {
                        visible: text !== ""
                        text: !Desktop.trayAvailable ? "Aucune zone de notification détectée : fermer le dashboard quitte l'application. "
                                + "Sous GNOME, active l'extension AppIndicator."
                            : Desktop.platformName === "wayland" ? "Sous Wayland, le bureau place lui-même l'aperçu, souvent au centre de l'écran." : ""
                    }
                }
            }

            // ── Fournisseurs ──
            Page {
                Repeater {
                    model: win.agents
                    Section {
                        id: agentBox
                        required property string modelData
                        readonly property var st: Burn.providerState(modelData)
                        title: Burn.agentName(modelData)
                        RowLayout {
                            spacing: 12
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: 32
                                implicitHeight: 32
                                radius: 8
                                color: Colors.withAlpha(Burn.agentColor(agentBox.modelData), 0.25)
                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    source: Burn.agentIcon(agentBox.modelData)
                                    sourceSize: Qt.size(64, 64)
                                    mipmap: true
                                    Accessible.ignored: true
                                }
                            }
                            ColumnLayout {
                                spacing: 4
                                // Pastille teintée, mot en couleur du texte : lisible quelle que soit la teinte.
                                RowLayout {
                                    spacing: 6
                                    Txt {
                                        text: "●"
                                        color: win.stateColor(agentBox.st.state)
                                        Layout.fillWidth: false
                                        Accessible.ignored: true
                                    }
                                    Txt { text: agentBox.st.label; font.bold: true }
                                }
                                Txt { text: agentBox.st.detail }
                                Hint { visible: agentBox.st.at > 0 && agentBox.st.state !== "none"; text: "Relevé " + Burn.ago(agentBox.st.at) }
                                Txt { visible: text !== ""; text: agentBox.st.error; color: Colors.danger }
                            }
                        }
                    }
                }
                Section {
                    title: "CLI agent-burn"
                    Field { label: "Emplacement"; value: Burn.bin }
                    Field { label: "Version"; value: Desktop.cliVersion || "lecture…" }
                    Field {
                        label: "Rapport"
                        value: Burn.stateText(Burn.dataState) + (Burn.updatedAt > 0 ? ", mis à jour " + Burn.ago(Burn.updatedAt) : "")
                    }
                    Button {
                        text: Burn.loading ? "Lecture en cours…" : "Rafraîchir maintenant"
                        enabled: !Burn.loading
                        onClicked: Burn.refresh(true)
                    }
                }
            }

            // ── Diagnostic ──
            Page {
                Rectangle {
                    visible: Settings.recovered
                    Layout.fillWidth: true
                    implicitHeight: notice.implicitHeight + 20
                    radius: 8
                    color: Colors.withAlpha(Colors.warn, 0.15)
                    border.color: Colors.withAlpha(Colors.warn, 0.5)
                    Txt {
                        id: notice
                        anchors.fill: parent
                        anchors.margins: 10
                        text: "Paramètres réinitialisés : le fichier de réglages était illisible, une copie a été gardée (settings.json.bak)."
                    }
                }
                Section {
                    title: "Versions"
                    Field {
                        label: "Agent Burn"
                        value: Desktop.appVersion + (Desktop.buildInfo.builtAt ? ", compilé le " + Desktop.buildInfo.builtAt : "")
                            + (Desktop.buildInfo.target === "dev" ? " (version de développement)" : "")
                    }
                    Field { label: "CLI agent-burn"; value: Desktop.cliVersion || "lecture…" }
                    Field {
                        label: "CLI prévu"
                        value: (Desktop.buildInfo.cliVersion || "—") + (Desktop.buildInfo.cliRev ? ", révision " + Desktop.buildInfo.cliRev.slice(0, 12) : "")
                    }
                }
                Section {
                    title: "Système"
                    Field { label: "Système"; value: Desktop.os }
                    Field { label: "Affichage"; value: Desktop.platformName + (Desktop.desktopEnv ? ", " + Desktop.desktopEnv : "") + (Desktop.sessionType ? " (" + Desktop.sessionType + ")" : "") }
                    Field { label: "Écrans"; value: Desktop.screens }
                    Field { label: "Zone de notification"; value: Desktop.trayAvailable ? "disponible" : "absente" }
                }
                Section {
                    title: "Dossiers"
                    Field { label: "Données"; value: Desktop.dataDir }
                    Field { label: "Réglages"; value: Desktop.configDir }
                    Field { label: "Journaux"; value: Desktop.logDir }
                    Field { label: "Cache"; value: Desktop.cacheDir }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Button { text: "Ouvrir les journaux"; onClicked: Desktop.openLogs() }
                        Button { text: "Ouvrir le dossier des données"; onClicked: Desktop.openDataDir() }
                        Button {
                            text: copied.running ? "Copié dans le presse-papiers" : "Copier le diagnostic"
                            onClicked: {
                                Desktop.copyDiagnostics();
                                copied.restart();
                            }
                            Timer { id: copied; interval: 3000 }
                        }
                    }
                    Switch {
                        text: "Journal détaillé (débogage)"
                        checked: Settings.debugLogging
                        onToggled: Settings.debugLogging = checked
                    }
                }
                Section {
                    title: "Dernières erreurs"
                    Hint { visible: Burn.recentErrors.length === 0; text: "Aucune erreur depuis le lancement." }
                    Repeater {
                        model: Burn.recentErrors.slice().reverse()
                        Txt {
                            required property var modelData
                            text: new Date(modelData.t).toLocaleTimeString(Qt.locale("fr_FR"), "HH:mm:ss") + " · "
                                + (win.sources[modelData.source] ?? modelData.source) + " — " + modelData.msg
                        }
                    }
                }
                Button {
                    text: "Réinitialiser les paramètres"
                    onClicked: Settings.reset()
                }
            }

            // ── À propos ──
            Page {
                RowLayout {
                    spacing: 10
                    Txt {
                        text: "\uf06d"  // fire
                        color: Colors.accent
                        font.pixelSize: 26
                        Layout.fillWidth: false
                        Accessible.ignored: true
                    }
                    Txt { text: "Agent Burn"; font.pixelSize: 20; font.bold: true }
                }
                Txt { text: "Version " + Desktop.appVersion + " · CLI " + (Desktop.cliVersion || "lecture…") }
                Txt { text: "Dépense des agents de code (Claude Code, Codex…) et limites d'abonnement en direct, lues par le CLI agent-burn." }
                Txt { text: "D'après l'app macOS agent-burn de Melvynx, sous licence MIT." }
                Button {
                    visible: Desktop.licensesAvailable
                    text: "Licences"
                    onClicked: Desktop.openLicenses()
                }
            }
        }
    }
}
