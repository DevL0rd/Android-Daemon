import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore

MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    property bool wasExpanded: false

    hoverEnabled: true
    onPressed: wasExpanded = root.expanded
    onClicked: root.expanded = !wasExpanded

    Layout.minimumWidth: vertical ? 0 : height
    Layout.maximumWidth: vertical ? Infinity : height
    Layout.minimumHeight: vertical ? width : 0
    Layout.maximumHeight: vertical ? width : Infinity

    Kirigami.Icon {
        anchors.centerIn: parent
        width: Kirigami.Units.iconSizes.smallMedium
        height: width
        source: root.trayIcon
        fallback: "smartphone-symbolic"
        active: compact.containsMouse
    }
}
