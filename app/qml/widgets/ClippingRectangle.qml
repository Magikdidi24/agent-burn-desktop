pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// ClippingRectangle de Quickshell.Widgets : rectangle arrondi qui découpe son contenu sur ses coins
// (le shader propre à Quickshell remplacé par un masque MultiEffect).
Rectangle {
    id: root
    default property alias content: box.data

    Item {
        id: box
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: true
    }
}
