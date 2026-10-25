pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

// Pace of a quota window (QuotaChart in the Mac app): % left, from 100% at the start of the
// window to 0% at the reset, with readings, the forecast up to the reset and the steady pace dashed.
// Pure component: the parent supplies the window, readings and projection (Burn.windows / quotaSamples / pace).
Item {
    id: root
    property real startMs
    property real endMs              // reset
    property var samples: []         // [{ t, used }]
    property real used: -1           // current % used ("Now" point), -1 = unknown
    property real projected: -1      // projected % used at the reset, -1 = unknown
    property color accent: Colors.good
    property bool compact: false

    implicitWidth: 320
    implicitHeight: compact ? 176 : 214

    readonly property bool valid: startMs > 0 && endMs > startMs   // unknown start (0): no axis in 1970
    readonly property bool hasNow: valid && used >= 0
    readonly property int fs: compact ? 10 : 11

    // Screen readers (Burn.accessibleText, desktop app): the chart in one sentence. Set in JS like the Txt
    // of the views: the Quickshell bar gets no extra Accessible object.
    readonly property bool exposed: Burn.accessibleText === true
    onExposedChanged: if (exposed) {
        Accessible.role = Accessible.Chart;
        Accessible.name = Qt.binding(() => root.summary());
    }
    // Left now and forecast at the reset; without a window, the message shown in its place.
    function summary() {
        if (!valid) return empty.text;
        const reset = new Date(endMs).toLocaleString(Qt.locale("en_US"), "ddd MMM d HH:mm");
        return "Quota until the reset (" + reset + "): "
            + (hasNow ? Math.max(0, Math.round(100 - used)) + "% left" : "reading unknown")
            + (projected < 0 ? "" : projected > 100 ? ", runs out before the reset at the current pace"
               : ", " + Math.round(100 - projected) + "% left at the reset at the current pace");
    }

    // Paths in `plot` pixels: y starts at the top and equals the % used (100% left at the top).
    // Date.now() is read again on each new data point: "Now" follows the latest measurement.
    readonly property var geo: {
        const w = plot.width, h = plot.height, span = Math.max(1, endMs - startMs);
        const pt = (t, u) => Qt.point((Math.min(endMs, Math.max(startMs, t)) - startMs) / span * w,
                                      Math.min(100, Math.max(0, u)) / 100 * h);
        const now = Date.now(), u = Math.min(100, used), dot = pt(now, u);
        const rec = valid ? (samples || []).map(s => pt(s.t, s.used)) : [];
        if (hasNow) rec.push(dot);
        // Above 100% projected, the forecast stops where the quota drops to 0% left.
        const end = projected > 100 ? now + (endMs - now) * (100 - u) / (projected - u) : endMs;
        return { rec: rec, dot: dot, fc: hasNow && projected >= 0 ? [dot, pt(end, projected)] : [] };
    }

    // Noon of each day ("Mon") if the window spans ≥ 2 d, otherwise full hours ("14:00"),
    // one step every `stride` to keep ≥ 44 px between two labels.
    readonly property var xTicks: {
        if (!valid) return [];
        const byDay = endMs - startMs >= 2 * 864e5, unit = byDay ? 864e5 : 36e5;
        const stride = Math.ceil((endMs - startMs) / unit / Math.max(2, Math.floor(plot.width / 44)));
        const d = new Date(startMs);
        if (byDay) d.setHours(12, 0, 0, 0); else d.setMinutes(0, 0, 0);
        const ticks = [], en = Qt.locale("en_US");
        for (let t = d < startMs ? +d + unit : +d; t <= endMs; t += stride * unit)
            ticks.push({ t: t, text: new Date(t).toLocaleString(en, byDay ? "ddd" : "HH:mm") });
        return ticks;
    }

    FontMetrics { id: fm; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: root.fs }

    Text {
        id: empty
        anchors.centerIn: parent
        visible: !root.valid
        text: "No quota window yet"
        color: Colors.muted
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: root.fs + 1
    }

    Item {
        anchors.fill: parent
        visible: root.valid

        Row {
            spacing: 12
            Repeater {
                model: [
                    { label: "Reading", tint: root.accent, dashed: false, on: root.geo.rec.length > 0 },
                    { label: "Forecast", tint: root.accent, dashed: true, on: root.geo.fc.length > 0 },
                    { label: "Steady pace", tint: Colors.muted, dashed: true, on: true }
                ]
                Row {
                    id: key
                    required property var modelData
                    visible: modelData.on
                    spacing: 5
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Repeater {
                            model: key.modelData.dashed ? 3 : 1
                            Rectangle {
                                width: key.modelData.dashed ? 3 : 12
                                height: 2
                                radius: 1
                                color: key.modelData.tint
                            }
                        }
                    }
                    Text {
                        text: key.modelData.label
                        color: Colors.muted
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: root.fs
                    }
                }
            }
        }

        Repeater {
            model: [100, 75, 50, 25, 0]
            Item {
                id: gridRow
                required property int modelData
                readonly property real yy: plot.y + (100 - modelData) / 100 * plot.height
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
                    text: gridRow.modelData + "%"
                    color: Colors.muted
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: root.fs
                }
            }
        }

        Repeater {
            model: root.xTicks
            Text {
                required property var modelData
                x: Math.max(plot.x, Math.min(root.width - implicitWidth,
                    plot.x + (modelData.t - root.startMs) / (root.endMs - root.startMs) * plot.width - implicitWidth / 2))
                y: plot.y + plot.height + 6
                text: modelData.text
                color: Colors.muted
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: root.fs
            }
        }

        // Vertical "now" marker, under the paths.
        Rectangle {
            visible: root.hasNow
            x: plot.x + root.geo.dot.x
            y: plot.y
            width: 1
            height: plot.height
            color: Colors.withAlpha(root.accent, 0.3)
        }

        Shape {
            id: plot
            x: fm.advanceWidth("100%") + 8
            y: fm.height + 12
            width: parent.width - x - 6
            height: parent.height - y - fm.height - 6
            preferredRendererType: Shape.CurveRenderer   // antialiasing without multisampling

            ShapePath {   // steady pace: quota spread evenly up to the reset
                strokeColor: Colors.muted
                strokeWidth: 1.5
                strokeStyle: ShapePath.DashLine
                dashPattern: [2.5, 2.5]
                fillColor: "transparent"
                PathPolyline { path: [Qt.point(0, 0), Qt.point(plot.width, plot.height)] }
            }
            ShapePath {   // reading
                strokeColor: root.accent
                strokeWidth: 2
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                fillColor: "transparent"
                PathPolyline { path: root.geo.rec }
            }
            ShapePath {   // forecast
                strokeColor: root.accent
                strokeWidth: 2
                strokeStyle: ShapePath.DashLine
                dashPattern: [3, 2.5]
                fillColor: "transparent"
                PathPolyline { path: root.geo.fc }
            }
        }

        // "Now" point: a background-colored ring keeps it readable over the paths.
        Rectangle {
            id: dot
            visible: root.hasNow
            x: plot.x + root.geo.dot.x - 6
            y: plot.y + root.geo.dot.y - 6
            width: 12
            height: 12
            radius: 6
            color: root.accent
            border.width: 2
            border.color: Colors.surface
        }
        // Label above the point, below it if it would leave the frame.
        Rectangle {
            visible: root.hasNow
            width: nowText.implicitWidth + 12
            height: nowText.implicitHeight + 4
            radius: height / 2
            x: Math.max(plot.x, Math.min(root.width - width, dot.x + 6 - width / 2))
            y: dot.y - height - 4 >= plot.y ? dot.y - height - 4 : dot.y + 16
            color: Colors.withAlpha(Colors.background, 0.9)   // surface: 2.3:1 under the text with wallust
            Text {
                id: nowText
                anchors.centerIn: parent
                text: "Now"
                color: Colors.foreground
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: root.fs
                font.bold: true
            }
        }
    }
}
