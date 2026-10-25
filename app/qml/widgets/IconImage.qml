import QtQuick

// IconImage de Quickshell.Widgets (même rendu) : image carrée, décodée à sa taille d'affichage.
Item {
    id: root
    property alias source: image.source
    property real implicitSize: 0
    implicitWidth: implicitSize
    implicitHeight: implicitSize

    Image {
        id: image
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        sourceSize.width: Math.min(root.width, root.height)
        sourceSize.height: Math.min(root.width, root.height)
    }
}
