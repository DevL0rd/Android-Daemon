import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

RowLayout {
    id: header

    property string icon: "smartphone"
    property string title
    property string subtitle
    property color statusColor: Kirigami.Theme.positiveTextColor
    property string statusText
    default property alias actions: actionRow.data

    spacing: Kirigami.Units.largeSpacing

    Item {
        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
        Kirigami.Icon {
            anchors.fill: parent
            source: header.icon
        }
        Rectangle {
            width: Math.round(Kirigami.Units.iconSizes.medium * 0.34)
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: -2
            color: header.statusColor
            border.width: 2
            border.color: Kirigami.Theme.backgroundColor
            Behavior on color { ColorAnimation { duration: 280 } }
            HoverHandler { id: statusHover }
            QQC2.ToolTip.visible: statusHover.hovered && header.statusText !== ""
            QQC2.ToolTip.text: header.statusText
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        spacing: 0
        Kirigami.Heading {
            level: 3
            text: header.title
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        PlasmaComponents.Label {
            visible: header.subtitle !== ""
            text: header.subtitle
            font: Kirigami.Theme.smallFont
            opacity: 0.65
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    RowLayout {
        id: actionRow
        spacing: 0
    }
}
