import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import "lib"

PopScroll {
    id: tab

    readonly property var sectionIcons: ({
        [i18n("Device")]: "smartphone",
        [i18n("Connection")]: "network-connect",
        [i18n("Mirror")]: "video-display",
        [i18n("Notifications")]: "notifications"
    })
    readonly property var groups: {
        const found = []
        for (const field of root.deviceFields) {
            let group = found.find(entry => entry.section === field.section)
            if (!group) {
                group = { section: field.section, icon: sectionIcons[field.section] || "configure", fields: [] }
                found.push(group)
            }
            group.fields.push(field)
        }
        return found
    }

    PopCard {
        title: i18n("Phones")
        icon: "phone"
        trailing: feed.devices.length + ""

        PlasmaComponents.Label {
            visible: feed.devices.length === 0
            Layout.fillWidth: true
            text: feed.ready ? i18n("No phones paired yet. Plug one in over USB.") : i18n("The daemon isn't running.")
            opacity: 0.65
            wrapMode: Text.WordWrap
        }
        Repeater {
            model: feed.devices
            DeviceRow {
                required property var modelData
                Layout.fillWidth: true
                device: modelData
            }
        }
    }

    Repeater {
        model: tab.groups

        PopCard {
            required property var modelData
            visible: feed.activeSerial !== ""
            title: modelData.section
            icon: modelData.icon
            trailing: modelData.section === i18n("Device") ? feed.activeName : ""

            Repeater {
                model: modelData.fields
                SettingField {
                    required property var modelData
                    spec: modelData
                }
            }
        }
    }
}
