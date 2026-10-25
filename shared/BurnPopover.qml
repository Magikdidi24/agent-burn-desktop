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

    function sum(series, key) { return series.reduce((s, d) => s + (d[key] ?? 0), 0); }
    // Dépense des `days` derniers jours d'une série Burn.dailySeries, aujourd'hui inclus : null (« — »)
    // pour un agent sans aucun jour connu, ou pour des tokens sans prix.
    function spent(series, days) {
        const t = new Date(), from = Burn.iso(new Date(t.getFullYear(), t.getMonth(), t.getDate() - days + 1));
        const s = series.filter(d => d.date >= from);
        return series.length ? Burn.priced(sum(s, "cost"), sum(s, "tokens")) : null;
    }
    // Teinte d'un état de Burn.providerState : le mot reste écrit à côté.
    function stateTone(s) { return Burn.tone({ live: "good", stale: "warn", expired: "danger", unavailable: "danger" }[s] ?? ""); }

    component Txt: Text {
        id: txt
        property bool spoken: true   // false : déjà dit ailleurs (libellé d'un bouton, Accessible.name explicite)
        color: Colors.foreground
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 12
        textFormat: Text.PlainText
        // Lecteurs d'écran : un Text n'est exposé qu'avec un rôle et un nom. Posés en JS et seulement avec
        // Burn.accessibleText (app de bureau) : la barre Quickshell garde ses Text sans objet Accessible.
        readonly property bool exposed: spoken && Burn.accessibleText === true
        onExposedChanged: if (exposed && !Accessible.ignored) {
            Accessible.role = Accessible.StaticText;
            Accessible.name = Qt.binding(() => txt.text);
        }
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
    // Bandeau d'alerte sur fond teinté, texte en couleur normale ; caché sans texte.
    component Banner: Rectangle {
        id: banner
        property string text
        property color tint: Colors.danger
        visible: text !== ""
        height: bannerText.implicitHeight + 16
        radius: 10
        color: Colors.withAlpha(tint, 0.25)
        Txt {
            id: bannerText
            x: 10
            width: parent.width - 20
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.WordWrap
            text: "\uf071  " + banner.text   // warning
            Accessible.name: banner.text
            spoken: false
        }
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
                    Accessible.ignored: true
                }
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Agent Burn"
                    font.pixelSize: 15
                    font.bold: true
                }
            }
            BurnButton {
                id: refresh
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: 8
                reach: 6   // cible de 40 px
                tip: "Rafraîchir"
                color: refresh.hovered ? Colors.withAlpha(Colors.muted, 0.2) : "transparent"
                opacity: Burn.loading ? 0.4 : 1
                Behavior on opacity { NumberAnimation { duration: 150 } }
                onClicked: Burn.refresh(true)
                Txt {
                    anchors.centerIn: parent
                    text: "\uf021"  // refresh
                    font.pixelSize: 14
                    Accessible.ignored: true
                }
            }
        }

        // Onglets segmentés : la pastille active glisse d'un onglet à l'autre. Flèches gauche / droite :
        // onglet voisin, sélectionné et focalisé.
        Rectangle {
            id: tabs
            readonly property var ids: ["general"].concat(root.quotaAgents)
            readonly property real tabW: (width - 6) / ids.length
            width: parent.width
            height: 34
            radius: 10
            color: Colors.withAlpha(Colors.muted, 0.12)
            Accessible.role: Accessible.PageTabList
            Accessible.name: "Onglets"

            function step(d) {
                const i = Math.max(0, ids.indexOf(root.tab)) + d;
                if (i < 0 || i >= ids.length) return;
                root.tab = ids[i];
                tabRepeater.itemAt(i).forceActiveFocus();
            }

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
                    id: tabRepeater
                    model: tabs.ids
                    BurnButton {
                        id: tabItem
                        required property string modelData
                        readonly property bool active: modelData === root.tab
                        width: tabs.tabW
                        height: tabs.height - 6
                        radius: 8
                        ring: tabItem.active ? Colors.background : Colors.accent   // sur la pastille accent
                        Accessible.role: Accessible.PageTab
                        Accessible.name: tabLabel.text
                        Accessible.checkable: true
                        Accessible.checked: tabItem.active
                        Keys.onLeftPressed: tabs.step(-1)
                        Keys.onRightPressed: tabs.step(1)
                        onClicked: root.tab = tabItem.modelData
                        Txt {
                            id: tabLabel
                            anchors.centerIn: parent
                            width: parent.width - 12
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: tabItem.modelData === "general" ? "Général" : Burn.agentName(tabItem.modelData)
                            color: tabItem.active ? Colors.background : tabItem.hovered ? Colors.foreground : Colors.muted
                            font.bold: tabItem.active
                            spoken: false
                        }
                    }
                }
            }
        }

        // Hors ligne ou LiteLLM injoignable, le CLI compte 0 $ : montants « — » ou partiels.
        Banner {
            width: parent.width
            tint: Colors.warn
            text: Burn.pricingMissing ? "Tarifs indisponibles : montants incomplets (réseau coupé ou tarifs non téléchargés)" : ""
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

        // Fraîcheur en toutes lettres : en direct, en cache (relu du disque, dernier appel en échec ou
        // trop ancien) ou indisponible.
        Row {
            spacing: 8
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: 3.5
                color: Burn.dataState === "live" ? Colors.good : Burn.dataState === "cached" ? Colors.warn
                     : Burn.loading ? Colors.muted : Colors.danger
            }
            Txt {
                text: Burn.dataState !== "unavailable" ? Burn.stateText(Burn.dataState) + " · mis à jour " + Burn.ago(Burn.updatedAt)
                    : Burn.loading ? "Mise à jour…" : Burn.stateText(Burn.dataState)
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        Txt {
            width: parent.width
            visible: text !== ""
            // CLI absent : le remède de l'hôte (install.sh, réinstallation de l'app) plutôt que le chemin.
            text: Burn.cliMissing ? Burn.cliHint : Burn.error
            color: Colors.danger
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        BurnButton {
            id: dash
            width: parent.width
            height: 36
            radius: 10
            color: dash.hovered ? Colors.withAlpha(Colors.muted, 0.22) : Colors.withAlpha(Colors.muted, 0.12)
            border.width: 1
            border.color: Colors.withAlpha(Colors.muted, 0.18)
            scale: dash.pressed ? 0.98 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
            Accessible.name: "Ouvrir le dashboard"
            onClicked: {
                Burn.openDashboard(root.tab === "general" ? "all" : root.tab);
                root.closeRequested();
            }
            Txt {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "Ouvrir le dashboard"
                font.bold: true
                spoken: false
            }
            Txt {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf08e"  // external-link
                color: Colors.muted
                font.pixelSize: 13
                Accessible.ignored: true
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
            readonly property var provider: Burn.providerState(agent)
            readonly property var series: Burn.dailySeries(agent)
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
                    readonly property color c: root.stateTone(av.provider.state)
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
                        Txt { text: "●"; color: badge.c; font.pixelSize: 11; Accessible.ignored: true }
                        Txt { text: av.provider.label; font.pixelSize: 11; font.bold: true }
                    }
                }
            }

            // Limites refusées : connexion expirée, ou réseau coupé avec un jeton expiré (sortie de veille).
            // Sans limites gardées, « Quota indisponible » plus bas le dit déjà.
            Banner {
                width: parent.width
                text: av.provider.state === "expired" && av.main ? av.provider.detail + " Dernières valeurs enregistrées affichées." : ""
            }
            // Échec du dernier harness de cet agent (page du dashboard) : affiché ici seulement.
            Banner {
                width: parent.width
                text: av.provider.error
            }

            Row {
                width: parent.width
                Stat {
                    id: spend
                    width: parent.width * 0.58
                    title: "Dépense"
                    value: Burn.money(root.spent(av.series, 30))
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
                // Pourquoi : non connecté ou hors ligne (Claude), relevé absent ou expiré (logs Codex de plus de 7 j).
                Txt {
                    width: parent.width
                    text: Burn.loading ? "Chargement des limites d'abonnement." : av.provider.detail
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
                        Accessible.ignored: true
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
                value: Burn.money(Burn.priced(root.sum(gv.all, "cost"), root.sum(gv.all, "tokens")))
                detail: "Tous agents · équivalent API"
                size: 36
            }
            Row {
                visible: gv.all.length > 0
                width: parent.width
                Stat {
                    width: parent.width / 2
                    title: "Tokens"
                    value: Burn.tokens(root.sum(gv.all, "tokens"))
                    detail: "Entrée, sortie et cache"
                    size: 22
                }
                Stat {
                    width: parent.width / 2
                    title: "Aujourd'hui"
                    value: Burn.money(root.spent(gv.all, 1))
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
                    BurnButton {
                        id: agentRow
                        required property string modelData
                        readonly property var series: Burn.dailySeries(modelData)
                        readonly property string tokensText: Burn.tokens(root.sum(series, "tokens")) + " tokens"
                        readonly property string costText: Burn.money(Burn.priced(root.sum(series, "cost"), root.sum(series, "tokens")))
                        width: list.width
                        height: 40
                        radius: 10
                        color: Colors.withAlpha(Colors.muted, 0.08)
                        // Agent à quota : la ligne ouvre son onglet (app Mac : « Busiest agents »).
                        enabled: root.quotaAgents.includes(agentRow.modelData)
                        Accessible.role: agentRow.enabled ? Accessible.Button : Accessible.ListItem
                        Accessible.name: Burn.agentName(agentRow.modelData) + " : " + agentRow.tokensText + ", " + agentRow.costText
                        onClicked: root.tab = agentRow.modelData
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
                            spoken: false
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 12
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                text: agentRow.tokensText
                                color: Colors.muted
                                font.pixelSize: 11
                                spoken: false
                            }
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 84
                                horizontalAlignment: Text.AlignRight
                                text: agentRow.costText
                                font.bold: true
                                spoken: false
                            }
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
                    text: Burn.money(root.spent(gv.all, 14))
                    color: Colors.muted
                    font.pixelSize: 11
                }
            }
            BurnBarChart {
                id: spark
                visible: gv.all.length > 0
                width: parent.width
                compact: true
                points: spark.lastDays(gv.all, 14)
                unit: ""   // total des 14 jours déjà en en-tête
            }
        }
    }
}
