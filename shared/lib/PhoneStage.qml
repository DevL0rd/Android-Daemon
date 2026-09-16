import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "MirrorState.js" as MirrorState

Rectangle {
    id: stage

    property var view: ({ key: "", icon: "smartphone", text: "", detail: "", tone: "neutral", busy: false })
    property bool unlockable: false
    signal unlockRequested()

    readonly property color toneColor: MirrorState.toneColor(view.tone, Kirigami.Theme)

    radius: Kirigami.Units.cornerRadius * 2
    color: Qt.alpha(Kirigami.Theme.textColor, 0.045)
    border.width: 1
    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.07)
    clip: true

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.alpha(stage.toneColor, 0.10) }
            GradientStop { position: 0.55; color: "transparent" }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: stage.unlockable
        acceptedButtons: Qt.LeftButton
        cursorShape: stage.unlockable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onDoubleClicked: stage.unlockRequested()
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.largeSpacing * 2, Kirigami.Units.gridUnit * 14)
        spacing: Kirigami.Units.largeSpacing

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.huge
            Layout.preferredHeight: Kirigami.Units.iconSizes.huge

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Qt.alpha(stage.toneColor, 0.14)
                border.width: 1
                border.color: Qt.alpha(stage.toneColor, 0.35)
            }
            Kirigami.Icon {
                anchors.centerIn: parent
                width: Kirigami.Units.iconSizes.medium
                height: width
                source: stage.view.icon
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: stage.view.text
            font.weight: Font.DemiBold
            wrapMode: Text.WordWrap
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            text: stage.view.detail
            font: Kirigami.Theme.smallFont
            opacity: 0.65
            wrapMode: Text.WordWrap
        }
    }
}
