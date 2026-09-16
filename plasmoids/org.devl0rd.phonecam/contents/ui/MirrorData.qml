import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "lib"

Item {
    id: root

    property bool active: true

    property string status: "off"
    property bool running: false
    property bool locked: false
    property string link: ""
    property int phoneW: 9
    property int phoneH: 19

    property string cachePath: ""
    property string lastText: ""

    P5Support.DataSource {
        id: helper
        engine: "executable"
        onNewData: function(source, d) { root.cachePath = (d.stdout || "").trim(); disconnectSource(source); root.read() }
    }

    onActiveChanged: if (active) read()

    function read() {
        if (!root.cachePath || !root.active) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.responseText === root.lastText) return
            root.lastText = xhr.responseText
            if (!xhr.responseText) { root.status = "off"; root.running = false; root.locked = false; root.link = ""; return }
            try {
                var p = JSON.parse(xhr.responseText)
                root.status = p.status || "off"
                root.running = p.running === true
                root.locked = p.locked === true
                root.link = p.link || ""
                if (p.width > 0 && p.height > 0) { root.phoneW = p.width; root.phoneH = p.height }
            } catch (e) {}
        }
        xhr.send()
    }

    FileWatcher { path: root.active ? root.cachePath : ""; onChanged: root.read() }

    Component.onCompleted: helper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Android-Daemon/phonescreen.json\"")
}
