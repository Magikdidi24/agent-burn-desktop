pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Widgets
import QtQuick

// Content of the Agent Burn dashboard (the Mac app window), without a window: BurnDashboard
// hosts it, a test harness can show it alone. Sidebar (all agents / one agent),
// scrolling page, fixed "updated" footer.
// Spend, tokens and days come from the archive (Burn.dailySeries): it keeps the days
// the agents purged from their logs.
Item {
    id: root

    // "all" or an agent; held by Burn so the popover opens the dashboard on its tab.
    property string page: Burn.dashboardPage
    readonly property string agent: page === "all" ? "" : page
    readonly property color tint: agent ? Burn.agentColor(agent) : Colors.accent
    // Host settings (desktop app): button at the bottom of the sidebar. The Quickshell bar has none.
    property bool settingsAvailable: false
    signal settingsRequested()

    readonly property var pages: ["all"].concat(Burn.agents)
    readonly property var provider: agent ? Burn.providerState(agent) : null
    // "Providers" card: Claude and Codex always, even when missing, then the other agents seen.
    readonly property var providerIds: Burn.knownProviders.concat(Burn.agents.filter(a => !Burn.knownProviders.includes(a)))
    // Banners, from most to least severe: CLI error; on an agent's page, its error (harness) and
    // its state if it is not live; missing pricing. 1st load: "Reading usage…".
    readonly property var notices: {
        const n = [], p = provider;
        if (Burn.error) n.push({ msg: Burn.error, tint: Colors.danger });
        if (p?.error) n.push({ msg: p.error, tint: Colors.danger });
        if (!Burn.summary && Burn.loading) n.push({ msg: "Reading usage…", tint: Colors.muted, plain: true });
        else if (p && p.state !== "live")
            n.push({ msg: p.detail + (p.state === "expired" && limits.length ? " Showing the last saved values." : ""),
                     tint: stateTone(p.state) });
        if (Burn.pricingMissing)
            n.push({ msg: "Pricing unavailable: amounts incomplete (network down or pricing not downloaded)", tint: Colors.warn });
        return n;
    }

    readonly property var ranges: [
        { key: "all", label: "All", long: "All history" },
        { key: "30d", label: "30 days", long: "Last 30 days" },
        { key: "7d", label: "7 days", long: "Last 7 days" },
        { key: "today", label: "Today", long: "Today" }
    ]
    readonly property string rangeLong: ranges.find(r => r.key === Burn.range)?.long ?? ""

    // Days of the range, today included (same bound as the --since of Burn.loadRange).
    function inRange(series) {
        const n = Burn.spans[Burn.range];   // days before today; missing for "All"
        if (n === undefined) return series;
        const d = new Date();
        d.setDate(d.getDate() - n);
        const from = Qt.formatDate(d, "yyyy-MM-dd");
        return series.filter(p => p.date >= from);
    }
    function total(series, key) { return series.reduce((s, p) => s + (p[key] || 0), 0); }
    // Tint of a Burn.providerState state: the word stays written next to it.
    function stateTone(s) { return Burn.tone({ live: "good", stale: "warn", expired: "danger", unavailable: "danger" }[s] ?? ""); }
    // Arrows of the sidebar and the range picker: neighbor selected and focused.
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
    readonly property bool noData: !Burn.summary && days.length === 0   // neither report nor archive: "—", not 0
    // Models of the range; null during the 1st load of rangeSummary.
    readonly property var models: {
        const s = Burn.rangeSummary;
        if (!s) return null;
        if (!agent) return s.models ?? [];
        return (s.agents ?? []).find(e => e.agent === agent)?.models ?? [];
    }
    // No arrow function with a `{}` body here: qmllint then gives up analyzing the whole file.
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
    readonly property var harness: agent ? (Burn.harnesses[agent] ?? null) : null

    property string sortKey: "totalCost"
    property bool sortAsc: false
    readonly property var modelRows: {
        const q = search.text.toLowerCase(), k = sortKey, dir = sortAsc ? 1 : -1;
        return (models ?? []).filter(m => m.model.toLowerCase().includes(q))
            .sort((a, b) => dir * (k === "model" ? a.model.localeCompare(b.model) : a[k] - b[k]));
    }
    // Columns Model | Tokens | Spend | Share: the first one takes the rest.
    function colW(i, w) { return [w - 400, 120, 130, 150][i]; }

    onPageChanged: flick.contentY = 0

    // Keyboard: the focused control (Tab) stays visible, each Flickable that contains it (page, "By agent"
    // list) scrolls to it.
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
    // PageUp / PageDown / Home / End scroll the page (keys the focused control did not take).
    Keys.onPressed: event => {
        const bottom = Math.max(0, flick.contentHeight - flick.height), step = flick.height - 40;
        const to = event.key === Qt.Key_PageDown ? flick.contentY + step : event.key === Qt.Key_PageUp ? flick.contentY - step
                 : event.key === Qt.Key_Home ? 0 : event.key === Qt.Key_End ? bottom : NaN;
        if (isNaN(to)) return;
        flick.contentY = Math.max(0, Math.min(bottom, to));
        event.accepted = true;
    }

    component Txt: Text {
        id: txt
        property bool spoken: true   // false: already said elsewhere (a button's label, explicit Accessible.name)
        color: Colors.foreground
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 12
        textFormat: Text.PlainText
        // Screen readers: a Text is exposed only with a role and a name. Set in JS and only with
        // Burn.accessibleText (desktop app): the Quickshell bar keeps its Text items without an Accessible object.
        readonly property bool exposed: spoken && Burn.accessibleText === true
        onExposedChanged: if (exposed && !Accessible.ignored) {
            Accessible.role = Accessible.StaticText;
            Accessible.name = Qt.binding(() => txt.text);
        }
    }
    // Card: translucent background, content stacked with an 18 px margin.
    component Card: Rectangle {
        id: card
        default property alias content: cardBody.data
        implicitHeight: cardBody.implicitHeight + 36
        radius: 14
        color: Colors.withAlpha(Colors.surface, 0.55)
        Column { id: cardBody; x: 18; y: 18; width: card.width - 36; spacing: 12 }
    }
    // Card title, discreet detail on the right; narrow card (window at its minimum size): the
    // detail gives way to the title.
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
    // Thin bar, value in 0..1 (NaN from a division by zero = empty).
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
    // Gauge: label on the left, figures on the right, bar below.
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
    // State of a provider (Burn.providerState): the word; the tinted dot only echoes it.
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

    // A limit window up to its reset: % left, pace verdict, readings and forecast. Hidden while its start is
    // unknown (Codex session: no reset time, nothing to draw) and once it is over (reading older than the window).
    component LimitCard: Card {
        id: lim
        property string agent
        property string key
        property string caption
        readonly property var w: Burn.windows(agent).find(x => x.key === key) ?? null
        readonly property var pace: w ? Burn.pace(agent, key) : null
        visible: !!w && w.startMs > 0 && (w.resetsAtMs || w.startMs + w.durationMin * 60000) > Burn.now
        Row {
            width: parent.width
            spacing: 24
            Column {
                id: limCol
                width: 260
                spacing: 10
                Txt {
                    text: lim.caption
                    color: Colors.muted
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 0.6
                }
                Row {
                    spacing: 8
                    Txt { id: limLeft; text: Burn.pct(lim.w?.remaining); font.pixelSize: 40; font.bold: true }
                    Txt { anchors.baseline: limLeft.baseline; text: "left"; color: Colors.muted; font.pixelSize: 13 }
                }
                Row {
                    spacing: 8
                    Txt {
                        text: lim.pace?.status === "good" ? "\uf058" : "\uf071"  // check-circle / warning
                        color: Burn.tone(lim.pace?.status)
                        font.pixelSize: 14
                        Accessible.ignored: true
                    }
                    Txt {
                        width: limCol.width - 30
                        wrapMode: Text.WordWrap
                        text: lim.pace?.title ?? ""
                        font.pixelSize: 13
                        font.bold: true
                    }
                }
                Txt {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: lim.pace?.detail ?? ""
                    color: Colors.muted
                }
                Txt {
                    id: limReset
                    readonly property string when: "Resets " + Burn.until(lim.w?.resetsAtMs ?? 0)
                    visible: (lim.w?.resetsAtMs ?? 0) > 0
                    text: "\uf017  " + limReset.when  // clock
                    color: Colors.muted
                    Accessible.name: limReset.when
                    spoken: false
                }
            }
            BurnQuotaChart {
                width: parent.width - limCol.width - parent.spacing
                height: 220
                startMs: lim.w?.startMs ?? 0
                // Unknown reset: theoretical end of the window.
                endMs: lim.w ? (lim.w.resetsAtMs || lim.w.startMs + lim.w.durationMin * 60000) : 0
                samples: lim.w ? Burn.quotaSamples(lim.agent, lim.key) : []
                used: lim.w?.used ?? -1
                projected: lim.pace?.projected ?? -1
                accent: Burn.tone(lim.pace?.status)
            }
        }
    }

    // ── Sidebar ──
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

            // App name: under Hyprland the window has no title bar.
            Row {
                leftPadding: 10
                bottomPadding: 14
                spacing: 8
                Txt { text: "\uf06d"; color: Colors.accent; font.pixelSize: 16; Accessible.ignored: true }  // fire
                Txt { text: "Agent Burn"; font.pixelSize: 14; font.bold: true }
            }

            // Pages: vertical tabs, up / down arrows to move from one to the other.
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
                        text: entry.modelData === "all" ? "All agents" : Burn.agentName(entry.modelData)
                        color: entry.sel ? Colors.foreground : Colors.withAlpha(Colors.foreground, 0.75)
                        font.bold: entry.sel
                        spoken: false
                    }
                }
            }
        }

        // Settings: only if the host has them (settingsAvailable); it opens its view on settingsRequested.
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
            Accessible.name: "Settings"
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
                text: "Settings"
                color: Colors.withAlpha(Colors.foreground, 0.75)
                spoken: false
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

            // Header: icon, title, range; range picker on the right.
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
                            // Narrow window: the name is elided, the badge does not spill onto the range picker.
                            Txt {
                                width: Math.min(implicitWidth, titleRow.width - (pageBadge.visible ? pageBadge.width + titleRow.spacing : 0))
                                elide: Text.ElideRight
                                text: root.agent ? Burn.agentName(root.agent) : "All agents"
                                font.pixelSize: 22
                                font.bold: true
                            }
                            // Agent page: where its figures come from, spelled out (details in a banner).
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
                            text: root.rangeLong + " · usage from your logs and connected providers"
                            color: Colors.muted
                        }
                    }
                }
                // Range: radio buttons, left / right arrows.
                Rectangle {
                    id: rangePicker
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: seg.implicitWidth + 6
                    height: 32
                    radius: 10
                    color: Colors.withAlpha(Colors.surface, 0.55)
                    Accessible.role: Accessible.Grouping
                    Accessible.name: "Period"
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
                                    font.bold: opt.sel   // selection is not shown by color alone
                                    spoken: false
                                }
                            }
                        }
                    }
                }
            }

            // Local archive: days kept, access to the folder.
            Item {
                width: parent.width
                height: 30
                Txt {
                    id: archive
                    readonly property string kept: Burn.historyDays + (Burn.historyDays === 1 ? " day kept" : " days kept")
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - backup.width - 12   // narrow window: elided, never under the button
                    elide: Text.ElideRight
                    text: "\uf1c0   Daily history · " + archive.kept + " on this PC"  // database
                    color: Colors.muted
                    Accessible.name: "Daily history: " + archive.kept + " on this PC"
                    spoken: false
                }
                BurnButton {
                    id: backup
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: backupText.implicitWidth + 24
                    height: 28
                    radius: 8
                    color: Colors.withAlpha(Colors.muted, backup.hovered ? 0.25 : 0.15)
                    Accessible.name: "Show backup"
                    onClicked: Quickshell.execDetached(["xdg-open", Burn.dataDir])
                    Txt { id: backupText; anchors.centerIn: parent; text: "\uf07c  Show backup"; Accessible.ignored: true }  // folder-open
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
                    // Tinted icon, text in the normal color: readable on the tint (3.7:1 for red on light red).
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

            // Plan: one gauge per limit window, then the extra credits (Claude).
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
                        Txt { text: "Plan " + (root.sub?.plan ?? ""); font.pixelSize: 14; font.bold: true }
                        // Age of the Claude limits reading: the footer only dates the summary.
                        Txt {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.agent === "claude" && !!Burn.account
                            text: "· last reading " + Burn.ago(Burn.account?.observedAtMs ?? 0)
                            color: Burn.limitsStale ? Colors.warn : Colors.muted
                        }
                    }
                    Txt {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.sub?.pricePerMonth != null
                        text: Burn.money(root.sub?.pricePerMonth) + " / month"
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
                        // Pace also written out: depending on the wallpaper, good and danger look alike.
                        value: Burn.pct(modelData.used) + " used"
                               + (modelData.resetsAtMs > 0 ? " · resets " + Burn.until(modelData.resetsAtMs) : "")
                               + (pace.status === "warn" || pace.status === "danger" ? " · " + pace.title : "")
                        ratio: modelData.used / 100
                        fill: Burn.tone(pace.status)
                    }
                }
                Txt {
                    visible: root.limits.length === 0
                    text: "No limits read for this plan."
                    color: Colors.muted
                }
                Gauge {
                    width: parent.width
                    visible: root.agent === "claude" && Burn.account?.extraEnabled === true
                    label: "Extra credits"
                    value: Burn.pct(Burn.account?.extraUsedPercent) + " used · " + Burn.money(Burn.account?.extraUsedUSD)
                           + " of " + Burn.money(Burn.account?.extraLimitUSD)
                    ratio: (Burn.account?.extraUsedPercent ?? 0) / 100
                    fill: root.tint
                }
            }

            // Weekly limit, then the 5-hour session: what is left, pace and trajectory up to the reset.
            LimitCard { width: parent.width; agent: root.agent; key: "weekly"; caption: "WEEKLY LIMIT" }
            LimitCard { width: parent.width; agent: root.agent; key: "session"; caption: "5-HOUR SESSION" }

            // Subscription over 30 days (`harness <agent>`): value for money and cost per token type.
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
                    Heading { width: parent.width; title: "Plan economics"; detail: "Last 30 days" }
                    Row {
                        width: parent.width
                        spacing: 10
                        Txt { id: mult; text: "×" + (eco.e?.valueMultiple ?? 0).toFixed(2); font.pixelSize: 36; font.bold: true }
                        Txt {
                            anchors.baseline: mult.baseline
                            width: parent.width - mult.width - parent.spacing   // narrow card: elided, not on the neighbor
                            elide: Text.ElideRight
                            text: "usage value / plan price"
                            color: Colors.muted
                        }
                    }
                    Gauge {
                        width: parent.width
                        label: "API equivalent"
                        value: Burn.money(eco.e?.apiEquivalentPerMonth)
                        ratio: (eco.e?.apiEquivalentPerMonth ?? 0) / eco.peak
                        fill: root.tint
                    }
                    Gauge {
                        width: parent.width
                        label: "Plan"
                        value: Burn.money(eco.e?.pricePerMonth)
                        ratio: (eco.e?.pricePerMonth ?? 0) / eco.peak
                        fill: Colors.muted
                    }
                    // Usage below the plan price (Codex barely used): negative gap, and no discount.
                    Txt {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: eco.e?.subsidyPerMonth < 0
                            ? "Usage value " + Burn.money(-eco.e.subsidyPerMonth) + " / month below the plan price"
                            : Burn.money(eco.e?.subsidyPerMonth) + " / month beyond the plan · "
                              + Burn.pct(eco.e?.discountPercent, 1) + " discount on API pricing"
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
                    Heading { width: parent.width; title: "Breakdown by token type"; detail: "Last 30 days" }
                    Repeater {
                        model: mix.parts
                        delegate: Gauge {
                            required property var modelData
                            width: parent.width
                            // CLI keys; raw label for an unknown category.
                            label: ({ input: "Input", output: "Output", cacheCreation: "Cache write",
                                      cacheRead: "Cache read" })[modelData.key] ?? modelData.label
                            value: Burn.pct(modelData.costPercent, 1) + " · " + Burn.tokens(modelData.tokens)
                                   + " · " + Burn.money(Burn.priced(modelData.costUSD, modelData.tokens))
                            ratio: modelData.costPercent / 100
                            fill: root.tint
                        }
                    }
                }
            }

            // Figures for the range.
            Card {
                width: parent.width
                Row {
                    width: parent.width
                    Repeater {
                        model: [
                            { title: "Total spend", detail: "API equivalent", value: root.noData ? "—"
                                : Burn.money(Burn.priced(root.total(root.days, "cost"), root.total(root.days, "tokens"))) },
                            { title: "Tokens", value: root.noData ? "—" : Burn.tokens(root.total(root.days, "tokens")),
                              detail: "Input, output and cache" },
                            { title: "Days recorded", value: root.noData ? "—" : String(root.days.length), detail: root.rangeLong },
                            { title: "Models", value: root.models ? String(root.models.length) : "—",
                              detail: root.agent ? Burn.agentName(root.agent) : "All agents combined" }
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

            // On "All agents": each provider, its state and where its figures come from.
            Card {
                width: parent.width
                visible: !root.agent
                Heading { width: parent.width; title: "Providers"; detail: "Claude and Codex, then detected agents" }
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

            // Daily spend; on "All agents", the per-agent list next to it (like the Mac app).
            Row {
                width: parent.width
                spacing: 14
                Card {
                    width: parent.width - (byAgent.visible ? byAgent.width + parent.spacing : 0)
                    Heading { width: parent.width; title: "Daily spend" }
                    BurnBarChart {
                        id: dailyChart
                        width: parent.width
                        height: 220
                        // Bounded range: all its days ($0 without usage), the axis covers all of it.
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
                        title: "By agent"
                        detail: root.agentRows.length + " active"
                    }
                    ListView {
                        width: parent.width
                        height: 220   // = chart height: the two cards line up
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
                            Accessible.name: Burn.agentName(ag.modelData.agent) + ": " + ag.costText + ", "
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
                                    Txt { text: Burn.agentName(ag.modelData.agent); font.bold: true; spoken: false }
                                    Txt { anchors.right: parent.right; text: ag.costText; font.bold: true; spoken: false }
                                }
                                Meter {
                                    width: parent.width
                                    implicitHeight: 4
                                    value: ag.modelData.cost / root.agentRows[0].cost
                                    fill: Burn.agentColor(ag.modelData.agent)
                                }
                                Txt { text: Burn.tokens(ag.modelData.tokens) + " tokens"; color: Colors.muted; font.pixelSize: 10; spoken: false }
                            }
                        }
                        Txt {
                            anchors.centerIn: parent
                            visible: root.agentRows.length === 0
                            text: "No spend in this period."
                            color: Colors.muted
                        }
                    }
                }
            }

            // Models: filter, sort by clicking the header (default: spend, descending).
            Card {
                width: parent.width
                Item {
                    width: parent.width
                    height: 30
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Txt { text: "Models"; font.pixelSize: 14; font.bold: true }
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
                            Accessible.name: "Filter models"
                            // Escape clears the filter; if already empty, it reaches the host (closing the dashboard).
                            Keys.onEscapePressed: event => {
                                event.accepted = search.text !== "";
                                search.text = "";
                            }
                            Txt {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: search.text === ""
                                text: "Filter models"
                                color: Colors.muted
                                spoken: false
                            }
                        }
                    }
                }
                // A single block: the card spacing would separate the header from the rows.
                Column {
                    width: parent.width
                    Row {
                        width: parent.width
                        height: 26
                        Repeater {
                            model: [["model", "Model"], ["totalTokens", "Tokens"], ["totalCost", "Spend"], ["percentage", "Share"]]
                            delegate: BurnButton {
                                id: colHead
                                required property var modelData
                                required property int index
                                readonly property bool sorted: root.sortKey === modelData[0]
                                width: root.colW(index, parent.width)
                                height: parent.height
                                radius: 6
                                Accessible.name: "Sort by " + colHead.modelData[1].toLowerCase()
                                                 + (colHead.sorted ? (root.sortAsc ? ", ascending" : ", descending") : "")
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
                                        spoken: false
                                    }
                                    Txt {
                                        visible: colHead.sorted
                                        text: "\uf0d7"  // caret-down, flipped when sorted ascending
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
                    text: root.models === null ? (Burn.loading ? "Loading models…" : "Data unavailable.")
                        : search.text !== "" ? "No model matches the filter."
                        : "No models used in this period."
                    color: Colors.muted
                }
            }
        }
    }

    // Scroll indicator (the Flickable draws none).
    Rectangle {
        x: flick.x + flick.width - 7
        y: flick.y + flick.visibleArea.yPosition * flick.height
        width: 4
        height: flick.visibleArea.heightRatio * flick.height
        radius: 2
        visible: flick.visibleArea.heightRatio < 1
        color: Colors.withAlpha(Colors.muted, 0.35)
    }

    // ── Fixed footer: data freshness, forced refresh ──
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
            // Spelled out: live, cached (read back from disk, last call failed or too old),
            // unavailable; the dot only echoes it.
            Rectangle {
                width: 6
                height: 6
                radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: Burn.dataState === "live" ? Colors.good : Burn.dataState === "cached" ? Colors.warn
                     : Burn.loading ? Colors.muted : Colors.danger
            }
            Txt {
                text: Burn.dataState !== "unavailable" ? Burn.stateText(Burn.dataState) + " · updated " + Burn.ago(Burn.updatedAt)
                    : Burn.loading ? "Reading usage…" : Burn.stateText(Burn.dataState)
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        // 28 px target (the former 16 px icon + 6 px around it), glyph in the same place.
        BurnButton {
            id: footRefresh
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28
            radius: 8
            tip: "Refresh"
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
                    alwaysRunToEnd: true   // finishes the turn: the icon stops upright
                }
            }
        }
    }
}
