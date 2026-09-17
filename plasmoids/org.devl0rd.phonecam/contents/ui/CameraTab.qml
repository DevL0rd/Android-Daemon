import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "lib"

PopScroll {
    id: tab

    readonly property var stateInfo: ({
        off: { text: i18n("Daemon not running"), tone: Kirigami.Theme.negativeTextColor, trailing: i18n("OFF") },
        missing: { text: i18n("Loopback missing — run install.sh"), tone: Kirigami.Theme.negativeTextColor, trailing: i18n("NO DEVICE") },
        inuse: { text: i18n("In use by %1", feed.consumers.map(c => c.name).join(", ")), tone: Kirigami.Theme.neutralTextColor, trailing: i18n("IN USE") },
        live: { text: i18n("Streaming to %1", feed.devnode || i18n("the webcam")), tone: Kirigami.Theme.positiveTextColor, trailing: i18n("LIVE") },
        error: { text: feed.error, tone: Kirigami.Theme.negativeTextColor, trailing: i18n("ERROR") },
        idle: { text: root.reachable ? i18n("Connecting preview…") : i18n("Phone not reachable"), tone: root.reachable ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.disabledTextColor, trailing: root.reachable ? i18n("STARTING") : i18n("IDLE") }
    })
    readonly property var info: stateInfo[root.cameraState]

    PopCard {
        title: i18n("Webcam")
        icon: "camera-web"
        trailing: tab.info.trailing
        trailingColor: tab.info.tone

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: width * 9 / 16
            radius: Kirigami.Units.cornerRadius * 1.5
            color: "#0a0a0a"
            clip: true
            border.width: feed.streaming ? 1 : 0
            border.color: root.accent

            Item {
                id: previewArea
                anchors.fill: parent
                anchors.margins: 1
                visible: feed.streaming && !root.appUsing
                property bool useA: true
                Image {
                    id: imgA; anchors.fill: parent; fillMode: Image.PreserveAspectFit
                    cache: false; asynchronous: true; smooth: true
                    opacity: previewArea.useA ? 1 : 0
                    onStatusChanged: if (status === Image.Ready && !previewArea.useA) previewArea.useA = true
                }
                Image {
                    id: imgB; anchors.fill: parent; fillMode: Image.PreserveAspectFit
                    cache: false; asynchronous: true; smooth: true
                    opacity: previewArea.useA ? 0 : 1
                    onStatusChanged: if (status === Image.Ready && previewArea.useA) previewArea.useA = false
                }
                Connections {
                    target: root
                    function onPreviewTickChanged() {
                        if (root.previewDir === "" || !previewArea.visible) return
                        var src = "file://" + root.previewDir + "/preview.jpg?t=" + root.previewTick
                        if (previewArea.useA) imgB.source = src
                        else imgA.source = src
                    }
                }
            }

            Rectangle {
                visible: feed.streaming && !root.appUsing
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing * 1.5
                height: liveRow.implicitHeight + Kirigami.Units.smallSpacing
                width: liveRow.implicitWidth + Kirigami.Units.smallSpacing * 3
                radius: height / 2
                color: Qt.alpha("black", 0.55)
                Row {
                    id: liveRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing
                    Rectangle {
                        width: Kirigami.Units.smallSpacing * 1.6; height: width; radius: width / 2
                        color: "#ff4d4f"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    PlasmaComponents.Label {
                        text: i18n("LIVE")
                        color: "white"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.weight: Font.DemiBold
                    }
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.largeSpacing * 2
                visible: !feed.streaming || root.appUsing
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.BusyIndicator {
                    running: root.connecting; visible: root.connecting
                    Layout.alignment: Qt.AlignHCenter
                }
                Kirigami.Icon {
                    visible: !root.connecting
                    source: !feed.loopback ? "dialog-error"
                          : root.appUsing ? "camera-web"
                          : root.reachable ? "camera-web" : "network-disconnect"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    opacity: 0.7
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: "white"; opacity: 0.85; font: Kirigami.Theme.smallFont
                    text: !feed.ready ? i18n("Daemon not running")
                        : !feed.loopback ? i18n("Loopback missing — run install.sh")
                        : root.appUsing ? i18n("In use by %1\n(preview unavailable while an app has the camera)",
                                               feed.consumers.map(function(c){return c.name}).join(", "))
                        : root.connecting ? i18n("Connecting…")
                        : root.reachable ? i18n("Connecting preview…")
                        : i18n("Phone not reachable\nPlug in USB or connect over Wi-Fi")
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: Kirigami.Units.largeSpacing
            PopStat {
                Layout.fillWidth: true
                label: i18n("Res")
                value: root.s.resolution ? root.s.resolution + "p" : "—"
                scale: 1.05
            }
            PopStat {
                Layout.fillWidth: true
                label: i18n("FPS")
                value: root.s.fps ? String(root.s.fps) : "—"
                scale: 1.05
            }
            PopStat {
                Layout.fillWidth: true
                label: i18n("Lens")
                value: root.optLabel(root.lensOptions, root.s.facing || "back")
                scale: 1.05
            }
            PopStat {
                Layout.fillWidth: true
                label: i18n("Zoom")
                value: (root.s.zoom || 1).toFixed(1)
                unit: "×"
                scale: 1.05
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: feed.ready
            spacing: Kirigami.Units.smallSpacing
            Rectangle {
                Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                Layout.preferredHeight: width
                radius: width / 2
                color: tab.info.tone
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: tab.info.text
                font: Kirigami.Theme.smallFont
                opacity: 0.8
                wrapMode: Text.WordWrap
            }
            PlasmaComponents.Label {
                visible: feed.devnode !== ""
                text: feed.devnode
                font: Kirigami.Theme.smallFont
                opacity: 0.5
            }
        }
    }

    PopCard {
        title: i18n("Phone")
        icon: "smartphone"
        visible: feed.devices.length > 1
        trailing: feed.activeName

        Repeater {
            model: feed.devices
            DeviceRow {
                required property var modelData
                Layout.fillWidth: true
                device: modelData
            }
        }
    }

    PopCard {
        title: i18n("Capture")
        icon: "camera-photo"

        Repeater {
            model: root.cameraFields
            SettingField {
                required property var modelData
                spec: modelData
            }
        }
    }
}
