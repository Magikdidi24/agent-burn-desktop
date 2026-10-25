import QtQuick

// Button for the Agent Burn views: click, or Tab then Enter / Space; screen readers through Accessible.*
// (Button role by default, name = tip unless stated otherwise), focus ring, optional tooltip.
// Homemade tooltip: QtQuick.Controls is loaded by neither the bar nor the desktop app.
Rectangle {
    id: btn

    property string tip                  // tooltip on hover or focus, left of the button
    property color ring: Colors.accent   // focus ring; another tint on a background that is already accent
    property real reach: 0               // click target enlarged by reach px on each side
    readonly property bool hovered: area.containsMouse
    readonly property bool pressed: area.pressed
    signal clicked()

    color: "transparent"
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: tip
    Accessible.onPressAction: btn.clicked()
    Keys.onPressed: event => {
        if (event.isAutoRepeat || ![Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) return;
        event.accepted = true;
        btn.clicked();
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -btn.reach
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
    // Drawn inside the edges (a clipping parent does not crop it), over the content.
    Rectangle {
        z: 1
        anchors.fill: parent
        visible: btn.activeFocus
        radius: btn.radius
        color: "transparent"
        border.width: 2
        border.color: btn.ring
    }
    // On the left: icon-only buttons sit at the right edge of their view, so the tooltip stays inside.
    Rectangle {
        z: 2
        visible: btn.tip !== "" && (btn.hovered || btn.activeFocus)
        anchors.right: parent.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: tipText.implicitWidth + 16
        height: tipText.implicitHeight + 8
        radius: 6
        color: Colors.background
        border.width: 1
        border.color: Colors.withAlpha(Colors.muted, 0.4)
        Text {
            id: tipText
            anchors.centerIn: parent
            text: btn.tip
            color: Colors.foreground
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 11
            textFormat: Text.PlainText
            Accessible.ignored: true   // already the button's name
        }
    }
}
