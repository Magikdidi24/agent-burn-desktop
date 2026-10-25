pragma ComponentBehavior: Bound
import QtQuick

// Histogramme quotidien (« Daily spend » de l'app Mac) : une barre par jour, jour absent = trou,
// survol d'une colonne = info-bulle date + valeur. Composant pur : le parent fournit les points.
Item {
    id: root
    property var points: []          // [{ date: "YYYY-MM-DD", value }] triés ; value null = montant inconnu
    property color barColor: Colors.accent
    property string unit: "USD"
    property bool compact: false

    implicitWidth: 360
    implicitHeight: compact ? 150 : 190

    readonly property int fs: compact ? 10 : 11
    readonly property var fr: Qt.locale("fr_FR")

    // Lecteurs d'écran (Burn.accessibleText, app de bureau) : le graphe en une phrase. Posé en JS comme les Txt
    // des vues : la barre Quickshell n'a aucun objet Accessible de plus.
    readonly property bool exposed: Burn.accessibleText === true
    onExposedChanged: if (exposed) {
        Accessible.role = Accessible.Chart;
        Accessible.name = Qt.binding(() => root.summary());
    }
    // Période, total et jour le plus cher ; sans graphe, le message affiché à sa place.
    function summary() {
        if (!chart.ok) return empty.text;
        const known = points.filter(p => p.value !== null), d = s => day(s).toLocaleString(fr, "d MMM");
        const peak = known.reduce((a, p) => p.value > a.value ? p : a);
        if (points.length === 1) return day(peak.date).toLocaleString(fr, "ddd d MMM") + " : " + fmt(peak.value);
        return "Du " + d(points[0].date) + " au " + d(points[points.length - 1].date) + " : "
            + fmt(known.reduce((s, p) => s + p.value, 0)) + " au total, pic de " + fmt(peak.value)
            + " le " + day(peak.date).toLocaleString(fr, "ddd d MMM");
    }

    function day(s) { const p = s.split("-"); return new Date(p[0], p[1] - 1, p[2]); }
    // Points des n derniers jours (Burn.lastDays) d'une série Burn.dailySeries ; jour à tokens sans prix : null.
    function lastDays(series, n) {
        const tokens = {};
        for (const d of series) tokens[d.date] = d.tokens;
        return Burn.lastDays(series, n).map(p => ({ date: p.date, value: Burn.priced(p.value, tokens[p.date] ?? 0) }));
    }
    function fmt(v) { return Burn.money(v); }
    // Graduations compactes, zéros décimaux en moins : "$1,000.00" → "$1,000", "$2.50" → "$2.5".
    function tick(v) { return fmt(v).replace(/(\.\d*?)0+(?=\D*$)/, "$1").replace(/\.(?=\D*$)/, ""); }

    // Index de jour de chaque point et graduations Y rondes.
    readonly property var chart: {
        const pts = points || [];
        const max = Math.max(0, ...pts.map(p => p.value));
        if (!(max > 0)) return { ok: false, idx: [], days: 1, ticks: [], top: 1 };
        const t0 = day(pts[0].date);
        // round : un jour de changement d'heure dure 23 ou 25 h.
        const idx = pts.map(p => Math.round((day(p.date) - t0) / 864e5));
        // Pas de 1, 2, 2,5 ou 5 × 10^k : 4 ou 5 graduations, 0 compris.
        const raw = max / 4, mag = Math.pow(10, Math.floor(Math.log10(raw))), n = raw / mag;
        const step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * mag;
        const ticks = [];
        for (let i = 0; i <= Math.ceil(max / step - 1e-9); i++) ticks.push(i * step);
        return { ok: true, t0: t0, idx: idx, days: idx[idx.length - 1] + 1, ticks: ticks, top: ticks[ticks.length - 1] };
    }

    // Jours sur 2 semaines au plus ; au-delà les débuts de mois s'il y en a au moins 3, sinon des jours
    // espacés. Une étiquette sur `stride` pour garder ≥ 80 px entre deux : même recalée au bord,
    // une date ne chevauche pas sa voisine.
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
        // Tokens sans aucun prix (hors ligne) : des jours d'usage, pas un graphe vide.
        text: (root.points || []).some(p => p.value === null) ? "Montants inconnus : tarifs indisponibles" : "Aucune donnée"
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

        // Cadre des barres ; la gouttière gauche suit la plus longue graduation.
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
                // 24 px au plus et 2 px d'air entre voisines ; 1 px minimum sur les longues plages.
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
                text: modelData.d.toLocaleString(root.fr, "d MMM")
                color: Colors.muted
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: root.fs
            }
        }

        MouseArea {
            id: hover
            // Toute la colonne du jour sert de cible : les barres font parfois 1 px.
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
            readonly property var p: root.points[hover.idx]   // undefined hors survol
            visible: p !== undefined
            width: tipCol.implicitWidth + 16
            height: tipCol.implicitHeight + 10
            x: p ? Math.max(0, Math.min(root.width - width,
                plot.x + (root.chart.idx[hover.idx] + 0.5) * plot.slot - width / 2)) : 0
            y: p ? Math.max(0, plot.y + plot.height * (1 - p.value / root.chart.top) - height - 6) : 0
            radius: 8
            color: Colors.withAlpha(Colors.background, 0.97)   // surface : 2,3:1 sous le texte avec wallust
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
                    text: tip.p ? root.day(tip.p.date).toLocaleString(root.fr, "ddd d MMM yyyy") : ""
                    color: Colors.muted
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: root.fs
                }
            }
        }
    }
}
