pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// ClippingRectangle from Quickshell.Widgets: rounded rectangle that clips its content to its corners
// (Quickshell's own shader replaced by a MultiEffect mask).
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
