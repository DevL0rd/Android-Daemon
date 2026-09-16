import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "lib"

Item {
    id: root

    property bool active: true

    property bool ready: false
    property string activeSerial: ""
    property string activeName: ""
    property string error: ""
    property bool onUsb: false
    property string lastIp: ""
    property string status: "off"
    property bool running: false
    property bool locked: false
    property string owner: ""
    signal updated()

    readonly property bool hasWifi: lastIp !== ""
    readonly property bool reachable: onUsb || hasWifi
    readonly property string transport: onUsb ? "usb" : (hasWifi ? "wifi" : "")

    property string dir: ""
    property string camText: ""
    property string screenText: ""

    P5Support.DataSource {
        id: pathHelper
        engine: "executable"
        onNewData: function(source, d) {
            root.dir = (d.stdout || "").trim()
            disconnectSource(source)
            root.readCam()
            root.readScreen()
        }
    }

    onActiveChanged: if (active) { readCam(); readScreen() }

    function _get(file, cb) {
        if (!root.dir || !root.active) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.dir + "/" + file)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            cb(xhr.responseText)
        }
        xhr.send()
    }

    function readCam() {
        _get("phonecam.json", function(txt) {
            var text = txt.replace(/"ts":\s*[0-9.eE+-]+,?/, "")
            if (text === root.camText) return
            root.camText = text
            if (!txt) { root.ready = false; root.updated(); return }
            try {
                var p = JSON.parse(txt)
                var devs = p.devices || []
                var serial = p.active_serial || ""
                var dev = devs.length ? devs[0] : null
                for (var i = 0; i < devs.length; i++)
                    if (devs[i].serial === serial) dev = devs[i]
                root.activeSerial = serial
                root.activeName = p.active_name || ""
                root.error = p.error || ""
                root.onUsb = dev ? dev.usb === true : false
                root.lastIp = dev ? (dev.last_ip || "") : ""
                root.ready = true
            } catch (e) {}
            root.updated()
        })
    }

    function readScreen() {
        _get("phonescreen.json", function(txt) {
            if (txt === root.screenText) return
            root.screenText = txt
            if (!txt) { root.status = "off"; root.running = false; return }
            try {
                var p = JSON.parse(txt)
                root.status = p.status || "off"
                root.running = p.running === true
                root.locked = p.locked === true
                root.owner = p.owner || ""
            } catch (e) {}
        })
    }

    FileWatcher { path: root.active && root.dir ? root.dir + "/phonecam.json" : ""; onChanged: root.readCam() }
    FileWatcher { path: root.active && root.dir ? root.dir + "/phonescreen.json" : ""; onChanged: root.readScreen() }

    Component.onCompleted: pathHelper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon\"")
}
