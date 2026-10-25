pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

// Rythme d'une fenêtre de quota (QuotaChart de l'app Mac) : % restant, de 100 % au début de la
// fenêtre à 0 % au reset, avec relevés, prévision jusqu'au reset et rythme régulier en pointillés.
// Composant pur : le parent fournit fenêtre, relevés et projection (Burn.windows / quotaSamples / pace).
Item {
    id: root
    property real startMs
    property real endMs              // reset
    property var samples: []         // [{ t, used }]
    property real used: -1           // % consommé actuel (point « Maintenant »), -1 = inconnu
    property real projected: -1      // % consommé projeté au reset, -1 = inconnu
    property color accent: Colors.good
    property bool compact: false

    implicitWidth: 320
    implicitHeight: compact ? 176 : 214

    readonly property bool valid: startMs > 0 && endMs > startMs   // début inconnu (0) : pas d'axe en 1970
    readonly property bool hasNow: valid && used >= 0
    readonly property int fs: compact ? 10 : 11

    // Lecteurs d'écran (Burn.accessibleText, app de bureau) : le graphe en une phrase. Posé en JS comme les Txt
    // des vues : la barre Quickshell n'a aucun objet Accessible de plus.
    readonly property bool exposed: Burn.accessibleText === true
    onExposedChanged: if (exposed) {
        Accessible.role = Accessible.Chart;
        Accessible.name = Qt.binding(() => root.summary());
    }
    // Restant maintenant et prévu au reset ; sans fenêtre, le message affiché à sa place.
    function summary() {
        if (!valid) return empty.text;
        const reset = new Date(endMs).toLocaleString(Qt.locale("fr_FR"), "ddd d MMM H'h'");
        return "Quota jusqu'au reset (" + reset + ") : "
            + (hasNow ? Math.max(0, Math.round(100 - used)) + " % restant" : "relevé inconnu")
            + (projected < 0 ? "" : projected > 100 ? ", épuisé avant le reset au rythme actuel"
               : ", " + Math.round(100 - projected) + " % au reset au rythme actuel");
    }

    // Tracés en pixels de `plot` : y part du haut et vaut le % consommé (100 % restant en haut).
    // Date.now() est relu à chaque nouvelle donnée : « Maintenant » suit la dernière mesure.
    readonly property var geo: {
        const w = plot.width, h = plot.height, span = Math.max(1, endMs - startMs);
        const pt = (t, u) => Qt.point((Math.min(endMs, Math.max(startMs, t)) - startMs) / span * w,
                                      Math.min(100, Math.max(0, u)) / 100 * h);
        const now = Date.now(), u = Math.min(100, used), dot = pt(now, u);
        const rec = valid ? (samples || []).map(s => pt(s.t, s.used)) : [];
        if (hasNow) rec.push(dot);
        // Au-delà de 100 % projeté, la prévision s'arrête là où le quota tombe à 0 % restant.
        const end = projected > 100 ? now + (endMs - now) * (100 - u) / (projected - u) : endMs;
        return { rec: rec, dot: dot, fc: hasNow && projected >= 0 ? [dot, pt(end, projected)] : [] };
    }

    // Midi de chaque jour (« lun. ») si la fenêtre fait ≥ 2 j, sinon heures pleines (« 14h »),
    // un pas sur `stride` pour garder ≥ 44 px entre deux étiquettes.
    readonly property var xTicks: {
        if (!valid) return [];
        const byDay = endMs - startMs >= 2 * 864e5, unit = byDay ? 864e5 : 36e5;
        const stride = Math.ceil((endMs - startMs) / unit / Math.max(2, Math.floor(plot.width / 44)));
        const d = new Date(startMs);
        if (byDay) d.setHours(12, 0, 0, 0); else d.setMinutes(0, 0, 0);
        const ticks = [], fr = Qt.locale("fr_FR");
        for (let t = d < startMs ? +d + unit : +d; t <= endMs; t += stride * unit)
            ticks.push({ t: t, text: new Date(t).toLocaleString(fr, byDay ? "ddd" : "H'h'") });
        return ticks;
    }

    FontMetrics { id: fm; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: root.fs }

    Text {
        id: empty
        anchors.centerIn: parent
        visible: !root.valid
        text: "Pas encore de fenêtre de quota"
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
                    { label: "Relevé", tint: root.accent, dashed: false, on: root.geo.rec.length > 0 },
                    { label: "Prévision", tint: root.accent, dashed: true, on: root.geo.fc.length > 0 },
                    { label: "Rythme régulier", tint: Colors.muted, dashed: true, on: true }
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
                    text: gridRow.modelData + " %"
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

        // Repère vertical de « maintenant », sous les tracés.
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
            x: fm.advanceWidth("100 %") + 8
            y: fm.height + 12
            width: parent.width - x - 6
            height: parent.height - y - fm.height - 6
            preferredRendererType: Shape.CurveRenderer   // anticrénelage sans multisampling

            ShapePath {   // rythme régulier : quota réparti uniformément jusqu'au reset
                strokeColor: Colors.muted
                strokeWidth: 1.5
                strokeStyle: ShapePath.DashLine
                dashPattern: [2.5, 2.5]
                fillColor: "transparent"
                PathPolyline { path: [Qt.point(0, 0), Qt.point(plot.width, plot.height)] }
            }
            ShapePath {   // relevé
                strokeColor: root.accent
                strokeWidth: 2
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                fillColor: "transparent"
                PathPolyline { path: root.geo.rec }
            }
            ShapePath {   // prévision
                strokeColor: root.accent
                strokeWidth: 2
                strokeStyle: ShapePath.DashLine
                dashPattern: [3, 2.5]
                fillColor: "transparent"
                PathPolyline { path: root.geo.fc }
            }
        }

        // Point « Maintenant » : anneau couleur de fond pour rester lisible sur les tracés.
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
        // Étiquette au-dessus du point, dessous si elle sortait du cadre.
        Rectangle {
            visible: root.hasNow
            width: nowText.implicitWidth + 12
            height: nowText.implicitHeight + 4
            radius: height / 2
            x: Math.max(plot.x, Math.min(root.width - width, dot.x + 6 - width / 2))
            y: dot.y - height - 4 >= plot.y ? dot.y - height - 4 : dot.y + 16
            color: Colors.withAlpha(Colors.background, 0.9)   // surface : 2,3:1 sous le texte avec wallust
            Text {
                id: nowText
                anchors.centerIn: parent
                text: "Maintenant"
                color: Colors.foreground
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: root.fs
                font.bold: true
            }
        }
    }
}
