pragma ComponentBehavior: Bound
import Quickshell.Widgets
import QtQuick

// Content of the Agent Burn popover (the menu bar popover of the Mac app): General tab +
// one tab per agent, "updated" footer, access to the dashboard. No window: BurnPill hosts it
// in its PopupWindow, a test harness can show it alone.
Item {
    id: root

    // One tab per agent with a quota, like the Mac app: the others have nothing to show there and stay
    // in General. Burn.agents is sorted by cost.
    readonly property var quotaAgents: Burn.agents.filter(a => Burn.subEntry(a) || (a === "claude" && Burn.account))
    // "general" or an agent; by default the most expensive one.
    property string tab: quotaAgents.length > 0 ? quotaAgents[0] : "general"
    // The host closes the popover (after "Open dashboard").
    signal closeRequested()

    implicitWidth: 440
    implicitHeight: col.implicitHeight + 32

    onVisibleChanged: if (root.visible) Burn.poke()
    onTabChanged: fade.restart()
    Timer { interval: 60000; repeat: true; running: root.visible; onTriggered: Burn.poke() }

    function sum(series, key) { return series.reduce((s, d) => s + (d[key] ?? 0), 0); }
    // Spend of the last `days` days of a Burn.dailySeries series, today included: null ("—")
    // for an agent without any known day, or for tokens without a price.
    function spent(series, days) {
        const t = new Date(), from = Burn.iso(new Date(t.getFullYear(), t.getMonth(), t.getDate() - days + 1));
        const s = series.filter(d => d.date >= from);
        return series.length ? Burn.priced(sum(s, "cost"), sum(s, "tokens")) : null;
    }
    // Tint of a Burn.providerState state: the word stays written next to it.
    function stateTone(s) { return Burn.tone({ live: "good", stale: "warn", expired: "danger", unavailable: "danger" }[s] ?? ""); }

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
    // Key figure: title, large value, detail.
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
    // Rounded brand icon; cut-out logos sit on a tinted tile.
    component AgentIcon: ClippingRectangle {
        id: tile
        property string agent
        readonly property color brand: Burn.agentColor(agent)   // "#rrggbb" string → color (withAlpha reads .r/.g/.b)
        color: Colors.withAlpha(brand, 0.25)
        Image { anchors.fill: parent; source: Burn.agentIcon(tile.agent); mipmap: true }
    }
    // Alert banner on a tinted background, text in the normal color; hidden without text.
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

        // Header: flame + title, forced refresh on the right.
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
                reach: 6   // 40 px target
                tip: "Refresh"
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

        // Segmented tabs: the active highlight slides from one tab to the next. Left / right arrows:
        // neighboring tab, selected and focused.
        Rectangle {
            id: tabs
            readonly property var ids: ["general"].concat(root.quotaAgents)
            readonly property real tabW: (width - 6) / ids.length
            width: parent.width
            height: 34
            radius: 10
            color: Colors.withAlpha(Colors.muted, 0.12)
            Accessible.role: Accessible.PageTabList
            Accessible.name: "Tabs"

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
                        ring: tabItem.active ? Colors.background : Colors.accent   // on the accent highlight
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
                            text: tabItem.modelData === "general" ? "General" : Burn.agentName(tabItem.modelData)
                            color: tabItem.active ? Colors.background : tabItem.hovered ? Colors.foreground : Colors.muted
                            font.bold: tabItem.active
                            spoken: false
                        }
                    }
                }
            }
        }

        // Offline or with LiteLLM unreachable, the CLI counts $0: amounts are "—" or partial.
        Banner {
            width: parent.width
            tint: Colors.warn
            text: Burn.pricingMissing ? "Pricing unavailable: amounts incomplete (network down or pricing not downloaded)" : ""
        }

        // Content created only when open: hidden, it no longer follows Burn's clock.
        Loader {
            id: body
            width: parent.width
            active: root.visible
            sourceComponent: root.tab === "general" ? generalView : agentView
            NumberAnimation { id: fade; target: body; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle { width: parent.width; height: 1; color: Colors.withAlpha(Colors.muted, 0.25) }

        // Freshness spelled out: live, cached (read back from disk, last call failed or
        // too old) or unavailable.
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
                text: Burn.dataState !== "unavailable" ? Burn.stateText(Burn.dataState) + " · updated " + Burn.ago(Burn.updatedAt)
                    : Burn.loading ? "Updating…" : Burn.stateText(Burn.dataState)
                color: Colors.muted
                font.pixelSize: 11
            }
        }
        Txt {
            width: parent.width
            visible: text !== ""
            // Missing CLI: the host's fix (install.sh, reinstalling the app) rather than the path.
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
            Accessible.name: "Open dashboard"
            onClicked: {
                Burn.openDashboard(root.tab === "general" ? "all" : root.tab);
                root.closeRequested();
            }
            Txt {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "Open dashboard"
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

    // Agent tab: plan, spend, limits (the most telling one shown large) and pace.
    Component {
        id: agentView
        Column {
            id: av
            readonly property string agent: root.tab
            readonly property var sub: Burn.subEntry(agent)
            readonly property var wins: Burn.windows(agent)
            // Featured window: the weekly one, otherwise the tightest.
            readonly property var main: wins.find(w => w.key === "weekly")
                ?? wins.reduce((a, w) => !a || w.remaining < a.remaining ? w : a, null)
            readonly property var pace: main ? Burn.pace(agent, main.key) : null
            readonly property color tint: Burn.tone(pace?.status ?? "")
            readonly property var provider: Burn.providerState(agent)
            readonly property var series: Burn.dailySeries(agent)
            spacing: 16

            // Identity: icon, name, plan + source of the limits.
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
                // Color on the dot only: colored text reads poorly on the popover's light background.
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

            // Limits refused: sign-in expired, or network down with an expired token (waking from sleep).
            // Without saved limits, "Quota unavailable" below already says so.
            Banner {
                width: parent.width
                text: av.provider.state === "expired" && av.main ? av.provider.detail + " Showing the last saved values." : ""
            }
            // Failure of this agent's last harness (dashboard page): shown here only.
            Banner {
                width: parent.width
                text: av.provider.error
            }

            Row {
                width: parent.width
                Stat {
                    id: spend
                    width: parent.width * 0.58
                    title: "Spend"
                    value: Burn.money(root.spent(av.series, 30))
                    detail: "Last 30 days · API equivalent"
                }
                Stat {
                    visible: typeof av.sub?.pricePerMonth === "number"
                    width: parent.width - spend.width
                    title: "Monthly plan"
                    value: Burn.money(av.sub?.pricePerMonth)
                    detail: av.sub?.plan ?? ""
                }
            }

            // No known limit (agent without a subscription, or 1st load).
            Column {
                visible: !av.main
                width: parent.width
                spacing: 6
                Txt {
                    text: Burn.loading ? "Reading usage…" : "Quota unavailable"
                    font.pixelSize: 20
                    font.bold: true
                }
                // Why: not signed in or offline (Claude), reading missing or expired (Codex logs older than 7 d).
                Txt {
                    width: parent.width
                    text: Burn.loading ? "Loading subscription limits." : av.provider.detail
                    color: Colors.muted
                    wrapMode: Text.WordWrap
                }
            }

            // What is left of the featured window: big number, window and reset on the right.
            Item {
                visible: !!av.main
                width: parent.width
                height: big.implicitHeight
                Txt {
                    id: big
                    text: av.main ? Math.round(av.main.remaining) + "%" : ""
                    font.pixelSize: 44
                    font.bold: true
                }
                Txt {
                    anchors.left: big.right
                    anchors.leftMargin: 8
                    anchors.baseline: big.baseline
                    text: "left"
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
                        text: "resets " + Burn.until(av.main?.resetsAtMs ?? 0)
                        color: Colors.muted
                        font.pixelSize: 11
                    }
                }
            }

            // Other windows (5-hour session, per-model limits).
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
                            text: Burn.pct(win.modelData.remaining) + " left"
                                + (win.modelData.resetsAtMs > 0 ? " · resets " + Burn.until(win.modelData.resetsAtMs) : "")
                        }
                    }
                }
            }

            // Pace: does the featured window last until the reset?
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
                text: "Your quota history builds up with each refresh."
                color: Colors.muted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }
    }

    // General tab: spend and tokens across all agents, list of agents, last 14 days. Everything comes
    // from the archive, like the dashboard: offline, the CLI sets costs to 0, and Claude Code purges
    // its logs older than 30 days.
    Component {
        id: generalView
        Column {
            id: gv
            readonly property var all: Burn.dailySeries("")
            spacing: 16

            // No data and no error; an error (missing CLI…) shows on its own under the footer.
            Txt {
                visible: gv.all.length === 0 && (Burn.loading || Burn.error === "")
                width: parent.width
                text: Burn.loading ? "Reading your local logs…"
                    : "No usage data: start an agent session, then refresh."
                color: Colors.muted
                wrapMode: Text.WordWrap
            }

            Stat {
                visible: gv.all.length > 0
                width: parent.width
                title: "Total spend"
                value: Burn.money(Burn.priced(root.sum(gv.all, "cost"), root.sum(gv.all, "tokens")))
                detail: "All agents · API equivalent"
                size: 36
            }
            Row {
                visible: gv.all.length > 0
                width: parent.width
                Stat {
                    width: parent.width / 2
                    title: "Tokens"
                    value: Burn.tokens(root.sum(gv.all, "tokens"))
                    detail: "Input, output and cache"
                    size: 22
                }
                Stat {
                    width: parent.width / 2
                    title: "Today"
                    value: Burn.money(root.spent(gv.all, 1))
                    detail: "Today's spend"
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
                        // Agent with a quota: the row opens its tab (Mac app: "Busiest agents").
                        enabled: root.quotaAgents.includes(agentRow.modelData)
                        Accessible.role: agentRow.enabled ? Accessible.Button : Accessible.ListItem
                        Accessible.name: Burn.agentName(agentRow.modelData) + ": " + agentRow.tokensText + ", " + agentRow.costText
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
                    text: "Last 14 days"
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
                unit: ""   // 14-day total already in the header
            }
        }
    }
}
