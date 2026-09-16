import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "lib"

Item {
    id: root

    property bool ready: false
    property bool loopback: false
    property bool streaming: false
    property string transport: ""
    property string target: ""
    property string activeSerial: ""
    property string activeName: ""
    property bool preview: false
    property string error: ""
    property string devnode: ""
    property int gen: 0
    property int pinGen: 0
    property var devices: []
    property var consumers: []
    property var settings: ({})
    property var defaults: ({})
    property var caps: ({})
    signal updated()

    property string cachePath: ""

    P5Support.DataSource {
        id: helper
        engine: "executable"
        onNewData: function(source, d) {
            root.cachePath = (d.stdout || "").trim()
            disconnectSource(source)
            root.read()
        }
    }

    function read() {
        if (!root.cachePath)
            return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (!xhr.responseText) {
                root.ready = false
                root.updated()
                return
            }
            try {
                var p = JSON.parse(xhr.responseText)
                root.loopback = p.loopback === true
                root.streaming = p.streaming === true
                root.transport = p.transport || ""
                root.target = p.target || ""
                root.activeSerial = p.active_serial || ""
                root.activeName = p.active_name || ""
                root.preview = p.preview === true
                root.error = p.error || ""
                root.devnode = p.devnode || ""
                root.gen = p.gen || 0
                root.pinGen = p.pin_gen || 0
                root.devices = p.devices || []
                root.consumers = p.consumers || []
                root.settings = p.settings || ({})
                root.defaults = p.defaults || ({})
                root.caps = p.caps || ({})
                root.ready = true
                root.updated()
            } catch (e) {}
        }
        xhr.send()
    }

    FileWatcher { path: root.cachePath; onChanged: root.read() }

    Component.onCompleted: helper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon/phonecam.json\"")
}
