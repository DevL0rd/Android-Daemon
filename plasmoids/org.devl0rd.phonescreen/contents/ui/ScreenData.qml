import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "lib"

Item {
    id: root

    property bool ready: false
    property var devices: []
    property string activeSerial: ""
    property string activeName: ""
    property string error: ""
    property string status: "off"
    property bool running: false
    property bool locked: false
    property string owner: ""
    signal updated()

    property string dir: ""
    readonly property var activeDev: {
        var devs = devices || []
        for (var i = 0; i < devs.length; i++)
            if (devs[i].serial === activeSerial) return devs[i]
        return devs.length ? devs[0] : null
    }
    readonly property bool onUsb: activeDev ? activeDev.usb === true : false
    readonly property bool hasWifi: activeDev ? (activeDev.last_ip || "") !== "" : false
    readonly property bool reachable: onUsb || hasWifi
    readonly property string transport: onUsb ? "usb" : (hasWifi ? "wifi" : "")

    P5Support.DataSource {
        id: pathHelper
        engine: "executable"
        onNewData: function(source, d) {
            root.dir = (d.stdout || "").trim()
            disconnectSource(source)
            root.read()
        }
    }

    function _get(file, cb) {
        if (!root.dir) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.dir + "/" + file)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            cb(xhr.responseText)
        }
        xhr.send()
    }

    function read() {
        _get("phonecam.json", function(txt) {
            if (!txt) { root.ready = false; root.updated(); return }
            try {
                var p = JSON.parse(txt)
                root.devices = p.devices || []
                root.activeSerial = p.active_serial || ""
                root.activeName = p.active_name || ""
                root.error = p.error || ""
                root.ready = true
            } catch (e) {}
            root.updated()
        })
        _get("phonescreen.json", function(txt) {
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
    FileWatcher { path: root.dir ? root.dir + "/phonecam.json" : ""; onChanged: root.read() }
    FileWatcher { path: root.dir ? root.dir + "/phonescreen.json" : ""; onChanged: root.read() }

    Component.onCompleted: pathHelper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon\"")
}
