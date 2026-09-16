import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.extras as PlasmaExtras
import "lib"
import "lib/MirrorState.js" as MirrorState

Item {
    id: pane

    readonly property real phoneAspect: root.phoneAspect
    readonly property int wantW: Math.round(root.phoneH * phoneAspect) + Kirigami.Units.largeSpacing * 2
    readonly property int wantH: Math.round(root.phoneH + chromeH)

    readonly property real chromeH: {
        const large = Kirigami.Units.largeSpacing
        const header = Math.max(Kirigami.Units.iconSizes.medium, measureTitle.implicitHeight + measureSubtitle.implicitHeight, measureButton.implicitHeight)
        const shellChrome = large * 2 + header + large + measureSearch.implicitHeight + large + measureTabs.implicitHeight + large
        const body = controls.implicitHeight + large + Kirigami.Units.smallSpacing + dragHandle.Layout.preferredHeight
        return shellChrome + body
    }

    Item {
        visible: false
        Kirigami.Heading { id: measureTitle; level: 3; text: "Ag"; font.weight: Font.DemiBold }
        PlasmaComponents.Label { id: measureSubtitle; text: "Ag"; font: Kirigami.Theme.smallFont }
        PlasmaComponents.ToolButton { id: measureButton; icon.name: "window-new"; display: PlasmaComponents.AbstractButton.IconOnly }
        PlasmaExtras.SearchField { id: measureSearch }
        PopTabs { id: measureTabs; model: root.tabModel }
    }

    implicitWidth: root.inPanel ? wantW : Kirigami.Units.gridUnit * 20
    implicitHeight: root.inPanel ? wantH : Kirigami.Units.gridUnit * 34
    Layout.minimumWidth: root.inPanel ? wantW : Kirigami.Units.gridUnit * 16
    Layout.maximumWidth: root.inPanel ? wantW : -1
    Layout.minimumHeight: root.inPanel ? wantH : Kirigami.Units.gridUnit * 24
    Layout.maximumHeight: root.inPanel ? wantH : -1
    Layout.preferredWidth: implicitWidth
    Layout.preferredHeight: implicitHeight

    readonly property bool winActive: Window.active
    onWinActiveChanged: {
        root.popupFocused = winActive
        if (!winActive && root.inPanel && root.expanded && !root.pinned) focusGuard.restart()
    }
    Component.onCompleted: root.popupFocused = Window.active
    Timer {
        id: focusGuard
        interval: 150
        onTriggered: if (!pane.winActive && root.expanded && !root.pinned)
                         activeProbe.connectSource("kdotool getactivewindow getwindowname")
    }
    P5Support.DataSource {
        id: activeProbe
        engine: "executable"
        onNewData: function(src, d) {
            disconnectSource(src)
            if (pane.winActive || !root.expanded || root.pinned) return
            var name = (d.stdout || "").trim()
            if (name !== "" && name.indexOf("PhoneScreenPinned") === -1)
                root.expanded = false
        }
    }

    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded)
                shell.focusSearch()
        }
        function onTabRequested(index) {
            shell.clearSearch()
            root.currentTab = index
        }
    }

    PopupShell {
        id: shell
        anchors.fill: parent

        icon: "smartphone"
        title: feed.activeName || (feed.ready ? i18n("No phone found") : i18n("Phone Manager"))
        subtitle: {
            const parts = [MirrorState.linkText(mirror.link)]
            if (mirror.link === "wifi" && root.activeDevice && root.activeDevice.last_ip)
                parts.push(root.activeDevice.last_ip)
            parts.push(root.mirrorView.text)
            return parts.join("  ·  ")
        }
        statusColor: root.statusColor
        statusText: root.mirrorView.text
        searchPlaceholder: i18n("Search settings, phones, actions…")
        tabs: root.tabModel
        currentTab: root.currentTab
        onTabActivated: index => root.currentTab = index
        onCloseRequested: if (root.inPanel) root.expanded = false
        matchCount: results.item ? results.item.count : -1
        onSearchAccepted: if (results.item) results.item.activateFirst()
        onSearchTextChanged: root.searching = searchText !== ""

        headerActions: [
            PlasmaComponents.ToolButton {
                icon.name: "window-new"
                display: PlasmaComponents.AbstractButton.IconOnly
                enabled: root.reachable && mirror.status !== "external"
                text: i18n("Pop out")
                onClicked: root.popOut()
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: text
                QQC2.ToolTip.delay: 600
            },
            PlasmaComponents.ToolButton {
                visible: root.inPanel
                checkable: true
                checked: root.pinned
                icon.name: root.pinned ? "window-pin" : "window-unpin"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: root.pinned ? i18n("Pinned open") : i18n("Pin open")
                onToggled: root.pinned = checked
                QQC2.ToolTip.visible: hovered
                QQC2.ToolTip.text: text
                QQC2.ToolTip.delay: 600
            }
        ]

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Item {
                id: stackHolder
                Layout.fillWidth: true
                Layout.fillHeight: true

                StackLayout {
                    anchors.fill: parent
                    currentIndex: root.currentTab
                    visible: !root.searching

                    ColumnLayout {
                        id: phoneColumn
                        spacing: Kirigami.Units.largeSpacing

                        PhoneStage {
                            id: phoneArea
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            view: root.mirrorView
                            unlockable: root.displayLocked
                            onUnlockRequested: root.toggleLock()
                            Component.onCompleted: { root._phoneTarget = phoneArea; root.claimMirror() }
                            onWidthChanged: if (!root.resizing) root.claimMirror()
                            onHeightChanged: if (!root.resizing) root.claimMirror()
                        }

                        PhoneControls {
                            id: controls
                            Layout.fillWidth: true
                            reachable: root.reachable
                            locked: root.displayLocked
                            onVolumeDown: root.volDown()
                            onVolumeUp: root.volUp()
                            onNavigate: key => root.navKey(key)
                            onLockToggled: root.toggleLock()
                        }
                    }

                    Loader {
                        active: root.currentTab === 1
                        source: "CameraTab.qml"
                    }

                    Loader {
                        active: root.currentTab === 2
                        source: "SettingsTab.qml"
                    }
                }

                Loader {
                    id: results
                    anchors.fill: parent
                    active: root.searching
                    source: "SearchResults.qml"
                    onLoaded: item.query = Qt.binding(() => shell.searchText.trim())
                }
            }

            MouseArea {
                id: dragHandle
                visible: root.inPanel
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.75
                cursorShape: Qt.SizeVerCursor
                hoverEnabled: true
                property int startH: 0
                property real startGY: 0
                onPressed: function(mouse) {
                    startH = root.phoneH
                    startGY = mapToGlobal(mouse.x, mouse.y).y
                    root.resizing = true
                    root.claimMirror()
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var dy = mapToGlobal(mouse.x, mouse.y).y - startGY
                    root.phoneH = Math.max(240, Math.min(2000, startH + dy))
                }
                onReleased: {
                    root.saveHeight()
                    root.resizing = false
                    root.claimMirror()
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: Kirigami.Units.gridUnit * 3
                    height: 4
                    radius: 2
                    color: Qt.alpha(Kirigami.Theme.textColor, dragHandle.pressed || dragHandle.containsMouse ? 0.6 : 0.25)
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }
}
