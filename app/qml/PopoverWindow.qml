import QtQuick
import QtQuick.Effects

// Popover de l'icône de notification (celui de la barre de menus de l'app Mac) : carte sans bordure
// posée contre l'icône par tray.py ; fermée par Échap, « Ouvrir le dashboard » ou la perte du focus.
Window {
    id: win

    readonly property int pad: 16   // place de l'ombre autour de la carte = écart à la barre des tâches
    property int edge: Qt.BottomEdge   // bord de la barre des tâches, d'où la carte glisse
    property int maxHeight: 0   // hauteur utile de l'écran (tray.py ; 0 : sans limite), au-delà la carte défile
    property alias tab: content.tab
    property real closedAt: 0   // fermé par perte du focus : tray.py ignore le clic d'icône qui suit
    readonly property point start: edge === Qt.TopEdge ? Qt.point(0, -10) : edge === Qt.LeftEdge ? Qt.point(-10, 0)
                                 : edge === Qt.RightEdge ? Qt.point(10, 0) : Qt.point(0, 10)

    width: box.width + 2 * pad
    height: box.height + 2 * pad
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    title: "Agent Burn"

    function open() {
        leave.stop();
        visible = true;
        raise();
        requestActivate();
        enter.restart();
    }
    function dismiss() {
        if (visible && !leave.running) {
            enter.stop();
            leave.start();
        }
    }
    onActiveChanged: if (!active && visible) {
        closedAt = Date.now();
        dismiss();
    }

    Shortcut { sequence: "Esc"; onActivated: win.dismiss() }

    Item {
        id: box
        x: win.pad
        y: win.pad
        width: 440
        height: win.maxHeight > 0 ? Math.min(content.implicitHeight, win.maxHeight) : content.implicitHeight
        transform: Translate { id: slide }

        RectangularShadow {
            anchors.fill: parent
            radius: 12
            blur: 16
            offset.y: 4
            color: Qt.rgba(0, 0, 0, Colors.dark ? 0.5 : 0.18)
        }
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Colors.background
            border.width: 1
            border.color: Colors.withAlpha(Colors.muted, 0.3)
        }
        // Portable en 1080p à 150 % : l'onglet d'un agent dépasse la hauteur utile de l'écran.
        Flickable {
            id: flick
            anchors.fill: parent
            clip: true
            contentHeight: content.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            BurnPopover {
                id: content
                width: parent.width
                visible: win.visible   // contenu créé et rafraîchi (poke) seulement popover ouvert
                onCloseRequested: win.dismiss()
            }
        }
        // Indicateur de défilement, celui du dashboard (le Flickable n'en dessine pas).
        Rectangle {
            x: flick.x + flick.width - 7
            y: flick.y + flick.visibleArea.yPosition * flick.height
            width: 4
            height: flick.visibleArea.heightRatio * flick.height
            radius: 2
            visible: flick.visibleArea.heightRatio < 1
            color: Colors.withAlpha(Colors.muted, 0.35)
        }
    }

    ParallelAnimation {
        id: enter
        NumberAnimation { target: box; property: "opacity"; from: 0; to: 1; duration: 150; easing.type: Easing.OutCubic }
        NumberAnimation { target: slide; property: "x"; from: win.start.x; to: 0; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { target: slide; property: "y"; from: win.start.y; to: 0; duration: 200; easing.type: Easing.OutCubic }
    }
    SequentialAnimation {
        id: leave
        NumberAnimation { target: box; property: "opacity"; to: 0; duration: 100; easing.type: Easing.InCubic }
        ScriptAction { script: win.visible = false }
    }
}
