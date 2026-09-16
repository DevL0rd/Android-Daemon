import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "lib/MirrorState.js" as MirrorState

MouseArea {
    id: compact

    property bool wasExpanded: false
    readonly property color badgeColor: !feed.ready ? Kirigami.Theme.negativeTextColor
        : root.cameraInUse ? Kirigami.Theme.negativeTextColor
        : mirror.link !== "" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor

    hoverEnabled: true
    onPressed: wasExpanded = root.expanded
    onClicked: root.expanded = !wasExpanded

    Layout.minimumWidth: Kirigami.Units.iconSizes.medium
    Layout.minimumHeight: Kirigami.Units.iconSizes.medium

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Kirigami.Units.cornerRadius
        color: Qt.alpha(Kirigami.Theme.textColor, compact.containsMouse || root.expanded ? 0.08 : 0)
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    Kirigami.Icon {
        id: icon
        anchors.centerIn: parent
        width: Math.min(parent.width, parent.height)
        height: width
        source: "smartphone"
        active: compact.containsMouse
    }

    Rectangle {
        visible: feed.ready
        width: Math.round(icon.width * 0.5)
        height: width
        radius: width / 2
        anchors.right: icon.right
        anchors.bottom: icon.bottom
        color: Kirigami.Theme.backgroundColor
        border.width: Math.max(1, Math.round(width * 0.08))
        border.color: compact.badgeColor
        Behavior on border.color { ColorAnimation { duration: 280 } }

        Kirigami.Icon {
            anchors.fill: parent
            anchors.margins: Math.round(parent.width * 0.18)
            source: root.cameraInUse ? "camera-web" : MirrorState.linkIcon(mirror.link)
            isMask: true
            color: compact.badgeColor
        }
    }
}
