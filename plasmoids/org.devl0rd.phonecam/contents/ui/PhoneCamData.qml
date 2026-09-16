import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "lib"

Item {
    id: root

    property bool active: true
    property bool detailed: true

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
    property int consumerCount: 0
    property var devices: []
    property var consumers: []
    property var settings: ({})
    property var defaults: ({})
    property var caps: ({})
    signal updated()

    property string cachePath: ""
    property string lastText: ""
    property bool lastDetailed: false

    P5Support.DataSource {
        id: helper
        engine: "executable"
        onNewData: function(source, d) {
            root.cachePath = (d.stdout || "").trim()
            disconnectSource(source)
            root.read()
        }
    }

    onActiveChanged: if (active) read()
    onDetailedChanged: if (detailed) read()

    function read() {
        if (!root.cachePath || !root.active)
            return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (!xhr.responseText) {
                root.lastText = ""
                root.ready = false
                root.updated()
                return
            }
            var text = xhr.responseText.replace(/"ts":\s*[0-9.eE+-]+,?/, "")
            if (text === root.lastText && (root.lastDetailed || !root.detailed))
                return
            try {
                var p = JSON.parse(xhr.responseText)
                root.lastText = text
                root.lastDetailed = root.detailed
                root.loopback = p.loopback === true
                root.streaming = p.streaming === true
                root.error = p.error || ""
                root.consumerCount = (p.consumers || []).length
                root.pinGen = p.pin_gen || 0
                root.activeName = p.active_name || ""
                if (root.detailed) {
                    root.transport = p.transport || ""
                    root.target = p.target || ""
                    root.activeSerial = p.active_serial || ""
                    root.preview = p.preview === true
                    root.devnode = p.devnode || ""
                    root.gen = p.gen || 0
                    root.devices = p.devices || []
                    root.consumers = p.consumers || []
                    root.settings = p.settings || ({})
                    root.defaults = p.defaults || ({})
                    root.caps = p.caps || ({})
                }
                root.ready = true
                root.updated()
            } catch (e) {}
        }
        xhr.send()
    }

    FileWatcher { path: root.active ? root.cachePath : ""; onChanged: root.read() }

    Component.onCompleted: helper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon/phonecam.json\"")
}
