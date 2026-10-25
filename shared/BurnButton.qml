import QtQuick

// Bouton des vues Agent Burn : clic, ou Tab puis Entrée / Espace ; lecteurs d'écran par Accessible.*
// (rôle Button par défaut, nom = tip sauf mention contraire), anneau de focus, info-bulle facultative.
// Info-bulle maison : QtQuick.Controls n'est chargé ni par la barre ni par l'app de bureau.
Rectangle {
    id: btn

    property string tip                  // info-bulle au survol ou au focus, à gauche du bouton
    property color ring: Colors.accent   // anneau de focus ; autre teinte sur un fond déjà accent
    property real reach: 0               // cible de clic agrandie de reach px de chaque côté
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
    // Tracé dans les bords (un parent qui découpe ne le rogne pas), par-dessus le contenu.
    Rectangle {
        z: 1
        anchors.fill: parent
        visible: btn.activeFocus
        radius: btn.radius
        color: "transparent"
        border.width: 2
        border.color: btn.ring
    }
    // À gauche : les boutons à icône seule sont au bord droit de leur vue, la bulle reste dedans.
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
            Accessible.ignored: true   // déjà le nom du bouton
        }
    }
}
