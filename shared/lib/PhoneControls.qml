import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Rectangle {
    id: bar

    property bool reachable: false
    property bool locked: false
    signal volumeDown()
    signal volumeUp()
    signal navigate(string key)
    signal lockToggled()

    implicitHeight: row.implicitHeight + 6
    radius: height / 2
    color: Qt.alpha(Kirigami.Theme.textColor, 0.06)

    component BarButton: PlasmaComponents.ToolButton {
        property string tip
        Layout.fillWidth: true
        display: QQC2.AbstractButton.IconOnly
        enabled: bar.reachable
        text: tip
        QQC2.ToolTip.text: tip
        QQC2.ToolTip.visible: hovered
        QQC2.ToolTip.delay: 600
        background: Rectangle {
            radius: height / 2
            color: parent.down ? Qt.alpha(Kirigami.Theme.highlightColor, 0.3)
                 : parent.hovered ? Qt.alpha(Kirigami.Theme.textColor, 0.08) : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
        }
    }
    component Divider: Rectangle {
        Layout.preferredWidth: 1
        Layout.preferredHeight: Kirigami.Units.iconSizes.small
        color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
    }

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 3
        spacing: 0

        BarButton { icon.name: "audio-volume-low"; tip: i18n("Volume down"); onClicked: bar.volumeDown() }
        BarButton { icon.name: "audio-volume-high"; tip: i18n("Volume up"); onClicked: bar.volumeUp() }
        Divider {}
        BarButton { icon.name: "draw-arrow-back"; tip: i18n("Back"); onClicked: bar.navigate("back") }
        BarButton { icon.name: "go-home"; tip: i18n("Home"); onClicked: bar.navigate("home") }
        BarButton { icon.name: "window-duplicate"; tip: i18n("Recent apps"); onClicked: bar.navigate("recents") }
        Divider {}
        BarButton {
            icon.name: bar.locked ? "object-locked" : "object-unlocked"
            icon.color: bar.locked ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
            tip: bar.locked ? i18n("Unlock phone") : i18n("Lock phone")
            onClicked: bar.lockToggled()
        }
    }
}
