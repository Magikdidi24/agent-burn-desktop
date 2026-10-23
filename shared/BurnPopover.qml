pragma ComponentBehavior: Bound
import Quickshell.Widgets
import QtQuick

// Contenu du popover Agent Burn (le popover de barre de menus de l'app Mac) : onglet Général +
// un onglet par agent, pied « mis à jour », accès au dashboard. Sans fenêtre : BurnPill l'héberge
// dans son PopupWindow, un harnais de test peut l'afficher seul.
Item {
    id: root

    // Un onglet par agent à quota, comme l'app Mac : les autres n'ont rien à y montrer et restent
    // dans Général. Burn.agents est trié par coût.
    readonly property var quotaAgents: Burn.agents.filter(a => Burn.subEntry(a) || (a === "claude" && Burn.account))
    // "general" ou un agent ; par défaut le plus coûteux.
    property string tab: quotaAgents.length > 0 ? quotaAgents[0] : "general"
    // Le porteur ferme le popover (après « Ouvrir le dashboard »).
    signal closeRequested()

    implicitWidth: 440
    implicitHeight: col.implicitHeight + 32

    onVisibleChanged: if (root.visible) Burn.poke()
    onTabChanged: fade.restart()
    Timer { interval: 60000; repeat: true; running: root.visible; onTriggered: Burn.poke() }

    component Txt: Text {
        color: Colors.foreground
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 12
        textFormat: Text.PlainText
    }
    // Chiffre clé : intitulé, valeur en gros, détail.
    component Stat: Column {
        id: stat
        property string title
        property string value
        property string detail
        property int size: 28
        spacing: 3
        Txt { text: stat.title; color: Colors.muted; font.pixelSize: 11 }
        Txt { text: stat.value; font.pixelSize: stat.size; font.bold: true }
        Txt {
            width: stat.width
            visible: text !== ""
            text: stat.detail
            color: Colors.muted
            font.pixelSize: 10
            wrapMode: Text.WordWrap
        }
    }
    // Icône de marque arrondie ; les logos détourés reposent sur une tuile teintée.
    component AgentIcon: ClippingRectangle {
        id: tile
        property string agent
        readonly property color brand: Burn.agentColor(agent)   // chaîne "#rrggbb" → couleur (withAlpha lit .r/.g/.b)
        color: Colors.withAlpha(brand, 0.25)
        Image { anchors.fill: parent; source: Burn.agentIcon(tile.agent); mipmap: true }
    }

    Column {
        id: col
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 14

        // En-tête : flamme + titre, rafraîchissement forcé à droite.
        Item {
            width: parent.width
            height: 28
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uf06d"  // fire
                    color: Colors.accent
                    font.pixelSize: 18
                }
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Agent Burn"
                    font.pixelSize: 15
                    font.bold: true
                }
            }
            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 8
                color: refreshMa.containsMouse ? Colors.withAlpha(Colors.muted, 0.2) : "transparent"
                opacity: Burn.loading ? 0.4 : 1
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Txt {
                    anchors.centerIn: parent
                    text: "\uf021"  // refresh
                    font.pixelSize: 14
                }
                MouseArea {
                    id: refreshMa
                    anchors.fill: parent
                    anchors.margins: -6   // cible de 40 px
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Burn.refresh(true)
                }
            }
        }

        // Onglets segmentés : la pastille active glisse d'un onglet à l'autre.
        Rectangle {
            id: tabs
            readonly property var ids: ["general"].concat(root.quotaAgents)
            readonly property real tabW: (width - 6) / ids.length
            width: parent.width
            height: 34
            radius: 10
            color: Colors.withAlpha(Colors.muted, 0.12)

            Rectangle {
                x: 3 + Math.max(0, tabs.ids.indexOf(root.tab)) * tabs.tabW
                y: 3
                width: tabs.tabW
                height: tabs.height - 6
                radius: 8
                color: Colors.accent
                Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }
            Row {
                x: 3
                y: 3
                Repeater {
                    model: tabs.ids
                    Item {
                        id: tabItem
                        required property string modelData
                        readonly property bool active: modelData === root.tab
                        width: tabs.tabW
                        height: tabs.height - 6
                        Txt {
                            anchors.centerIn: parent
                            width: parent.width - 12
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: tabItem.modelData === "general" ? "Général" : Burn.agentName(tabItem.modelData)
                            color: tabItem.active ? Colors.background : tabMa.containsMouse ? Colors.foreground : Colors.muted
                            font.bold: tabItem.active
                        }
                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.tab = tabItem.modelData
                        }
                    }
                }
            }
        }

        // Contenu créé à l'ouverture seulement : caché, il ne suit plus l'horloge de Burn.
        Loader {
            id: body
            width: parent.width
            active: root.visible
            sourceComponent: root.tab === "general" ? generalView : agentView
            NumberAnimation { id: fade; target: body; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle { width: parent.width; height: 1; color: Colors.withAlpha(Colors.muted, 0.25) }

        // Fraîcheur : vert, orange au-delà de 10 min (ou jamais), rouge si le dernier appel a échoué.
        Row {
            spacing: 8
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: 3.5
                color: Burn.error !== "" ? Colors.danger
                     : Burn.updatedAt === 0 || Burn.now - Burn.updatedAt > 600000 ? Colors.warn : Colors.good
            }
            Txt {
                text: Burn.updatedAt > 0 ? "Mis à jour " + Burn.ago(Burn.updatedAt)
                    : Burn.loading ? "Mise à jour…" : "Jamais mis à jour"
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        Txt {
            width: parent.width
            visible: text !== ""
            text: Burn.cliMissing ? "CLI agent-burn introuvable (~/.local/bin/agent-burn) : relance install.sh" : Burn.error
            color: Colors.danger
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Rectangle {
            width: parent.width
            height: 36
            radius: 10
            color: dashMa.containsMouse ? Colors.withAlpha(Colors.muted, 0.22) : Colors.withAlpha(Colors.muted, 0.12)
            border.width: 1
            border.color: Colors.withAlpha(Colors.muted, 0.18)
            scale: dashMa.pressed ? 0.98 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
            Txt {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "Ouvrir le dashboard"
                font.bold: true
            }
            Txt {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf08e"  // external-link
                color: Colors.muted
                font.pixelSize: 13
            }
            MouseArea {
                id: dashMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Burn.openDashboard(root.tab === "general" ? "all" : root.tab);
                    root.closeRequested();
                }
            }
        }
    }

    // Onglet agent : forfait, dépense, limites (la plus parlante en grand) et rythme.
    Component {
        id: agentView
        Column {
            id: av
            readonly property string agent: root.tab
            readonly property var sub: Burn.subEntry(agent)
            readonly property var wins: Burn.windows(agent)
            // Fenêtre en vedette : l'hebdo, sinon la plus contraignante.
            readonly property var main: wins.find(w => w.key === "weekly")
                ?? wins.reduce((a, w) => !a || w.remaining < a.remaining ? w : a, null)
            readonly property var pace: main ? Burn.pace(agent, main.key) : null
            readonly property color tint: Burn.tone(pace?.status ?? "")
            readonly property bool live: agent === "claude" && !!Burn.account && !Burn.limitsStale
            spacing: 16

            // Identité : icône, nom, forfait + provenance des limites.
            Item {
                width: parent.width
                height: 40
                AgentIcon {
                    id: icon
                    width: 40
                    height: 40
                    radius: 10
                    agent: av.agent
                }
                Column {
                    anchors.left: icon.right
                    anchors.leftMargin: 12
                    anchors.right: badge.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Txt {
                        width: parent.width
                        text: Burn.agentName(av.agent)
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Txt {
                        width: parent.width
                        visible: text !== ""
                        text: av.sub?.plan ?? ""
                        color: Colors.muted
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
                // Couleur sur le point seul : le texte coloré se lit mal sur le fond clair du popover.
                Rectangle {
                    id: badge
                    readonly property color c: av.live ? Colors.good : Colors.muted
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: badgeRow.implicitWidth + 20
                    height: 24
                    radius: 12
                    color: Colors.withAlpha(c, 0.14)
                    Row {
                        id: badgeRow
                        anchors.centerIn: parent
                        spacing: 5
                        Txt { text: "●"; color: badge.c; font.pixelSize: 11 }
                        Txt { text: av.live ? "En direct" : "Instantané CLI"; font.pixelSize: 11; font.bold: true }
                    }
                }
            }

            // Connexion refusée par Anthropic : seul /login dans claude la rétablit.
            Rectangle {
                visible: av.agent === "claude" && Burn.signInExpired
                width: parent.width
                height: expired.implicitHeight + 16
                radius: 10
                color: Colors.withAlpha(Colors.danger, 0.25)
                Txt {
                    id: expired
                    x: 10
                    width: parent.width - 20
                    anchors.verticalCenter: parent.verticalCenter
                    wrapMode: Text.WordWrap
                    text: "\uf071  Connexion Claude Code expirée : lance claude dans un terminal puis /login. "
                          + "Dernières valeurs enregistrées affichées."  // warning
                }
            }

            Row {
                width: parent.width
                Stat {
                    id: spend
                    width: parent.width * 0.58
                    title: "Dépense"
                    value: Burn.money(Burn.spendSince(av.agent, 30))
                    detail: "30 derniers jours · équivalent API"
                }
                Stat {
                    visible: typeof av.sub?.pricePerMonth === "number"
                    width: parent.width - spend.width
                    title: "Forfait mensuel"
                    value: Burn.money(av.sub?.pricePerMonth)
                    detail: av.sub?.plan ?? ""
                }
            }

            // Aucune limite connue (agent sans abonnement, ou 1er chargement).
            Column {
                visible: !av.main
                width: parent.width
                spacing: 6
                Txt {
                    text: Burn.loading ? "Lecture de l'usage…" : "Quota indisponible"
                    font.pixelSize: 20
                    font.bold: true
                }
                Txt {
                    width: parent.width
                    text: Burn.loading ? "Chargement des limites d'abonnement."
                        : "Connecte-toi à " + Burn.agentName(av.agent) + " et lance une session, puis rafraîchis."
                    color: Colors.muted
                    wrapMode: Text.WordWrap
                }
            }

            // Restant de la fenêtre en vedette : grand chiffre, fenêtre et reset à droite.
            Item {
                visible: !!av.main
                width: parent.width
                height: big.implicitHeight
                Txt {
                    id: big
                    text: av.main ? Math.round(av.main.remaining) : ""
                    font.pixelSize: 44
                    font.bold: true
                }
                Txt {
                    anchors.left: big.right
                    anchors.leftMargin: 8
                    anchors.baseline: big.baseline
                    text: "% restant"
                    color: Colors.muted
                    font.pixelSize: 16
                }
                Column {
                    anchors.right: parent.right
                    anchors.bottom: big.baseline
                    spacing: 2
                    Txt {
                        anchors.right: parent.right
                        text: av.main?.label ?? ""
                        color: Colors.muted
                        font.pixelSize: 11
                    }
                    Txt {
                        anchors.right: parent.right
                        visible: (av.main?.resetsAtMs ?? 0) > 0
                        text: "réinit. " + Burn.until(av.main?.resetsAtMs ?? 0)
                        color: Colors.muted
                        font.pixelSize: 11
                    }
                }
            }

            // Autres fenêtres (session 5 h, limites par modèle).
            Column {
                id: others
                width: parent.width
                spacing: 6
                Repeater {
                    model: av.wins.filter(w => w.key !== av.main?.key)
                    Item {
                        id: win
                        required property var modelData
                        width: others.width
                        height: 18
                        Txt {
                            anchors.verticalCenter: parent.verticalCenter
                            text: win.modelData.label
                            color: Colors.muted
                        }
                        Txt {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: Burn.pct(win.modelData.remaining) + " restant"
                                + (win.modelData.resetsAtMs > 0 ? " · réinit. " + Burn.until(win.modelData.resetsAtMs) : "")
                        }
                    }
                }
            }

            // Rythme : la fenêtre en vedette tient-elle jusqu'au reset ?
            Column {
                visible: !!av.pace
                width: parent.width
                spacing: 4
                Row {
                    spacing: 8
                    Txt {
                        anchors.verticalCenter: parent.verticalCenter
                        text: av.pace?.status === "good" ? "\uf058" : "\uf071"  // check-circle / warning
                        color: av.tint
                        font.pixelSize: 14
                    }
                    Txt {
                        anchors.verticalCenter: parent.verticalCenter
                        text: av.pace?.title ?? ""
                        font.pixelSize: 13
                        font.bold: true
                    }
                }
                Txt {
                    width: parent.width
                    visible: text !== ""
                    text: av.pace?.detail ?? ""
                    color: Colors.muted
                    wrapMode: Text.WordWrap
                }
            }

            BurnQuotaChart {
                visible: !!av.main
                width: parent.width
                compact: true
                startMs: av.main?.startMs ?? 0
                endMs: av.main ? (av.main.resetsAtMs || av.main.startMs + av.main.durationMin * 60000) : 0
                samples: av.main ? Burn.quotaSamples(av.agent, av.main.key) : []
                used: av.main?.used ?? -1
                projected: av.pace?.projected ?? -1
                accent: av.tint
            }
            Txt {
                visible: !!av.main
                width: parent.width
                text: "Ton historique de quota se construit à chaque rafraîchissement."
                color: Colors.muted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }
    }

    // Onglet Général : dépense et tokens tous agents, liste des agents, 14 derniers jours. Tout vient
    // de l'archive, comme le dashboard : hors ligne le CLI met les coûts à 0, et Claude Code purge
    // ses logs de plus de 30 jours.
    Component {
        id: generalView
        Column {
            id: gv
            readonly property var all: Burn.dailySeries("")
            readonly property var days: Burn.lastDays(all, 14)
            function sum(series, key) { return series.reduce((s, d) => s + (d[key] ?? 0), 0); }
            spacing: 16

            // Sans données ni erreur ; l'erreur (CLI absent…) s'affiche seule sous le pied.
            Txt {
                visible: gv.all.length === 0 && (Burn.loading || Burn.error === "")
                width: parent.width
                text: Burn.loading ? "Lecture de tes logs locaux…"
                    : "Aucune donnée d'usage : lance une session d'agent puis rafraîchis."
                color: Colors.muted
                wrapMode: Text.WordWrap
            }

            Stat {
                visible: gv.all.length > 0
                width: parent.width
                title: "Dépense totale"
                value: Burn.money(gv.sum(gv.all, "cost"))
                detail: "Tous agents · équivalent API"
                size: 36
            }
            Row {
                visible: gv.all.length > 0
                width: parent.width
                Stat {
                    width: parent.width / 2
                    title: "Tokens"
                    value: Burn.tokens(gv.sum(gv.all, "tokens"))
                    detail: "Entrée, sortie et cache"
                    size: 22
                }
                Stat {
                    width: parent.width / 2
                    title: "Aujourd'hui"
                    value: Burn.money(Burn.spendSince("", 1))
                    detail: "Dépense du jour"
                    size: 22
                }
            }

            Column {
                id: list
                width: parent.width
                spacing: 4
                Repeater {
                    model: Burn.agents
                    Rectangle {
                        id: agentRow
                        required property string modelData
                        readonly property var series: Burn.dailySeries(modelData)
                        width: list.width
                        height: 40
                        radius: 10
                        color: Colors.withAlpha(Colors.muted, 0.08)
                        AgentIcon {
                            id: rowIcon
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 24
                            height: 24
                            radius: 6
                            agent: agentRow.modelData
                        }
                        Txt {
                            anchors.left: rowIcon.right
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: Burn.agentName(agentRow.modelData)
                            font.bold: true
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 12
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Burn.tokens(gv.sum(agentRow.series, "tokens")) + " tokens"
                                color: Colors.muted
                                font.pixelSize: 11
                            }
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 84
                                horizontalAlignment: Text.AlignRight
                                text: Burn.money(gv.sum(agentRow.series, "cost"))
                                font.bold: true
                            }
                        }
                        // Agent à quota : la ligne ouvre son onglet (app Mac : « Busiest agents »).
                        MouseArea {
                            anchors.fill: parent
                            enabled: root.quotaAgents.includes(agentRow.modelData)
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.tab = agentRow.modelData
                        }
                    }
                }
            }

            Item {
                visible: gv.all.length > 0
                width: parent.width
                height: 16
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "14 derniers jours"
                    font.bold: true
                }
                Txt {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: Burn.money(Burn.spendSince("", 14))
                    color: Colors.muted
                    font.pixelSize: 11
                }
            }
            BurnBarChart {
                visible: gv.all.length > 0
                width: parent.width
                compact: true
                points: gv.days
                unit: ""   // total des 14 jours déjà en en-tête
            }
        }
    }
}
