import QtQuick

// IconImage from Quickshell.Widgets (same rendering): square image, decoded at its display size.
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
