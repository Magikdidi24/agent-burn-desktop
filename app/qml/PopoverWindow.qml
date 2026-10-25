import QtQuick
import QtQuick.Effects

// Tray icon popover (the one from the Mac app's menu bar): borderless card
// placed against the icon by tray.py; closed by Esc, "Open dashboard" or focus loss.
Window {
    id: win

    readonly property int pad: 16   // room for the shadow around the card = gap to the taskbar
    property int edge: Qt.BottomEdge   // taskbar edge, where the card slides in from
    property int maxHeight: 0   // usable screen height (tray.py; 0: no limit), beyond it the card scrolls
    property alias tab: content.tab
    property real closedAt: 0   // closed by focus loss: tray.py ignores the icon click that follows
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

    // Short screen: the card scrolls to the control reached by keyboard (Tab).
    onActiveFocusItemChanged: {
        const item = activeFocusItem;
        let inside = false;
        for (let p = item; p && !inside; p = p.parent)
            inside = p === flick;
        if (!inside)
            return;
        const y = item.mapToItem(flick.contentItem, 0, 0).y, max = Math.max(0, flick.contentHeight - flick.height);
        if (y - 12 < flick.contentY)
            flick.contentY = Math.max(0, y - 12);
        else if (y + item.height + 12 > flick.contentY + flick.height)
            flick.contentY = Math.min(max, y + item.height + 12 - flick.height);
    }

    Item {
        id: box
        x: win.pad
        y: win.pad
        width: 440
        height: win.maxHeight > 0 ? Math.min(content.implicitHeight, win.maxHeight) : content.implicitHeight
        transform: Translate { id: slide }
        // Page up or down, home, end: by keyboard too, with or without a focused control.
        focus: true
        Keys.onPressed: event => {
            const max = Math.max(0, flick.contentHeight - flick.height), step = flick.height - 40;
            const to = event.key === Qt.Key_PageDown ? flick.contentY + step : event.key === Qt.Key_PageUp ? flick.contentY - step
                     : event.key === Qt.Key_Home ? 0 : event.key === Qt.Key_End ? max : NaN;
            if (isNaN(to))
                return;
            flick.contentY = Math.max(0, Math.min(max, to));
            event.accepted = true;
        }

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
        // Laptop at 1080p and 150%: an agent's tab is taller than the usable screen height.
        Flickable {
            id: flick
            anchors.fill: parent
            clip: true
            contentHeight: content.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            BurnPopover {
                id: content
                width: parent.width
                visible: win.visible   // content created and refreshed (poke) only while the popover is open
                onCloseRequested: win.dismiss()
            }
        }
        // Scroll indicator, as in the dashboard (the Flickable draws none).
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
