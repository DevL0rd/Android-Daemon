import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import "lib"
import "lib/MirrorState.js" as MirrorState

PlasmoidItem {
    id: root

    readonly property string ctlBin: "$HOME/.local/bin/phonescreenctl"
    readonly property string serial: (Plasmoid.configuration.deviceSerial || "").trim()
    readonly property string serialArg: serial !== "" ? " " + serial : ""
    readonly property bool inPanel: Plasmoid.formFactor === PlasmaCore.Types.Horizontal || Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool dataWanted: inPanel || visible
    readonly property bool mirrorMine: feed.owner === "" || feed.owner === "desktop"

    property var pendingLock: null
    readonly property bool displayLocked: pendingLock !== null ? pendingLock : feed.locked
    Connections {
        target: feed
        function onLockedChanged() {
            if (root.pendingLock !== null && feed.locked === root.pendingLock)
                root.pendingLock = null
        }
    }
    Timer { id: pendingClear; interval: 10000; onTriggered: root.pendingLock = null }

    readonly property var mirrorView: MirrorState.describe({
        resizing: false,
        ready: feed.ready,
        elsewhere: !root.mirrorMine,
        status: feed.status,
        reachable: feed.reachable,
        locked: root.displayLocked
    })
    readonly property color statusColor: MirrorState.toneColor(mirrorView.tone, Kirigami.Theme)

    Plasmoid.title: i18n("Phone Screen")
    Plasmoid.icon: "smartphone"
    preferredRepresentation: fullRepresentation
    toolTipMainText: feed.activeName || i18n("Phone Screen")
    toolTipSubText: mirrorView.text

    ScreenData {
        id: feed
        active: root.dataWanted
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ctl(args) { runner.connectSource(root.ctlBin + " " + args) }

    property var _pinTarget: null
    function screenRect() {
        var p = _pinTarget.mapToGlobal(0, 0)
        return {
            x: Math.round(p.x) + Plasmoid.configuration.offsetX,
            y: Math.round(p.y) + Plasmoid.configuration.offsetY,
            w: Math.round(_pinTarget.width),
            h: Math.round(_pinTarget.height)
        }
    }

    function claimMirror() {
        if (!_pinTarget || !root.dataWanted) return
        var r = screenRect()
        var a = "claim desktop 1 " + r.x + " " + r.y + " " + r.w + " " + r.h + root.serialArg
        a += " --above " + (Plasmoid.configuration.keepBelow ? 0 : 1)
        a += " --borderless " + (Plasmoid.configuration.borderless ? 1 : 0)
        var extra = (Plasmoid.configuration.extraArgs || "").replace(/'/g, "").trim()
        if (extra !== "") a += " --extra '" + extra + "'"
        ctl(a)
    }
    onDataWantedChanged: {
        if (root.dataWanted) claimMirror()
        else ctl("release desktop")
    }
    function popOut() { ctl("window" + root.serialArg) }
    function toggleLock() {
        root.pendingLock = !root.displayLocked
        pendingClear.restart()
        ctl((root.pendingLock ? "lock" : "unlock") + root.serialArg)
    }

    Timer {
        interval: 1000; repeat: true
        running: root.dataWanted
        triggeredOnStart: true
        onTriggered: root.claimMirror()
    }

    fullRepresentation: Item {
        id: rep
        Layout.minimumWidth: Kirigami.Units.gridUnit * 12
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        implicitWidth: Kirigami.Units.gridUnit * 16
        implicitHeight: Kirigami.Units.gridUnit * 30

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.largeSpacing

            PhoneHeader {
                Layout.fillWidth: true
                title: feed.activeName || (feed.ready ? i18n("No phone found") : i18n("Phone Screen"))
                subtitle: {
                    const parts = [MirrorState.linkText(feed.reachable ? feed.transport : "")]
                    if (feed.transport === "wifi")
                        parts.push(feed.lastIp)
                    parts.push(root.mirrorView.text)
                    return parts.join("  ·  ")
                }
                statusColor: root.statusColor
                statusText: root.mirrorView.text

                PlasmaComponents.ToolButton {
                    icon.name: "window-new"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: feed.ready && feed.reachable && feed.status !== "external"
                    onClicked: root.popOut()
                    text: i18n("Pop out")
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: Plasmoid.internalAction("configure").trigger()
                    text: i18n("Configure…")
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: 600
                }
            }

            PhoneStage {
                id: screenArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                view: root.mirrorView
                unlockable: root.displayLocked
                onUnlockRequested: root.toggleLock()
                Component.onCompleted: { root._pinTarget = screenArea; root.claimMirror() }
                onWidthChanged: root.claimMirror()
                onHeightChanged: root.claimMirror()
            }

            PhoneControls {
                Layout.fillWidth: true
                reachable: feed.ready && feed.reachable
                locked: root.displayLocked
                onVolumeDown: root.ctl("volume down" + root.serialArg)
                onVolumeUp: root.ctl("volume up" + root.serialArg)
                onNavigate: key => root.ctl("nav " + key + root.serialArg)
                onLockToggled: root.toggleLock()
            }
        }
    }
}
