import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import "lib"
import "lib/Highlight.js" as Highlight

Item {
    id: results

    property string query
    readonly property string needle: query.toLowerCase()

    function fieldMatches(field) {
        return Highlight.matchesAny([field.label, field.section, field.hint || "", field.keywords || ""], needle)
    }

    readonly property var actions: [
        { text: root.displayLocked ? i18n("Unlock phone") : i18n("Lock phone"), icon: root.displayLocked ? "object-unlocked" : "object-locked", keywords: "lock unlock screen pin", run: () => root.toggleLock(), enabled: root.reachable },
        { text: i18n("Pop out mirror"), icon: "window-new", keywords: "pop out window mirror scrcpy", run: () => root.popOut(), enabled: root.reachable && mirror.status !== "external" },
        { text: i18n("Volume up"), icon: "audio-volume-high", keywords: "volume louder sound", run: () => root.volUp(), enabled: root.reachable },
        { text: i18n("Volume down"), icon: "audio-volume-low", keywords: "volume quieter sound", run: () => root.volDown(), enabled: root.reachable },
        { text: i18n("Back"), icon: "draw-arrow-back", keywords: "back navigate", run: () => root.navKey("back"), enabled: root.reachable },
        { text: i18n("Home"), icon: "go-home", keywords: "home launcher navigate", run: () => root.navKey("home"), enabled: root.reachable },
        { text: i18n("Recent apps"), icon: "window-duplicate", keywords: "recents apps switcher overview", run: () => root.navKey("recents"), enabled: root.reachable },
        { text: i18n("Show phone"), icon: "smartphone", keywords: "phone mirror screen view", run: () => root.openTab(0), enabled: true },
        { text: i18n("Show webcam"), icon: "camera-web", keywords: "camera webcam preview video", run: () => root.openTab(1), enabled: true },
        { text: i18n("Show settings"), icon: "configure", keywords: "settings options preferences", run: () => root.openTab(2), enabled: true }
    ].filter(action => action.enabled && Highlight.matchesAny([action.text, action.keywords], needle))

    readonly property var phones: (feed.devices || []).filter(device => Highlight.matchesAny([device.name, device.serial, device.last_ip, device.usb ? "usb" : device.last_ip ? "wifi wi-fi" : "offline"], needle))
    readonly property var cameraMatches: root.cameraFields.filter(fieldMatches)
    readonly property var deviceMatches: root.activeDevice ? root.deviceFields.filter(fieldMatches) : []
    readonly property int count: actions.length + phones.length + cameraMatches.length + deviceMatches.length

    function activateFirst() {
        if (actions.length > 0) {
            actions[0].run()
        } else if (phones.length > 0) {
            root.selectDevice(phones[0].serial)
        } else if (cameraMatches.length > 0) {
            root.openTab(1)
        } else if (deviceMatches.length > 0) {
            root.openTab(2)
        }
    }

    PopScroll {
        anchors.fill: parent
        visible: results.count > 0

        PopCard {
            visible: results.actions.length > 0
            title: i18n("Actions")
            icon: "system-run"
            trailing: results.actions.length + ""

            Repeater {
                model: results.actions
                MouseArea {
                    id: actionRow
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    implicitHeight: actionContent.implicitHeight + Kirigami.Units.smallSpacing * 3
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modelData.run()

                    Rectangle {
                        anchors.fill: parent
                        radius: Kirigami.Units.cornerRadius * 1.5
                        color: actionRow.index === 0 ? Qt.alpha(Kirigami.Theme.highlightColor, actionRow.containsMouse ? 0.24 : 0.14)
                             : actionRow.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.06) : "transparent"
                    }
                    RowLayout {
                        id: actionContent
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
                        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: actionRow.modelData.icon
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            text: Highlight.mark(actionRow.modelData.text, results.needle, Kirigami.Theme.highlightColor)
                            textFormat: Text.StyledText
                            elide: Text.ElideRight
                        }
                        PlasmaComponents.Label {
                            visible: actionRow.index === 0
                            text: i18n("Enter")
                            font: Kirigami.Theme.smallFont
                            opacity: 0.55
                        }
                    }
                }
            }
        }

        PopCard {
            visible: results.phones.length > 0
            title: i18n("Phones")
            icon: "phone"
            trailing: results.phones.length + ""
            Repeater {
                model: results.phones
                DeviceRow {
                    required property var modelData
                    Layout.fillWidth: true
                    device: modelData
                    query: results.needle
                }
            }
        }

        PopCard {
            visible: results.cameraMatches.length > 0
            title: i18n("Webcam settings")
            icon: "camera-web"
            trailing: results.cameraMatches.length + ""
            Repeater {
                model: results.cameraMatches
                SettingField {
                    required property var modelData
                    spec: modelData
                    query: results.needle
                }
            }
        }

        PopCard {
            visible: results.deviceMatches.length > 0
            title: i18n("Phone settings")
            icon: "configure"
            trailing: feed.activeName
            Repeater {
                model: results.deviceMatches
                SettingField {
                    required property var modelData
                    spec: modelData
                    query: results.needle
                }
            }
        }
    }

    PlasmaExtras.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 2
        visible: results.count === 0
        iconName: "edit-find"
        text: i18n("Nothing matches “%1”", results.query)
        explanation: i18n("Try a setting name, a phone, or an action like lock or home.")
    }
}
