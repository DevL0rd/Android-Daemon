import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import "lib"

PopScroll {
    id: tab

    readonly property var sections: {
        const names = []
        for (const field of root.deviceFields)
            if (names.indexOf(field.section) < 0)
                names.push(field.section)
        return names
    }
    readonly property var sectionIcons: ({
        [i18n("Device")]: "smartphone",
        [i18n("Connection")]: "network-connect",
        [i18n("Mirror")]: "video-display",
        [i18n("Notifications")]: "notifications"
    })

    PopCard {
        title: i18n("Phones")
        icon: "phone"
        trailing: (feed.devices || []).length + ""

        PlasmaComponents.Label {
            visible: (feed.devices || []).length === 0
            Layout.fillWidth: true
            text: feed.ready ? i18n("No phones paired yet. Plug one in over USB.") : i18n("The daemon isn't running.")
            opacity: 0.65
            wrapMode: Text.WordWrap
        }
        Repeater {
            model: feed.devices || []
            DeviceRow {
                required property var modelData
                Layout.fillWidth: true
                device: modelData
            }
        }
    }

    Repeater {
        model: root.activeDevice ? tab.sections : []

        PopCard {
            required property string modelData
            readonly property string section: modelData
            title: section
            icon: tab.sectionIcons[section] || "configure"
            trailing: section === i18n("Device") ? feed.activeName : ""

            Repeater {
                model: root.deviceFields.filter(field => field.section === section)
                SettingField {
                    required property var modelData
                    spec: modelData
                }
            }
        }
    }
}
