pragma ComponentBehavior: Bound
import QtQuick

// Daily histogram ("Daily spend" in the Mac app): one bar per day, missing day = gap,
// hovering a column = date + value tooltip. Pure component: the parent supplies the points.
Item {
    id: root
    property var points: []          // [{ date: "YYYY-MM-DD", value }] sorted; value null = unknown amount
    property color barColor: Colors.accent
    property string unit: "USD"
    property bool compact: false

    implicitWidth: 360
    implicitHeight: compact ? 150 : 190

    readonly property int fs: compact ? 10 : 11
    readonly property var en: Qt.locale("en_US")

    // Screen readers (Burn.accessibleText, desktop app): the chart in one sentence. Set in JS like the Txt
    // of the views: the Quickshell bar gets no extra Accessible object.
    readonly property bool exposed: Burn.accessibleText === true
    onExposedChanged: if (exposed) {
        Accessible.role = Accessible.Chart;
        Accessible.name = Qt.binding(() => root.summary());
    }
    // Period, total and most expensive day; without a chart, the message shown in its place.
    function summary() {
        if (!chart.ok) return empty.text;
        const known = points.filter(p => p.value !== null), d = s => day(s).toLocaleString(en, "MMM d");
        const peak = known.reduce((a, p) => p.value > a.value ? p : a);
        if (points.length === 1) return day(peak.date).toLocaleString(en, "ddd MMM d") + ": " + fmt(peak.value);
        return "From " + d(points[0].date) + " to " + d(points[points.length - 1].date) + ": "
            + fmt(known.reduce((s, p) => s + p.value, 0)) + " in total, peak of " + fmt(peak.value)
            + " on " + day(peak.date).toLocaleString(en, "ddd MMM d");
    }

    function day(s) { const p = s.split("-"); return new Date(p[0], p[1] - 1, p[2]); }
    // Points of the last n days (Burn.lastDays) of a Burn.dailySeries series; a day with tokens but no price: null.
    function lastDays(series, n) {
        const tokens = {};
        for (const d of series) tokens[d.date] = d.tokens;
        return Burn.lastDays(series, n).map(p => ({ date: p.date, value: Burn.priced(p.value, tokens[p.date] ?? 0) }));
    }
    function fmt(v) { return Burn.money(v); }
    // Compact ticks without trailing decimal zeros: "$1,000.00" → "$1,000", "$2.50" → "$2.5".
    function tick(v) { return fmt(v).replace(/(\.\d*?)0+(?=\D*$)/, "$1").replace(/\.(?=\D*$)/, ""); }

    // Day index of each point and round Y ticks.
    readonly property var chart: {
        const pts = points || [];
        const max = Math.max(0, ...pts.map(p => p.value));
        if (!(max > 0)) return { ok: false, idx: [], days: 1, ticks: [], top: 1 };
        const t0 = day(pts[0].date);
        // round: a daylight saving time change day lasts 23 or 25 h.
        const idx = pts.map(p => Math.round((day(p.date) - t0) / 864e5));
        // Step of 1, 2, 2.5 or 5 × 10^k: 4 or 5 ticks, 0 included.
        const raw = max / 4, mag = Math.pow(10, Math.floor(Math.log10(raw))), n = raw / mag;
        const step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * mag;
        const ticks = [];
        for (let i = 0; i <= Math.ceil(max / step - 1e-9); i++) ticks.push(i * step);
        return { ok: true, t0: t0, idx: idx, days: idx[idx.length - 1] + 1, ticks: ticks, top: ticks[ticks.length - 1] };
    }

    // Days over 2 weeks at most; beyond that, the first days of months if there are at least 3, otherwise
    // spaced days. One label every `stride` to keep ≥ 80 px between two: even when shifted at the edge,
    // a date does not overlap its neighbor.
    readonly property var xLabels: {
        const c = chart, all = [];
        if (!c.ok) return [];
        for (let i = 0; i < c.days; i++)
            all.push({ i: i, d: new Date(c.t0.getFullYear(), c.t0.getMonth(), c.t0.getDate() + i) });
        const firsts = all.filter(l => l.d.getDate() === 1);
        const pick = c.days > 14 && firsts.length >= 3 ? firsts : all;
        const stride = Math.ceil(pick.length / Math.max(1, Math.floor(plot.width / 80)));
        return pick.filter((l, k) => k % stride === 0);
    }

    FontMetrics { id: fm; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: root.fs }

    Text {
        id: empty
        anchors.centerIn: parent
        visible: !root.chart.ok
        // Tokens without any price (offline): days of usage, not an empty chart.
        text: (root.points || []).some(p => p.value === null) ? "Unknown amounts: pricing unavailable" : "No data"
        color: Colors.muted
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: root.fs + 1
    }

    Item {
        anchors.fill: parent
        visible: root.chart.ok

        Text {
            anchors.right: parent.right
            text: root.unit
            color: Colors.muted
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: root.fs
        }

        // Bar frame; the left gutter follows the longest tick.
        Item {
            id: plot
            readonly property real slot: width / root.chart.days
            x: Math.max(0, ...root.chart.ticks.map(v => fm.advanceWidth(root.tick(v)))) + 8
            y: fm.height + 8
            width: parent.width - x
            height: parent.height - y - fm.height - 6
        }

        Repeater {
            model: root.chart.ticks
            Item {
                id: gridRow
                required property real modelData
                readonly property real yy: plot.y + plot.height * (1 - modelData / root.chart.top)
                Rectangle {
                    x: plot.x
                    y: gridRow.yy
                    width: plot.width
                    height: 1
                    color: Colors.withAlpha(Colors.muted, 0.15)
                }
                Text {
                    width: plot.x - 8
                    y: gridRow.yy - height / 2
                    horizontalAlignment: Text.AlignRight
                    text: root.tick(gridRow.modelData)
                    color: Colors.muted
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: root.fs
                }
            }
        }

        Repeater {
            model: root.chart.ok ? root.points : []
            Rectangle {
                required property var modelData
                required property int index
                readonly property real h: plot.height * Math.max(0, modelData.value) / root.chart.top
                // 24 px at most and 2 px of space between neighbors; 1 px minimum on long ranges.
                width: Math.max(1, Math.round(Math.min(24, plot.slot - 2)))
                height: h
                x: Math.round(plot.x + (root.chart.idx[index] + 0.5) * plot.slot - width / 2)
                y: plot.y + plot.height - h
                topLeftRadius: Math.min(4, width / 2, h)
                topRightRadius: topLeftRadius
                color: root.barColor
                opacity: hover.idx < 0 || hover.idx === index ? 1 : 0.35
            }
        }

        Repeater {
            model: root.xLabels
            Text {
                required property var modelData
                x: Math.max(plot.x, Math.min(root.width - implicitWidth,
                    plot.x + (modelData.i + 0.5) * plot.slot - implicitWidth / 2))
                y: plot.y + plot.height + 6
                text: modelData.d.toLocaleString(root.en, "MMM d")
                color: Colors.muted
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: root.fs
            }
        }

        MouseArea {
            id: hover
            // The whole day column is the target: bars are sometimes 1 px wide.
            readonly property int idx: containsMouse ? root.chart.idx.indexOf(Math.floor(mouseX / plot.slot)) : -1
            x: plot.x
            y: plot.y
            width: plot.width
            height: plot.height
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
        }

        Rectangle {
            id: tip
            readonly property var p: root.points[hover.idx]   // undefined when not hovered
            visible: p !== undefined
            width: tipCol.implicitWidth + 16
            height: tipCol.implicitHeight + 10
            x: p ? Math.max(0, Math.min(root.width - width,
                plot.x + (root.chart.idx[hover.idx] + 0.5) * plot.slot - width / 2)) : 0
            y: p ? Math.max(0, plot.y + plot.height * (1 - p.value / root.chart.top) - height - 6) : 0
            radius: 8
            color: Colors.withAlpha(Colors.background, 0.97)   // surface: 2.3:1 under the text with wallust
            border.color: Colors.withAlpha(Colors.accent, 0.4)
            border.width: 1

            Column {
                id: tipCol
                anchors.centerIn: parent
                spacing: 1
                Text {
                    text: tip.p ? root.fmt(tip.p.value) : ""
                    color: Colors.foreground
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: root.fs + 1
                    font.bold: true
                }
                Text {
                    text: tip.p ? root.day(tip.p.date).toLocaleString(root.en, "ddd MMM d yyyy") : ""
                    color: Colors.muted
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: root.fs
                }
            }
        }
    }
}
