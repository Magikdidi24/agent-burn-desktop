pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Widgets
import QtQuick

// Contenu du tableau de bord Agent Burn (fenêtre de l'app Mac), sans fenêtre : BurnDashboard
// l'héberge, un harnais de test peut l'afficher seul. Barre latérale (tous les agents / un agent),
// page défilante, pied « Mis à jour » fixe.
// Dépense, tokens et jours viennent de l'archive (Burn.dailySeries) : elle garde les jours
// que les agents ont purgés de leurs logs.
Item {
    id: root

    // "all" ou un agent ; tenue par Burn pour que le popover ouvre le dashboard sur son onglet.
    property string page: Burn.dashboardPage
    readonly property string agent: page === "all" ? "" : page
    readonly property color tint: agent ? Burn.agentColor(agent) : Colors.accent

    readonly property var ranges: [
        { key: "all", label: "Tout", long: "Tout l'historique" },
        { key: "30d", label: "30 jours", long: "30 derniers jours" },
        { key: "7d", label: "7 jours", long: "7 derniers jours" },
        { key: "today", label: "Aujourd'hui", long: "Aujourd'hui" }
    ]
    readonly property string rangeLong: ranges.find(r => r.key === Burn.range)?.long ?? ""

    // Jours de la plage, aujourd'hui inclus (même borne que le --since de Burn.loadRange).
    function inRange(series) {
        const n = Burn.spans[Burn.range];   // jours avant aujourd'hui ; absent pour « Tout »
        if (n === undefined) return series;
        const d = new Date();
        d.setDate(d.getDate() - n);
        const from = Qt.formatDate(d, "yyyy-MM-dd");
        return series.filter(p => p.date >= from);
    }
    function total(series, key) { return series.reduce((s, p) => s + (p[key] || 0), 0); }

    readonly property var days: inRange(Burn.dailySeries(agent))
    readonly property bool noData: !Burn.summary && days.length === 0   // ni rapport ni archive : « — », pas 0
    // Modèles de la plage ; null pendant le 1er chargement de rangeSummary.
    readonly property var models: {
        const s = Burn.rangeSummary;
        if (!s) return null;
        if (!agent) return s.models ?? [];
        return (s.agents ?? []).find(e => e.agent === agent)?.models ?? [];
    }
    // Pas de flèche à corps `{}` ici : qmllint abandonne alors l'analyse de tout le fichier.
    readonly property var agentRows: {
        const rows = [];
        for (const a of Burn.agents) {
            const s = inRange(Burn.dailySeries(a));
            const r = { agent: a, cost: total(s, "cost"), tokens: total(s, "tokens") };
            if (r.cost > 0 || r.tokens > 0) rows.push(r);
        }
        return rows.sort((x, y) => y.cost - x.cost);
    }

    readonly property var sub: agent ? Burn.subEntry(agent) : null
    readonly property var limits: agent ? Burn.windows(agent) : []
    readonly property var weekly: limits.find(w => w.key === "weekly") ?? null
    readonly property var weeklyPace: weekly ? Burn.pace(agent, "weekly") : null
    readonly property var harness: agent ? (Burn.harnesses[agent] ?? null) : null

    property string sortKey: "totalCost"
    property bool sortAsc: false
    readonly property var modelRows: {
        const q = search.text.toLowerCase(), k = sortKey, dir = sortAsc ? 1 : -1;
        return (models ?? []).filter(m => m.model.toLowerCase().includes(q))
            .sort((a, b) => dir * (k === "model" ? a.model.localeCompare(b.model) : a[k] - b[k]));
    }
    // Colonnes Modèle | Tokens | Dépense | Part : la première prend le reste.
    function colW(i, w) { return [w - 400, 120, 130, 150][i]; }

    onPageChanged: flick.contentY = 0

    component Txt: Text {
        color: Colors.foreground
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 12
        textFormat: Text.PlainText
    }
    // Carte : fond translucide, contenu empilé avec 18 px de marge.
    component Card: Rectangle {
        id: card
        default property alias content: cardBody.data
        implicitHeight: cardBody.implicitHeight + 36
        radius: 14
        color: Colors.withAlpha(Colors.surface, 0.55)
        Column { id: cardBody; x: 18; y: 18; width: card.width - 36; spacing: 12 }
    }
    // Titre de carte, précision discrète à droite.
    component Heading: Item {
        id: heading
        property string title
        property string detail
        implicitHeight: 20
        Txt { anchors.verticalCenter: parent.verticalCenter; text: heading.title; font.pixelSize: 14; font.bold: true }
        Txt {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: heading.detail
            color: Colors.muted
            font.pixelSize: 11
        }
    }
    // Barre fine, value sur 0..1 (NaN d'une division par zéro = vide).
    component Meter: Rectangle {
        id: meter
        property real value
        property color fill: Colors.accent
        implicitHeight: 6
        radius: height / 2
        color: Colors.withAlpha(Colors.muted, 0.18)
        Rectangle {
            width: meter.width * Math.max(0, Math.min(1, meter.value || 0))
            height: meter.height
            radius: meter.radius
            color: meter.fill
        }
    }
    // Jauge : intitulé à gauche, chiffres à droite, barre dessous.
    component Gauge: Column {
        id: gauge
        property string label
        property string value
        property real ratio
        property color fill: Colors.accent
        spacing: 6
        Item {
            width: gauge.width
            height: 16
            Txt {
                width: parent.width - gaugeValue.implicitWidth - 12
                elide: Text.ElideRight
                text: gauge.label
                font.bold: true
            }
            Txt { id: gaugeValue; anchors.right: parent.right; text: gauge.value; color: Colors.muted }
        }
        Meter { width: gauge.width; value: gauge.ratio; fill: gauge.fill }
    }

    // ── Barre latérale ──
    Rectangle {
        id: side
        width: 210
        height: parent.height
        color: Colors.withAlpha(Colors.surface, 0.3)

        Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Colors.withAlpha(Colors.muted, 0.15)
        }

        Column {
            x: 10
            y: 18
            width: parent.width - 20
            spacing: 2

            // Nom de l'app : sous Hyprland la fenêtre n'a pas de barre de titre.
            Row {
                leftPadding: 10
                bottomPadding: 14
                spacing: 8
                Txt { text: "\uf06d"; color: Colors.accent; font.pixelSize: 16 }  // fire
                Txt { text: "Agent Burn"; font.pixelSize: 14; font.bold: true }
            }

            Repeater {
                model: ["all"].concat(Burn.agents)
                delegate: Rectangle {
                    id: entry
                    required property string modelData
                    readonly property bool sel: root.page === modelData
                    width: parent.width
                    height: 36
                    radius: 10
                    color: sel ? Colors.withAlpha(Colors.accent, 0.18)
                         : entryMa.containsMouse ? Colors.withAlpha(Colors.muted, 0.10) : "transparent"

                    Txt {
                        x: 10
                        width: 22
                        anchors.verticalCenter: parent.verticalCenter
                        visible: entry.modelData === "all"
                        horizontalAlignment: Text.AlignHCenter
                        text: "\uf080"  // bar-chart
                        color: Colors.accent
                        font.pixelSize: 15
                    }
                    IconImage {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 22
                        source: Burn.agentIcon(entry.modelData)
                    }
                    Txt {
                        x: 42
                        width: parent.width - 50
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: entry.modelData === "all" ? "Tous les agents" : Burn.agentName(entry.modelData)
                        color: entry.sel ? Colors.foreground : Colors.withAlpha(Colors.foreground, 0.75)
                        font.bold: entry.sel
                    }
                    MouseArea {
                        id: entryMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Burn.dashboardPage = entry.modelData
                    }
                }
            }
        }
    }

    // ── Page ──
    Flickable {
        id: flick
        anchors { left: side.right; right: parent.right; top: parent.top; bottom: foot.top }
        contentHeight: pageCol.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: pageCol
            x: 24
            y: 24
            width: flick.width - 48
            spacing: 14

            // En-tête : icône, titre, plage ; sélecteur de plage à droite.
            Item {
                id: header
                width: parent.width
                height: 52
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Item {
                        width: 40
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter
                        Txt {
                            anchors.centerIn: parent
                            visible: !root.agent
                            text: "\uf080"  // bar-chart
                            color: Colors.accent
                            font.pixelSize: 30
                        }
                        IconImage { anchors.fill: parent; source: Burn.agentIcon(root.agent) }
                    }
                    Column {
                        width: header.width - rangePicker.width - 70
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Txt {
                            text: root.agent ? Burn.agentName(root.agent) : "Tous les agents"
                            font.pixelSize: 22
                            font.bold: true
                        }
                        Txt {
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.rangeLong + " · usage depuis tes logs et les fournisseurs connectés"
                            color: Colors.muted
                        }
                    }
                }
                Rectangle {
                    id: rangePicker
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: seg.implicitWidth + 6
                    height: 32
                    radius: 10
                    color: Colors.withAlpha(Colors.surface, 0.55)
                    Row {
                        id: seg
                        x: 3
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: root.ranges
                            delegate: Rectangle {
                                id: opt
                                required property var modelData
                                readonly property bool sel: Burn.range === modelData.key
                                width: optText.implicitWidth + 22
                                height: 26
                                radius: 8
                                color: sel ? Colors.withAlpha(Colors.accent, 0.25)
                                     : optMa.containsMouse ? Colors.withAlpha(Colors.muted, 0.12) : "transparent"
                                Txt {
                                    id: optText
                                    anchors.centerIn: parent
                                    text: opt.modelData.label
                                    color: opt.sel ? Colors.foreground : Colors.muted
                                }
                                MouseArea {
                                    id: optMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Burn.setRange(opt.modelData.key)
                                }
                            }
                        }
                    }
                }
            }

            // Archive locale : jours conservés, accès au dossier.
            Item {
                width: parent.width
                height: 30
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uf1c0   Historique journalier · " + Burn.historyDays  // database
                          + (Burn.historyDays > 1 ? " jours conservés" : " jour conservé") + " sur ce PC"
                    color: Colors.muted
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: backupText.implicitWidth + 24
                    height: 28
                    radius: 8
                    color: Colors.withAlpha(Colors.muted, backupMa.containsMouse ? 0.25 : 0.15)
                    Txt { id: backupText; anchors.centerIn: parent; text: "\uf07c  Afficher la sauvegarde" }  // folder-open
                    MouseArea {
                        id: backupMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["xdg-open", Burn.dataDir])
                    }
                }
            }

            // Erreur du CLI, connexion Claude expirée (page Claude), ou 1er chargement encore vide.
            Rectangle {
                id: notice
                readonly property string msg: Burn.error || (root.agent === "claude" && Burn.signInExpired
                    ? "Connexion Claude Code expirée : lance claude dans un terminal puis /login. "
                      + "Dernières valeurs enregistrées affichées." : "")
                visible: msg !== "" || (!Burn.summary && Burn.loading)
                width: parent.width
                height: noticeText.implicitHeight + 22
                radius: 10
                color: Colors.withAlpha(msg ? Colors.danger : Colors.muted, 0.12)
                Txt {
                    id: noticeText
                    x: 14
                    width: parent.width - 28
                    anchors.verticalCenter: parent.verticalCenter
                    wrapMode: Text.WordWrap
                    text: notice.msg ? "\uf071  " + notice.msg : "Lecture de l'usage…"  // warning
                    color: notice.msg ? Colors.danger : Colors.muted
                }
            }

            // Forfait : une jauge par fenêtre de limite, puis les crédits supplémentaires (Claude).
            Card {
                width: parent.width
                visible: root.sub !== null || root.limits.length > 0
                Item {
                    width: parent.width
                    height: 22
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Txt { text: "\uf09d"; color: root.tint; font.pixelSize: 15 }  // credit-card
                        Txt { text: "Forfait " + (root.sub?.plan ?? ""); font.pixelSize: 14; font.bold: true }
                        // Âge du relevé des limites Claude : le pied ne date que le summary.
                        Txt {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.agent === "claude" && !!Burn.account
                            text: "· relevé " + Burn.ago(Burn.account?.observedAtMs ?? 0)
                            color: Burn.limitsStale ? Colors.warn : Colors.muted
                        }
                    }
                    Txt {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.sub?.pricePerMonth != null
                        text: Burn.money(root.sub?.pricePerMonth) + " / mois"
                        color: Colors.muted
                    }
                }
                Repeater {
                    model: root.limits
                    delegate: Gauge {
                        required property var modelData
                        readonly property var pace: Burn.pace(root.agent, modelData.key)
                        width: parent.width
                        label: modelData.label
                        // Rythme aussi écrit : selon le fond d'écran, good et danger se confondent.
                        value: Burn.pct(modelData.used) + " utilisé"
                               + (modelData.resetsAtMs > 0 ? " · réinit. " + Burn.until(modelData.resetsAtMs) : "")
                               + (pace.status === "warn" || pace.status === "danger" ? " · " + pace.title : "")
                        ratio: modelData.used / 100
                        fill: Burn.tone(pace.status)
                    }
                }
                Txt {
                    visible: root.limits.length === 0
                    text: "Aucune limite relevée pour ce forfait."
                    color: Colors.muted
                }
                Gauge {
                    width: parent.width
                    visible: root.agent === "claude" && Burn.account?.extraEnabled === true
                    label: "Crédits supplémentaires"
                    value: Burn.pct(Burn.account?.extraUsedPercent) + " utilisé · " + Burn.money(Burn.account?.extraUsedUSD)
                           + " sur " + Burn.money(Burn.account?.extraLimitUSD)
                    ratio: (Burn.account?.extraUsedPercent ?? 0) / 100
                    fill: root.tint
                }
            }

            // Limite hebdomadaire : reste, rythme et trajectoire jusqu'au reset.
            Card {
                width: parent.width
                visible: root.weekly !== null
                Row {
                    width: parent.width
                    spacing: 24
                    Column {
                        id: weekCol
                        width: 260
                        spacing: 10
                        Txt {
                            text: "LIMITE HEBDOMADAIRE"
                            color: Colors.muted
                            font.pixelSize: 11
                            font.bold: true
                            font.letterSpacing: 0.6
                        }
                        Row {
                            spacing: 8
                            Txt { id: weekLeft; text: Burn.pct(root.weekly?.remaining); font.pixelSize: 40; font.bold: true }
                            Txt { anchors.baseline: weekLeft.baseline; text: "restant"; color: Colors.muted; font.pixelSize: 13 }
                        }
                        Row {
                            spacing: 8
                            Txt {
                                text: root.weeklyPace?.status === "good" ? "\uf058" : "\uf071"  // check-circle / warning
                                color: Burn.tone(root.weeklyPace?.status)
                                font.pixelSize: 14
                            }
                            Txt {
                                width: weekCol.width - 30
                                wrapMode: Text.WordWrap
                                text: root.weeklyPace?.title ?? ""
                                font.pixelSize: 13
                                font.bold: true
                            }
                        }
                        Txt {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: root.weeklyPace?.detail ?? ""
                            color: Colors.muted
                        }
                        Txt {
                            visible: (root.weekly?.resetsAtMs ?? 0) > 0
                            text: "\uf017  Réinitialisation " + Burn.until(root.weekly?.resetsAtMs ?? 0)  // clock
                            color: Colors.muted
                        }
                    }
                    BurnQuotaChart {
                        width: parent.width - weekCol.width - parent.spacing
                        height: 220
                        startMs: root.weekly?.startMs ?? 0
                        // Reset inconnu : fin théorique de la fenêtre.
                        endMs: root.weekly ? (root.weekly.resetsAtMs || root.weekly.startMs + root.weekly.durationMin * 60000) : 0
                        samples: root.weekly ? Burn.quotaSamples(root.agent, "weekly") : []
                        used: root.weekly?.used ?? -1
                        projected: root.weeklyPace?.projected ?? -1
                        accent: Burn.tone(root.weeklyPace?.status)
                    }
                }
            }

            // Abonnement sur 30 jours (`harness <agent>`) : rentabilité et coût par type de token.
            Row {
                width: parent.width
                spacing: 14
                visible: root.harness !== null
                Card {
                    id: eco
                    readonly property var e: root.harness?.economics ?? null
                    readonly property real peak: Math.max(e?.apiEquivalentPerMonth ?? 0, e?.pricePerMonth ?? 0)
                    visible: e !== null
                    width: (parent.width - parent.spacing) / 2
                    height: Math.max(eco.implicitHeight, mix.implicitHeight)
                    Heading { width: parent.width; title: "Économie du forfait"; detail: "30 derniers jours" }
                    Row {
                        spacing: 10
                        Txt { id: mult; text: "×" + (eco.e?.valueMultiple ?? 0).toFixed(2); font.pixelSize: 36; font.bold: true }
                        Txt { anchors.baseline: mult.baseline; text: "valeur d'usage / prix du forfait"; color: Colors.muted }
                    }
                    Gauge {
                        width: parent.width
                        label: "Équivalent API"
                        value: Burn.money(eco.e?.apiEquivalentPerMonth)
                        ratio: (eco.e?.apiEquivalentPerMonth ?? 0) / eco.peak
                        fill: root.tint
                    }
                    Gauge {
                        width: parent.width
                        label: "Forfait"
                        value: Burn.money(eco.e?.pricePerMonth)
                        ratio: (eco.e?.pricePerMonth ?? 0) / eco.peak
                        fill: Colors.muted
                    }
                    Txt {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: Burn.money(eco.e?.subsidyPerMonth) + " / mois au-delà du forfait · remise de "
                              + Burn.pct(eco.e?.discountPercent, 1) + " sur le tarif API"
                        color: Colors.muted
                        font.pixelSize: 11
                    }
                }
                Card {
                    id: mix
                    readonly property var parts: root.harness?.spendMix ?? []
                    visible: parts.length > 0
                    width: (parent.width - parent.spacing) / 2
                    height: eco.height
                    Heading { width: parent.width; title: "Répartition par type de token"; detail: "30 derniers jours" }
                    Repeater {
                        model: mix.parts
                        delegate: Gauge {
                            required property var modelData
                            width: parent.width
                            // Clés du CLI ; libellé brut pour une catégorie inconnue.
                            label: ({ input: "Entrée", output: "Sortie", cacheCreation: "Écriture cache",
                                      cacheRead: "Lecture cache" })[modelData.key] ?? modelData.label
                            value: Burn.pct(modelData.costPercent, 1) + " · " + Burn.tokens(modelData.tokens)
                                   + " · " + Burn.money(modelData.costUSD)
                            ratio: modelData.costPercent / 100
                            fill: root.tint
                        }
                    }
                }
            }

            // Chiffres de la plage.
            Card {
                width: parent.width
                Row {
                    width: parent.width
                    Repeater {
                        model: [
                            { title: "Dépense totale", value: root.noData ? "—" : Burn.money(root.total(root.days, "cost")),
                              detail: "Équivalent API" },
                            { title: "Tokens", value: root.noData ? "—" : Burn.tokens(root.total(root.days, "tokens")),
                              detail: "Entrée, sortie et cache" },
                            { title: "Jours enregistrés", value: root.noData ? "—" : String(root.days.length), detail: root.rangeLong },
                            { title: "Modèles", value: root.models ? String(root.models.length) : "—",
                              detail: root.agent ? Burn.agentName(root.agent) : "Tous agents confondus" }
                        ]
                        delegate: Item {
                            id: stat
                            required property var modelData
                            required property int index
                            width: parent.width / 4
                            height: statCol.implicitHeight
                            Rectangle {
                                visible: stat.index > 0
                                width: 1
                                height: parent.height
                                color: Colors.withAlpha(Colors.muted, 0.2)
                            }
                            Column {
                                id: statCol
                                x: stat.index > 0 ? 20 : 0
                                width: parent.width - x - 8
                                spacing: 6
                                Txt { text: stat.modelData.title; color: Colors.muted }
                                Txt {
                                    width: parent.width
                                    text: stat.modelData.value
                                    font.pixelSize: 32
                                    font.bold: true
                                    fontSizeMode: Text.HorizontalFit
                                    minimumPixelSize: 18
                                }
                                Txt {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: stat.modelData.detail
                                    color: Colors.muted
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }
                }
            }

            // Dépense journalière ; sur « Tous », la liste par agent à côté (comme l'app Mac).
            Row {
                width: parent.width
                spacing: 14
                Card {
                    width: parent.width - (byAgent.visible ? byAgent.width + parent.spacing : 0)
                    Heading { width: parent.width; title: "Dépense journalière" }
                    BurnBarChart {
                        width: parent.width
                        height: 220
                        // Plage bornée : tous ses jours (0 $ sans usage), l'axe la couvre en entier.
                        points: Burn.range === "all" ? root.days.map(d => ({ date: d.date, value: d.cost }))
                            : Burn.lastDays(root.days, Burn.spans[Burn.range] + 1)
                        barColor: root.tint
                    }
                }
                Card {
                    id: byAgent
                    visible: !root.agent
                    width: 300
                    Heading {
                        width: parent.width
                        title: "Par agent"
                        detail: root.agentRows.length + (root.agentRows.length > 1 ? " actifs" : " actif")
                    }
                    ListView {
                        width: parent.width
                        height: 220   // = hauteur du graphe : les deux cartes s'alignent
                        clip: true
                        spacing: 2
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.agentRows
                        delegate: Rectangle {
                            id: ag
                            required property var modelData
                            width: ListView.view.width
                            height: 52
                            radius: 10
                            color: agMa.containsMouse ? Colors.withAlpha(Colors.muted, 0.10) : "transparent"
                            IconImage {
                                x: 8
                                anchors.verticalCenter: parent.verticalCenter
                                implicitSize: 26
                                source: Burn.agentIcon(ag.modelData.agent)
                            }
                            Column {
                                x: 44
                                width: parent.width - 52
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 5
                                Item {
                                    width: parent.width
                                    height: 15
                                    Txt { text: Burn.agentName(ag.modelData.agent); font.bold: true }
                                    Txt { anchors.right: parent.right; text: Burn.money(ag.modelData.cost); font.bold: true }
                                }
                                Meter {
                                    width: parent.width
                                    implicitHeight: 4
                                    value: ag.modelData.cost / root.agentRows[0].cost
                                    fill: Burn.agentColor(ag.modelData.agent)
                                }
                                Txt { text: Burn.tokens(ag.modelData.tokens) + " tokens"; color: Colors.muted; font.pixelSize: 10 }
                            }
                            MouseArea {
                                id: agMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Burn.dashboardPage = ag.modelData.agent
                            }
                        }
                        Txt {
                            anchors.centerIn: parent
                            visible: root.agentRows.length === 0
                            text: "Aucune dépense sur cette période."
                            color: Colors.muted
                        }
                    }
                }
            }

            // Modèles : filtre, tri au clic sur l'en-tête (défaut : dépense décroissante).
            Card {
                width: parent.width
                Item {
                    width: parent.width
                    height: 30
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Txt { text: "Modèles · données sources disponibles"; font.pixelSize: 14; font.bold: true }
                        Txt {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.models ? root.models.length : "—"
                            color: Colors.muted
                        }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        width: 230
                        height: 30
                        radius: 8
                        color: Colors.withAlpha(Colors.background, 0.6)
                        border.width: 1
                        border.color: search.activeFocus ? Colors.accent : Colors.withAlpha(Colors.muted, 0.3)
                        Txt { x: 10; anchors.verticalCenter: parent.verticalCenter; text: "\uf002"; color: Colors.muted }  // search
                        TextInput {
                            id: search
                            x: 32
                            width: parent.width - 42
                            anchors.verticalCenter: parent.verticalCenter
                            color: Colors.foreground
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 12
                            clip: true
                            selectByMouse: true
                            selectionColor: Colors.withAlpha(Colors.accent, 0.5)
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: search.text === ""
                                text: "Filtrer les modèles"
                                color: Colors.withAlpha(Colors.muted, 0.8)
                            }
                        }
                    }
                }
                // Un seul bloc : l'espacement de la carte décollerait l'en-tête des lignes.
                Column {
                    width: parent.width
                    Row {
                        width: parent.width
                        height: 26
                        Repeater {
                            model: [["model", "Modèle"], ["totalTokens", "Tokens"], ["totalCost", "Dépense"], ["percentage", "Part"]]
                            delegate: Item {
                                id: colHead
                                required property var modelData
                                required property int index
                                readonly property bool sorted: root.sortKey === modelData[0]
                                width: root.colW(index, parent.width)
                                height: parent.height
                                Row {
                                    x: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    Txt {
                                        text: colHead.modelData[1]
                                        color: colHead.sorted ? Colors.foreground : Colors.muted
                                        font.pixelSize: 11
                                        font.bold: true
                                    }
                                    Txt {
                                        visible: colHead.sorted
                                        text: "\uf0d7"  // caret-down, retourné en tri croissant
                                        rotation: root.sortAsc ? 180 : 0
                                        color: Colors.muted
                                        font.pixelSize: 11
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (colHead.sorted) root.sortAsc = !root.sortAsc;
                                        else { root.sortKey = colHead.modelData[0]; root.sortAsc = colHead.modelData[0] === "model"; }
                                    }
                                }
                            }
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: Colors.withAlpha(Colors.muted, 0.2) }
                    Repeater {
                        model: root.modelRows
                        delegate: Rectangle {
                            id: mrow
                            required property var modelData
                            required property int index
                            width: parent.width
                            height: 30
                            radius: 6
                            color: index % 2 ? Colors.withAlpha(Colors.muted, 0.07) : "transparent"
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                Txt {
                                    width: root.colW(0, mrow.width)
                                    leftPadding: 10
                                    rightPadding: 10
                                    elide: Text.ElideRight
                                    text: mrow.modelData.model
                                }
                                Txt {
                                    width: root.colW(1, mrow.width)
                                    leftPadding: 10
                                    text: Burn.tokens(mrow.modelData.totalTokens)
                                    color: Colors.muted
                                }
                                Txt { width: root.colW(2, mrow.width); leftPadding: 10; text: Burn.money(mrow.modelData.totalCost) }
                                Row {
                                    leftPadding: 10
                                    spacing: 8
                                    Meter {
                                        width: 44
                                        implicitHeight: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        value: mrow.modelData.percentage / 100
                                        fill: root.tint
                                    }
                                    Txt { text: Burn.pct(mrow.modelData.percentage, 1); color: Colors.muted }
                                }
                            }
                        }
                    }
                }
                Txt {
                    visible: root.modelRows.length === 0
                    text: root.models === null ? (Burn.loading ? "Chargement des modèles…"
                                                                : "Modèles indisponibles : rapport agent-burn non lu.")
                        : search.text !== "" ? "Aucun modèle ne correspond au filtre."
                        : "Aucun modèle utilisé sur cette période."
                    color: Colors.muted
                }
            }
        }
    }

    // Indicateur de défilement (le Flickable n'en dessine pas).
    Rectangle {
        x: flick.x + flick.width - 7
        y: flick.y + flick.visibleArea.yPosition * flick.height
        width: 4
        height: flick.visibleArea.heightRatio * flick.height
        radius: 2
        visible: flick.visibleArea.heightRatio < 1
        color: Colors.withAlpha(Colors.muted, 0.35)
    }

    // ── Pied fixe : fraîcheur des données, rafraîchissement forcé ──
    Rectangle {
        id: foot
        anchors { left: side.right; right: parent.right; bottom: parent.bottom }
        height: 34
        color: Colors.withAlpha(Colors.surface, 0.3)
        Rectangle { width: parent.width; height: 1; color: Colors.withAlpha(Colors.muted, 0.15) }
        Row {
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle {
                width: 6
                height: 6
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: Burn.error ? Colors.danger : Colors.good
            }
            Txt {
                text: Burn.updatedAt === 0 ? (Burn.loading ? "Lecture de l'usage…" : "Aucune donnée pour l'instant")
                    : (Burn.error ? "Dernière mise à jour réussie " : "Mis à jour ") + Burn.ago(Burn.updatedAt)
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        Txt {
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "\uf021"  // refresh
            color: refreshMa.containsMouse ? Colors.foreground : Colors.muted
            RotationAnimation on rotation {
                running: Burn.loading
                from: 0
                to: 360
                duration: 1000
                loops: Animation.Infinite
                alwaysRunToEnd: true   // finit le tour : l'icône s'arrête droite
            }
            MouseArea {
                id: refreshMa
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Burn.refresh(true)
            }
        }
    }
}
