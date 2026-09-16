import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "lib/Highlight.js" as Highlight

MouseArea {
    id: row

    property var device
    property string query
    readonly property bool active: device.serial === feed.activeSerial
    readonly property string link: device.usb ? "usb" : (device.last_ip ? "wifi" : "")
    readonly property bool managed: !device.config || device.config.enabled !== false

    implicitHeight: content.implicitHeight + Kirigami.Units.smallSpacing * 3
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (!active) root.selectDevice(device.serial)

    Rectangle {
        anchors.fill: parent
        radius: Kirigami.Units.cornerRadius * 1.5
        color: row.active ? Qt.alpha(Kirigami.Theme.highlightColor, 0.16)
             : row.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.06) : "transparent"
        border.width: row.active ? 1 : 0
        border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.45)
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Icon {
            source: "smartphone"
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            opacity: row.managed ? 1 : 0.5
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            spacing: 0
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: Highlight.mark(row.device.name || row.device.serial, row.query, Kirigami.Theme.highlightColor)
                textFormat: Text.StyledText
                font.weight: row.active ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: Highlight.mark([row.device.serial, row.device.last_ip].filter(x => !!x).join("  ·  "), row.query, Kirigami.Theme.highlightColor)
                textFormat: Text.StyledText
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                elide: Text.ElideRight
            }
        }
        Rectangle {
            readonly property color tone: !row.managed ? Kirigami.Theme.disabledTextColor
                : row.link !== "" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
            Layout.preferredHeight: chipLabel.implicitHeight + Kirigami.Units.smallSpacing
            Layout.preferredWidth: chipLabel.implicitWidth + Kirigami.Units.smallSpacing * 3
            radius: height / 2
            color: Qt.alpha(tone, 0.14)
            border.width: 1
            border.color: Qt.alpha(tone, 0.4)
            PlasmaComponents.Label {
                id: chipLabel
                anchors.centerIn: parent
                text: !row.managed ? i18n("Ignored") : row.link === "usb" ? i18n("USB") : row.link === "wifi" ? i18n("Wi-Fi") : i18n("Offline")
                color: parent.tone
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight: Font.DemiBold
            }
        }
        Kirigami.Icon {
            visible: row.active
            source: "checkmark"
            isMask: true
            color: Kirigami.Theme.highlightColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
    }
}
