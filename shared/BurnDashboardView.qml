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
    // Réglages de l'hôte (app de bureau) : bouton en bas de la barre latérale. La barre Quickshell n'en a pas.
    property bool settingsAvailable: false
    signal settingsRequested()

    readonly property var pages: ["all"].concat(Burn.agents)
    readonly property var provider: agent ? Burn.providerState(agent) : null
    // Carte « Fournisseurs » : Claude et Codex toujours, même absents, puis les autres agents vus.
    readonly property var providerIds: Burn.knownProviders.concat(Burn.agents.filter(a => !Burn.knownProviders.includes(a)))
    // Bandeaux, du plus grave au moins grave : erreur du CLI ; page d'un agent, son erreur (harness) et
    // son état s'il n'est pas en direct ; tarifs manquants. 1er chargement : « Lecture de l'usage… ».
    readonly property var notices: {
        const n = [], p = provider;
        if (Burn.error) n.push({ msg: Burn.error, tint: Colors.danger });
        if (p?.error) n.push({ msg: p.error, tint: Colors.danger });
        if (!Burn.summary && Burn.loading) n.push({ msg: "Lecture de l'usage…", tint: Colors.muted, plain: true });
        else if (p && p.state !== "live")
            n.push({ msg: p.detail + (p.state === "expired" && limits.length ? " Dernières valeurs enregistrées affichées." : ""),
                     tint: stateTone(p.state) });
        if (Burn.pricingMissing)
            n.push({ msg: "Tarifs indisponibles : montants incomplets (réseau coupé ou tarifs non téléchargés)", tint: Colors.warn });
        return n;
    }

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
    // Teinte d'un état de Burn.providerState : le mot reste écrit à côté.
    function stateTone(s) { return Burn.tone({ live: "good", stale: "warn", expired: "danger", unavailable: "danger" }[s] ?? ""); }
    // Flèches de la barre latérale et du sélecteur de plage : voisin sélectionné et focalisé.
    function stepPage(d) {
        const i = pages.indexOf(page) + d;
        if (i < 0 || i >= pages.length) return;
        Burn.dashboardPage = pages[i];
        sideEntries.itemAt(i).forceActiveFocus();
    }
    function stepRange(d) {
        const i = ranges.findIndex(r => r.key === Burn.range) + d;
        if (i < 0 || i >= ranges.length) return;
        Burn.setRange(ranges[i].key);
        rangeOptions.itemAt(i).forceActiveFocus();
    }

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

    // Clavier : le contrôle focalisé (Tab) reste visible, chaque Flickable qui le contient (page, liste
    // « Par agent ») défile jusqu'à lui.
    function reveal(item) {
        for (let f = item?.parent; f; f = f.parent) {
            if (!(f instanceof Flickable)) continue;
            const y = item.mapToItem(f.contentItem, 0, 0).y, bottom = f.originY + Math.max(0, f.contentHeight - f.height);
            if (y - 12 < f.contentY)
                f.contentY = Math.max(f.originY, y - 12);
            else if (y + item.height + 12 > f.contentY + f.height)
                f.contentY = Math.min(bottom, y + item.height + 12 - f.height);
        }
    }
    Window.onActiveFocusItemChanged: root.reveal(Window.activeFocusItem)
    // PageUp / PageDown / Début / Fin font défiler la page (touches que le contrôle focalisé n'a pas prises).
    Keys.onPressed: event => {
        const bottom = Math.max(0, flick.contentHeight - flick.height), step = flick.height - 40;
        const to = event.key === Qt.Key_PageDown ? flick.contentY + step : event.key === Qt.Key_PageUp ? flick.contentY - step
                 : event.key === Qt.Key_Home ? 0 : event.key === Qt.Key_End ? bottom : NaN;
        if (isNaN(to)) return;
        flick.contentY = Math.max(0, Math.min(bottom, to));
        event.accepted = true;
    }

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
    // Titre de carte, précision discrète à droite ; carte étroite (fenêtre à sa taille minimale) : la
    // précision cède la place au titre.
    component Heading: Item {
        id: heading
        property string title
        property string detail
        implicitHeight: 20
        Txt { id: headingTitle; anchors.verticalCenter: parent.verticalCenter; text: heading.title; font.pixelSize: 14; font.bold: true }
        Txt {
            id: headingDetail
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: heading.detail !== "" && headingTitle.implicitWidth + headingDetail.implicitWidth + 12 <= heading.width
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
    // État d'un fournisseur (Burn.providerState) : le mot, le point teinté n'en est qu'un rappel.
    component Badge: Rectangle {
        id: badge
        property string label
        property color tone
        width: badgeRow.implicitWidth + 20
        height: 24
        radius: 12
        color: Colors.withAlpha(tone, 0.14)
        Row {
            id: badgeRow
            anchors.centerIn: parent
            spacing: 5
            Txt { text: "●"; color: badge.tone; font.pixelSize: 11; Accessible.ignored: true }
            Txt { text: badge.label; font.pixelSize: 11; font.bold: true }
        }
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
                Txt { text: "\uf06d"; color: Colors.accent; font.pixelSize: 16; Accessible.ignored: true }  // fire
                Txt { text: "Agent Burn"; font.pixelSize: 14; font.bold: true }
            }

            // Pages : onglets verticaux, flèches haut / bas pour passer de l'un à l'autre.
            Repeater {
                id: sideEntries
                model: root.pages
                delegate: BurnButton {
                    id: entry
                    required property string modelData
                    readonly property bool sel: root.page === modelData
                    width: parent.width
                    height: 36
                    radius: 10
                    color: sel ? Colors.withAlpha(Colors.accent, 0.18)
                         : entry.hovered ? Colors.withAlpha(Colors.muted, 0.10) : "transparent"
                    Accessible.role: Accessible.PageTab
                    Accessible.name: entryLabel.text
                    Accessible.checkable: true
                    Accessible.checked: entry.sel
                    Keys.onUpPressed: root.stepPage(-1)
                    Keys.onDownPressed: root.stepPage(1)
                    onClicked: Burn.dashboardPage = entry.modelData

                    Txt {
                        x: 10
                        width: 22
                        anchors.verticalCenter: parent.verticalCenter
                        visible: entry.modelData === "all"
                        horizontalAlignment: Text.AlignHCenter
                        text: "\uf080"  // bar-chart
                        color: Colors.accent
                        font.pixelSize: 15
                        Accessible.ignored: true
                    }
                    IconImage {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 22
                        source: Burn.agentIcon(entry.modelData)
                    }
                    Txt {
                        id: entryLabel
                        x: 42
                        width: parent.width - 50
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: entry.modelData === "all" ? "Tous les agents" : Burn.agentName(entry.modelData)
                        color: entry.sel ? Colors.foreground : Colors.withAlpha(Colors.foreground, 0.75)
                        font.bold: entry.sel
                    }
                }
            }
        }

        // Réglages : seulement si l'hôte en a (settingsAvailable), il ouvre sa vue sur settingsRequested.
        BurnButton {
            id: settings
            visible: root.settingsAvailable
            x: 10
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            width: parent.width - 20
            height: 36
            radius: 10
            color: settings.hovered ? Colors.withAlpha(Colors.muted, 0.10) : "transparent"
            Accessible.name: "Paramètres"
            onClicked: root.settingsRequested()
            Txt {
                x: 10
                width: 22
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text: "\uf013"  // cog
                color: Colors.muted
                font.pixelSize: 15
                Accessible.ignored: true
            }
            Txt {
                x: 42
                anchors.verticalCenter: parent.verticalCenter
                text: "Paramètres"
                color: Colors.withAlpha(Colors.foreground, 0.75)
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
                            Accessible.ignored: true
                        }
                        IconImage { anchors.fill: parent; source: Burn.agentIcon(root.agent) }
                    }
                    Column {
                        width: header.width - rangePicker.width - 70
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Row {
                            id: titleRow
                            width: parent.width
                            spacing: 12
                            // Fenêtre étroite : le nom s'abrège, le badge ne déborde pas sur le sélecteur de plage.
                            Txt {
                                width: Math.min(implicitWidth, titleRow.width - (pageBadge.visible ? pageBadge.width + titleRow.spacing : 0))
                                elide: Text.ElideRight
                                text: root.agent ? Burn.agentName(root.agent) : "Tous les agents"
                                font.pixelSize: 22
                                font.bold: true
                            }
                            // Page d'un agent : d'où viennent ses chiffres, en toutes lettres (détail en bandeau).
                            Badge {
                                id: pageBadge
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.provider !== null
                                label: root.provider?.label ?? ""
                                tone: root.stateTone(root.provider?.state ?? "")
                            }
                        }
                        Txt {
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.rangeLong + " · usage depuis tes logs et les fournisseurs connectés"
                            color: Colors.muted
                        }
                    }
                }
                // Plage : boutons radio, flèches gauche / droite.
                Rectangle {
                    id: rangePicker
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: seg.implicitWidth + 6
                    height: 32
                    radius: 10
                    color: Colors.withAlpha(Colors.surface, 0.55)
                    Accessible.role: Accessible.Grouping
                    Accessible.name: "Période"
                    Row {
                        id: seg
                        x: 3
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            id: rangeOptions
                            model: root.ranges
                            delegate: BurnButton {
                                id: opt
                                required property var modelData
                                readonly property bool sel: Burn.range === modelData.key
                                width: optText.implicitWidth + 22
                                height: 26
                                radius: 8
                                color: sel ? Colors.withAlpha(Colors.accent, 0.25)
                                     : opt.hovered ? Colors.withAlpha(Colors.muted, 0.12) : "transparent"
                                Accessible.role: Accessible.RadioButton
                                Accessible.name: opt.modelData.long
                                Accessible.checkable: true
                                Accessible.checked: opt.sel
                                Keys.onLeftPressed: root.stepRange(-1)
                                Keys.onRightPressed: root.stepRange(1)
                                onClicked: Burn.setRange(opt.modelData.key)
                                Txt {
                                    id: optText
                                    anchors.centerIn: parent
                                    text: opt.modelData.label
                                    color: opt.sel ? Colors.foreground : Colors.muted
                                    font.bold: opt.sel   // la sélection ne tient pas qu'à la couleur
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
                    id: archive
                    readonly property string kept: Burn.historyDays + (Burn.historyDays > 1 ? " jours conservés" : " jour conservé")
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - backup.width - 12   // fenêtre étroite : élidé, jamais sous le bouton
                    elide: Text.ElideRight
                    text: "\uf1c0   Historique journalier · " + archive.kept + " sur ce PC"  // database
                    color: Colors.muted
                    Accessible.name: "Historique journalier : " + archive.kept + " sur ce PC"
                }
                BurnButton {
                    id: backup
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: backupText.implicitWidth + 24
                    height: 28
                    radius: 8
                    color: Colors.withAlpha(Colors.muted, backup.hovered ? 0.25 : 0.15)
                    Accessible.name: "Afficher la sauvegarde"
                    onClicked: Quickshell.execDetached(["xdg-open", Burn.dataDir])
                    Txt { id: backupText; anchors.centerIn: parent; text: "\uf07c  Afficher la sauvegarde"; Accessible.ignored: true }  // folder-open
                }
            }

            Repeater {
                model: root.notices
                delegate: Rectangle {
                    id: notice
                    required property var modelData
                    width: parent.width
                    height: noticeText.implicitHeight + 22
                    radius: 10
                    color: Colors.withAlpha(modelData.tint, 0.12)
                    // Icône teintée, texte en couleur normale : lisible sur la teinte (3,7:1 en rouge sur rouge clair).
                    Txt {
                        x: 14
                        y: noticeText.y
                        visible: !notice.modelData.plain
                        text: "\uf071"  // warning
                        color: notice.modelData.tint
                        Accessible.ignored: true
                    }
                    Txt {
                        id: noticeText
                        x: notice.modelData.plain ? 14 : 36
                        width: parent.width - x - 14
                        anchors.verticalCenter: parent.verticalCenter
                        wrapMode: Text.WordWrap
                        text: notice.modelData.msg
                        color: notice.modelData.plain ? Colors.muted : Colors.foreground
                    }
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
                        Txt { text: "\uf09d"; color: root.tint; font.pixelSize: 15; Accessible.ignored: true }  // credit-card
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
                                Accessible.ignored: true
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
                            id: weekReset
                            readonly property string when: "Réinitialisation " + Burn.until(root.weekly?.resetsAtMs ?? 0)
                            visible: (root.weekly?.resetsAtMs ?? 0) > 0
                            text: "\uf017  " + weekReset.when  // clock
                            color: Colors.muted
                            Accessible.name: weekReset.when
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
                        width: parent.width
                        spacing: 10
                        Txt { id: mult; text: "×" + (eco.e?.valueMultiple ?? 0).toFixed(2); font.pixelSize: 36; font.bold: true }
                        Txt {
                            anchors.baseline: mult.baseline
                            width: parent.width - mult.width - parent.spacing   // carte étroite : élidé, pas sur la voisine
                            elide: Text.ElideRight
                            text: "valeur d'usage / prix du forfait"
                            color: Colors.muted
                        }
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
                    // Usage sous le prix du forfait (Codex peu utilisé) : écart négatif, et aucune remise.
                    Txt {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: eco.e?.subsidyPerMonth < 0
                            ? "Valeur d'usage inférieure de " + Burn.money(-eco.e.subsidyPerMonth) + " / mois au prix du forfait"
                            : Burn.money(eco.e?.subsidyPerMonth) + " / mois au-delà du forfait · remise de "
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
                                   + " · " + Burn.money(Burn.priced(modelData.costUSD, modelData.tokens))
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
                            { title: "Dépense totale", detail: "Équivalent API", value: root.noData ? "—"
                                : Burn.money(Burn.priced(root.total(root.days, "cost"), root.total(root.days, "tokens"))) },
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

            // Sur « Tous » : chaque fournisseur, son état et la provenance de ses chiffres.
            Card {
                width: parent.width
                visible: !root.agent
                Heading { width: parent.width; title: "Fournisseurs"; detail: "Claude et Codex, puis les agents détectés" }
                Repeater {
                    model: root.providerIds
                    delegate: Item {
                        id: prov
                        required property string modelData
                        readonly property var info: Burn.providerState(modelData)
                        width: parent.width
                        height: Math.max(26, provDetail.implicitHeight)
                        IconImage {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitSize: 20
                            source: Burn.agentIcon(prov.modelData)
                        }
                        Txt {
                            x: 30
                            width: 130
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: Burn.agentName(prov.modelData)
                            font.bold: true
                        }
                        Badge {
                            x: 170
                            anchors.verticalCenter: parent.verticalCenter
                            label: prov.info.label
                            tone: root.stateTone(prov.info.state)
                        }
                        Txt {
                            id: provDetail
                            x: 352
                            width: parent.width - x
                            anchors.verticalCenter: parent.verticalCenter
                            wrapMode: Text.WordWrap
                            text: prov.info.detail
                            color: Colors.muted
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
                        id: dailyChart
                        width: parent.width
                        height: 220
                        // Plage bornée : tous ses jours (0 $ sans usage), l'axe la couvre en entier.
                        points: Burn.range === "all" ? root.days.map(d => ({ date: d.date, value: Burn.priced(d.cost, d.tokens) }))
                            : dailyChart.lastDays(root.days, Burn.spans[Burn.range] + 1)
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
                        delegate: BurnButton {
                            id: ag
                            required property var modelData
                            readonly property string costText: Burn.money(Burn.priced(modelData.cost, modelData.tokens))
                            width: ListView.view.width
                            height: 52
                            radius: 10
                            color: ag.hovered ? Colors.withAlpha(Colors.muted, 0.10) : "transparent"
                            Accessible.name: Burn.agentName(ag.modelData.agent) + " : " + ag.costText + ", "
                                             + Burn.tokens(ag.modelData.tokens) + " tokens"
                            onClicked: Burn.dashboardPage = ag.modelData.agent
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
                                    Txt { anchors.right: parent.right; text: ag.costText; font.bold: true }
                                }
                                Meter {
                                    width: parent.width
                                    implicitHeight: 4
                                    value: ag.modelData.cost / root.agentRows[0].cost
                                    fill: Burn.agentColor(ag.modelData.agent)
                                }
                                Txt { text: Burn.tokens(ag.modelData.tokens) + " tokens"; color: Colors.muted; font.pixelSize: 10 }
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
                        Txt { text: "Modèles"; font.pixelSize: 14; font.bold: true }
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
                        Txt { x: 10; anchors.verticalCenter: parent.verticalCenter; text: "\uf002"; color: Colors.muted; Accessible.ignored: true }  // search
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
                            activeFocusOnTab: true
                            Accessible.name: "Filtrer les modèles"
                            // Échap vide le filtre ; déjà vide, il remonte à l'hôte (fermeture du dashboard).
                            Keys.onEscapePressed: event => {
                                event.accepted = search.text !== "";
                                search.text = "";
                            }
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
                            delegate: BurnButton {
                                id: colHead
                                required property var modelData
                                required property int index
                                readonly property bool sorted: root.sortKey === modelData[0]
                                width: root.colW(index, parent.width)
                                height: parent.height
                                radius: 6
                                Accessible.name: "Trier par " + colHead.modelData[1].toLowerCase()
                                                 + (colHead.sorted ? (root.sortAsc ? ", tri croissant" : ", tri décroissant") : "")
                                onClicked: {
                                    if (colHead.sorted) root.sortAsc = !root.sortAsc;
                                    else { root.sortKey = colHead.modelData[0]; root.sortAsc = colHead.modelData[0] === "model"; }
                                }
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
                                        Accessible.ignored: true
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
                                Txt {
                                    width: root.colW(2, mrow.width)
                                    leftPadding: 10
                                    text: Burn.money(Burn.priced(mrow.modelData.totalCost, mrow.modelData.totalTokens))
                                }
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
                    text: root.models === null ? (Burn.loading ? "Chargement des modèles…" : "Données indisponibles.")
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
            // En toutes lettres : en direct, en cache (relu du disque, dernier appel en échec ou trop ancien),
            // indisponible ; le point n'en est qu'un rappel.
            Rectangle {
                width: 6
                height: 6
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: Burn.dataState === "live" ? Colors.good : Burn.dataState === "cached" ? Colors.warn
                     : Burn.loading ? Colors.muted : Colors.danger
            }
            Txt {
                text: Burn.dataState !== "unavailable" ? Burn.stateText(Burn.dataState) + " · mis à jour " + Burn.ago(Burn.updatedAt)
                    : Burn.loading ? "Lecture de l'usage…" : Burn.stateText(Burn.dataState)
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        // 28 px (cible de l'ancienne icône de 16 px + 6 px autour), glyphe au même endroit.
        BurnButton {
            id: footRefresh
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28
            radius: 8
            tip: "Rafraîchir"
            onClicked: Burn.refresh(true)
            Txt {
                anchors.centerIn: parent
                width: 16
                height: 16
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "\uf021"  // refresh
                color: footRefresh.hovered ? Colors.foreground : Colors.muted
                Accessible.ignored: true
                RotationAnimation on rotation {
                    running: Burn.loading
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                    alwaysRunToEnd: true   // finit le tour : l'icône s'arrête droite
                }
            }
        }
    }
}
