import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import "lib"
import "lib/MirrorState.js" as MirrorState

PlasmoidItem {
    id: root

    readonly property string ctlBin: "$HOME/.local/bin/phonecamctl"
    readonly property string psBin: "$HOME/.local/bin/phonescreenctl"
    readonly property color accent: Plasmoid.configuration.accentColor !== ""
        ? Plasmoid.configuration.accentColor : Kirigami.Theme.highlightColor
    readonly property real maxZoom: Plasmoid.configuration.maxZoom
    readonly property int screenH: Screen.height > 0 ? Screen.height : 1080

    readonly property bool inPanel: Plasmoid.formFactor === PlasmaCore.Types.Horizontal || Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool dataWanted: inPanel || visible
    readonly property bool shown: inPanel ? expanded : visible

    readonly property string resKey: (mirror.phoneW > 0 && mirror.phoneH > 0)
        ? (mirror.phoneW + "x" + mirror.phoneH) : ""
    property int phoneH: Plasmoid.configuration.phoneHeight
    function _heightForRes(key) {
        if (key) {
            try {
                var m = JSON.parse(Plasmoid.configuration.phoneHeights || "{}")
                if (m[key] > 0) return m[key]
            } catch (e) {}
        }
        return Plasmoid.configuration.phoneHeight
    }
    onResKeyChanged: phoneH = _heightForRes(resKey)
    function saveHeight() {
        Plasmoid.configuration.phoneHeight = root.phoneH
        var m = {}
        try { m = JSON.parse(Plasmoid.configuration.phoneHeights || "{}") } catch (e) {}
        if (root.resKey) m[root.resKey] = root.phoneH
        Plasmoid.configuration.phoneHeights = JSON.stringify(m)
    }

    readonly property real phoneAspect: Plasmoid.configuration.cachedAspect > 0
        ? Plasmoid.configuration.cachedAspect : (9 / 16)
    Connections {
        target: mirror
        function onPhoneWChanged() { root._cacheAspect() }
        function onPhoneHChanged() { root._cacheAspect() }
    }
    function _cacheAspect() {
        if (mirror.phoneW > 0 && mirror.phoneH > 0) {
            var a = mirror.phoneW / mirror.phoneH
            if (Math.abs(a - Plasmoid.configuration.cachedAspect) > 0.001)
                Plasmoid.configuration.cachedAspect = a
        }
    }

    readonly property var s: feed.settings
    readonly property bool reachable: mirror.link !== ""
    readonly property bool connecting: feed.ready && root.shown && root.currentTab === 1 && reachable && !feed.streaming && !feed.error

    readonly property var activeDevice: {
        var devs = feed.devices || []
        for (var i = 0; i < devs.length; i++)
            if (devs[i].serial === feed.activeSerial) return devs[i]
        return null
    }
    readonly property var mirrorView: MirrorState.describe({
        resizing: root.resizing,
        ready: feed.ready,
        elsewhere: false,
        status: mirror.status,
        reachable: root.reachable,
        locked: root.displayLocked
    })
    readonly property color statusColor: MirrorState.toneColor(mirrorView.tone, Kirigami.Theme)
    readonly property string cameraState: !feed.ready ? "off"
        : root.appUsing ? "inuse"
        : feed.streaming ? "live"
        : !feed.loopback ? "missing"
        : feed.error ? "error" : "idle"

    Plasmoid.title: i18n("Phone Manager")
    Plasmoid.icon: "smartphone"
    toolTipMainText: i18n("Phone Manager")
    toolTipSubText: !feed.ready ? i18n("daemon not running")
                  : feed.activeName ? i18n("%1 · %2", feed.activeName, MirrorState.linkText(mirror.link))
                  : i18n("no phone")

    preferredRepresentation: inPanel ? compactRepresentation : fullRepresentation

    PhoneCamData {
        id: feed
        active: root.dataWanted
        detailed: root.shown
        onUpdated: {
            if (root.previewPaused && feed.pinGen !== root.pausedPinGen) {
                root.previewPaused = false
                root.syncPreviewWish()
            }
        }
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ctl(args) { runner.connectSource(root.ctlBin + " " + args) }
    function setting(key, val) { ctl("set " + key + " " + val) }
    function optIndex(model, val) {
        for (var i = 0; i < model.length; i++)
            if (String(model[i].value) === String(val)) return i
        return 0
    }
    function optLabel(model, val) {
        return model[optIndex(model, val)].label
    }
    function devCfg() {
        return root.activeDevice ? (root.activeDevice.config || ({})) : ({})
    }
    function devVal(key, dflt) {
        var c = devCfg()
        if (c[key] !== undefined) return c[key]
        if (feed.defaults[key] !== undefined) return feed.defaults[key]
        return dflt
    }
    function devSet(key, val) { ctl("devset " + (feed.activeSerial || "auto") + " " + key + " " + val) }
    function quoted(text) { return "'" + String(text).replace(/'/g, "") + "'" }
    function onOff(value) { return value ? "on" : "off" }

    property bool previewPaused: false
    property int pausedPinGen: 0
    property string previewDir: ""
    property int previewTick: 0
    readonly property bool previewShowing: root.shown && root.currentTab === 1 && !root.searching && !root.previewPaused
    readonly property bool appUsing: feed.consumerCount > 0
    readonly property bool cameraInUse: feed.streaming || appUsing

    P5Support.DataSource {
        id: pathResolver
        engine: "executable"
        onNewData: function(source, d) { root.previewDir = (d.stdout || "").trim(); disconnectSource(source) }
    }
    Component.onCompleted: pathResolver.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon\"")

    function syncPreviewWish() {
        ctl(root.previewShowing ? "preview on" : "preview off")
    }
    onPreviewShowingChanged: syncPreviewWish()
    Timer {
        interval: 2000; repeat: true; running: root.previewShowing
        triggeredOnStart: true
        onTriggered: root.ctl("preview on")
    }
    Timer {
        interval: Math.max(16, Math.round(1000 / (feed.settings.fps || 15)))
        repeat: true; running: root.previewShowing && feed.streaming
        onTriggered: root.previewTick++
    }
    function applyGeom() {
        if (!root.previewShowing) return
        root.pausedPinGen = feed.pinGen
        root.previewPaused = true
        ctl("preview off")
        geomFallback.restart()
    }
    Timer {
        id: geomFallback; interval: 4000
        onTriggered: if (root.previewPaused) { root.previewPaused = false; root.syncPreviewWish() }
    }

    property bool pinned: false
    property bool resizing: false
    property bool popupFocused: false
    property bool searching: false
    property int currentTab: 0
    readonly property bool phoneTab: root.currentTab === 0
    readonly property bool mirrorWanted: root.shown
    readonly property string claimName: inPanel ? "popup" : "manager"
    property var _phoneTarget: null
    property var pendingLock: null
    readonly property bool displayLocked: pendingLock !== null ? pendingLock : mirror.locked

    MirrorData {
        id: mirror
        active: root.dataWanted
    }

    P5Support.DataSource {
        id: psRunner; engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function ps(args) { psRunner.connectSource(root.psBin + " " + args) }
    function phoneSerial() { return feed.activeSerial || "" }
    function serialArg() { return phoneSerial() ? " " + phoneSerial() : "" }

    function claimMirror() {
        if (!_phoneTarget || !root.mirrorWanted) return
        var p = _phoneTarget.mapToGlobal(0, 0)
        var a = "claim " + root.claimName + " " + (root.inPanel ? 2 : 1) + " " + Math.round(p.x) + " " + Math.round(p.y)
              + " " + Math.round(_phoneTarget.width) + " " + Math.round(_phoneTarget.height)
        if (phoneSerial() !== "") a += " " + phoneSerial()
        var show = root.phoneTab && !root.resizing && !root.searching
        a += " --above " + (root.inPanel ? 1 : 0) + " --borderless 1 --min " + (show ? 0 : 1)
        ps(a)
        if (show && root.inPanel && root.popupFocused) ps("raise")
    }
    function releaseMirror() { ps("release " + root.claimName) }
    function lockPhone()   { ps("lock" + serialArg()) }
    function unlockPhone() { ps("unlock" + serialArg()) }
    function toggleLock() {
        if (root.displayLocked) { root.pendingLock = false; pendingClear.restart(); unlockPhone() }
        else { root.pendingLock = true; pendingClear.restart(); lockPhone() }
    }
    function volUp()   { ps("volume up" + serialArg()) }
    function volDown() { ps("volume down" + serialArg()) }
    function navKey(k) { ps("nav " + k + serialArg()) }
    function popOut()  { ps("window" + serialArg()) }
    function selectDevice(serial) { ctl("select " + (serial || "auto")) }
    signal tabRequested(int index)
    function openTab(index) { tabRequested(index) }
    Timer { id: pendingClear; interval: 10000; onTriggered: root.pendingLock = null }
    Connections {
        target: mirror
        function onLockedChanged() {
            if (root.pendingLock !== null && mirror.locked === root.pendingLock) root.pendingLock = null
        }
    }

    onMirrorWantedChanged: {
        if (root.mirrorWanted) { claimMirror(); if (root.phoneTab && root.inPanel) unlockPhone() }
        else { releaseMirror() }
    }
    onCurrentTabChanged: {
        if (!root.mirrorWanted) return
        claimMirror()
        if (root.phoneTab && root.inPanel) unlockPhone()
    }
    onSearchingChanged: claimMirror()
    Timer {
        interval: root.inPanel ? 500 : 1000; repeat: true; running: root.mirrorWanted
        triggeredOnStart: true
        onTriggered: root.claimMirror()
    }
    hideOnWindowDeactivate: false

    readonly property var tabModel: [
        { key: "phone", label: i18n("Phone"), icon: "smartphone" },
        { key: "camera", label: i18n("Webcam"), icon: "camera-web" },
        { key: "settings", label: i18n("Settings"), icon: "configure" }
    ]
    readonly property var lensOptions: [
        { label: i18n("Back"), value: "back" }, { label: i18n("Front"), value: "front" },
        { label: i18n("External"), value: "external" }
    ]
    readonly property var resOptions: [
        { label: "2160p · 4K", value: "2160" }, { label: "1440p", value: "1440" },
        { label: "1080p", value: "1080" }, { label: "720p", value: "720" },
        { label: "480p", value: "480" }
    ]
    readonly property var arOptions: [
        { label: "16:9", value: "16:9" }, { label: "4:3", value: "4:3" },
        { label: "3:2", value: "3:2" }, { label: "1:1", value: "1:1" }
    ]
    readonly property var fpsOptions: [
        { label: "60", value: 60 }, { label: "30", value: 30 },
        { label: "24", value: 24 }, { label: "15", value: 15 }
    ]
    readonly property var rotOptions: [
        { label: i18n("Landscape"), value: "@0" },
        { label: i18n("Portrait (90°)"), value: "@90" },
        { label: i18n("Upside-down"), value: "@180" },
        { label: i18n("Portrait (270°)"), value: "@270" },
        { label: i18n("Mirror"), value: "flip0" }
    ]
    readonly property var modeOptions: [
        { label: i18n("Clone screen"), value: "clone" }, { label: i18n("Extended display"), value: "extended" }
    ]
    readonly property var orientOptions: [
        { label: i18n("Portrait"), value: "portrait" }, { label: i18n("Landscape"), value: "landscape" },
        { label: i18n("Auto-rotate"), value: "auto" }
    ]
    readonly property var tetherOptions: [
        { label: "RNDIS", value: "rndis" }, { label: "NCM", value: "ncm" }
    ]

    readonly property var cameraFields: [
        { section: i18n("Camera"), label: i18n("Lens"), kind: "choice", options: lensOptions, keywords: "facing front back external",
          get: () => root.s.facing || "back", set: v => { root.setting("facing", v); root.applyGeom() } },
        { section: i18n("Camera"), label: i18n("Resolution"), kind: "choice", options: resOptions, keywords: "quality 4k 1080p 720p",
          get: () => root.s.resolution || "", set: v => { root.setting("resolution", root.quoted(v)); root.applyGeom() } },
        { section: i18n("Camera"), label: i18n("Aspect ratio"), kind: "choice", options: arOptions, keywords: "16:9 4:3 crop",
          get: () => root.s.aspect_ratio || "16:9", set: v => { root.setting("aspect_ratio", root.quoted(v)); root.applyGeom() } },
        { section: i18n("Camera"), label: i18n("Frame rate"), kind: "choice", options: fpsOptions, keywords: "fps",
          get: () => root.s.fps || 0, set: v => root.setting("fps", v) },
        { section: i18n("Camera"), label: i18n("Rotation"), kind: "choice", options: rotOptions, keywords: "orientation portrait landscape flip",
          get: () => root.s.rotation || "@0", set: v => { root.setting("rotation", root.quoted(v)); root.applyGeom() } },
        { section: i18n("Camera"), label: i18n("Zoom"), kind: "slider", from: 1.0, to: maxZoom, keywords: "magnify",
          get: () => root.s.zoom || 1.0, set: v => root.setting("zoom", v.toFixed(1)) },
        { section: i18n("Camera"), label: i18n("Torch"), kind: "toggle", hint: i18n("Turn on the phone's flashlight"), keywords: "flash light",
          get: () => root.s.torch === true, set: v => root.setting("torch", root.onOff(v)) },
        { section: i18n("Camera"), label: i18n("Hi-speed"), kind: "toggle", hint: i18n("High frame rate capture mode"), keywords: "high speed slow motion",
          get: () => root.s.high_speed === true, set: v => root.setting("high_speed", root.onOff(v)) }
    ]

    readonly property var deviceFields: {
        feed.activeSerial
        return [
            { section: i18n("Device"), label: i18n("Name"), kind: "text", keywords: "rename label",
              get: () => root.devVal("name", ""), set: v => root.devSet("name", root.quoted(v)) },
            { section: i18n("Device"), label: i18n("Manage this phone"), kind: "toggle", hint: i18n("Let the daemon connect and mirror it"), keywords: "enable disable",
              get: () => root.devVal("enabled", true) === true, set: v => root.devSet("enabled", root.onOff(v)) },
            { section: i18n("Device"), label: i18n("Auto-unlock"), kind: "toggle", hint: i18n("Unlock with the PIN when the mirror opens"), keywords: "unlock pin",
              get: () => root.devVal("unlock", true) === true, set: v => root.devSet("unlock", root.onOff(v)) },
            { section: i18n("Device"), label: i18n("Lock PIN"), kind: "password", placeholder: i18n("for auto-unlock"), keywords: "password code unlock",
              get: () => root.devVal("lock_pin", ""), set: v => root.devSet("lock_pin", root.quoted(v)) },
            { section: i18n("Connection"), label: i18n("Wireless ADB on plug"), kind: "toggle", hint: i18n("Switch to Wi-Fi debugging when plugged in"), keywords: "wifi tcpip adb",
              get: () => root.devVal("enable_tcpip", true) === true, set: v => root.devSet("enable_tcpip", root.onOff(v)) },
            { section: i18n("Connection"), label: i18n("Wireless ADB port"), kind: "number", from: 1024, to: 65535, keywords: "tcpip port wifi adb",
              get: () => root.devVal("tcpip_port", 5555), set: v => root.devSet("tcpip_port", v) },
            { section: i18n("Connection"), label: i18n("USB tether failover"), kind: "toggle", hint: i18n("Use the phone's connection when the network drops"), keywords: "internet hotspot network",
              get: () => root.devVal("tether_failover", false) === true, set: v => root.devSet("tether_failover", root.onOff(v)) },
            { section: i18n("Connection"), label: i18n("Tether mode"), kind: "choice", options: tetherOptions, keywords: "rndis ncm usb network",
              get: () => root.devVal("tether_function", "rndis"), set: v => root.devSet("tether_function", v) },
            { section: i18n("Mirror"), label: i18n("Blank phone screen"), kind: "toggle", hint: i18n("Turn the phone's display off while mirroring"), keywords: "screen off display",
              get: () => root.devVal("screen_off", true) === true, set: v => root.devSet("screen_off", root.onOff(v)) },
            { section: i18n("Mirror"), label: i18n("Keep awake on USB"), kind: "toggle", hint: i18n("Stop the phone sleeping while plugged in"), keywords: "stay awake sleep",
              get: () => root.devVal("stay_awake", false) === true, set: v => root.devSet("stay_awake", root.onOff(v)) },
            { section: i18n("Mirror"), label: i18n("Mirror mode"), kind: "choice", options: modeOptions, keywords: "clone extended display",
              get: () => root.devVal("mode", "clone"), set: v => root.devSet("mode", v) },
            { section: i18n("Mirror"), label: i18n("Mirror rotation"), kind: "choice", options: orientOptions, keywords: "orientation portrait landscape auto rotate",
              get: () => root.devVal("orientation", "portrait"), set: v => root.devSet("orientation", v) },
            { section: i18n("Mirror"), label: i18n("Extended launcher"), kind: "text", placeholder: i18n("launcher package (optional)"), keywords: "extended display home app",
              get: () => root.devVal("display_launcher", ""), set: v => root.devSet("display_launcher", root.quoted(v)) },
            { section: i18n("Mirror"), label: i18n("Samsung DeX on external"), kind: "toggle", hint: i18n("Start DeX on the extended display"), keywords: "dex desktop samsung",
              get: () => root.devVal("dex_desktop_mode", false) === true, set: v => root.devSet("dex_desktop_mode", root.onOff(v)) },
            { section: i18n("Mirror"), label: i18n("Mirror scrcpy args"), kind: "text", placeholder: i18n("e.g. --turn-screen-off"), keywords: "scrcpy arguments flags options",
              get: () => (root.devVal("scrcpy_args", []) || []).join(" "), set: v => root.devSet("scrcpy_args", root.quoted(v)) },
            { section: i18n("Notifications"), label: i18n("Notifications"), kind: "toggle", hint: i18n("Desktop notifications for connect and disconnect"), keywords: "notify alerts",
              get: () => root.devVal("notify", false) === true, set: v => root.devSet("notify", root.onOff(v)) },
            { section: i18n("Notifications"), label: i18n("KDE Connect notify"), kind: "toggle", hint: i18n("Send notifications through KDE Connect"), keywords: "kdeconnect",
              get: () => root.devVal("kdeconnect_notify", false) === true, set: v => root.devSet("kdeconnect_notify", root.onOff(v)) }
        ]
    }

    compactRepresentation: CompactView {}
    fullRepresentation: FullView {}
}
