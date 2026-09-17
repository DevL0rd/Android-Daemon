import socket
import subprocess
import threading
import time

from core import camera as cam
from core.adb_monitor import AdbMonitor


class ReachabilityWatcher:
    def __init__(self):
        self._lock = threading.Lock()
        self._state = {}
        self._usb = None
        self._wake = threading.Event()

    def start(self):
        for target in (self._probe_loop, self._track_devices, self._dbus_loop):
            threading.Thread(target=target, daemon=True).start()
        self._wake.set()

    def reachable(self, target):
        with self._lock:
            known = target in self._state
            value = self._state.get(target, False)
        if not known:
            self._wake.set()
        return value

    def _set(self, target, value):
        with self._lock:
            previous = self._state.get(target)
            self._state[target] = value
        if previous != value:
            print("[reachability] %s %s" % (target, "reachable" if value else "unreachable"))

    @staticmethod
    def _targets():
        cfg = cam.load_config()
        defaults = cfg.get("defaults", {})
        targets = set()
        for device in cfg.get("devices", {}).values():
            ip = device.get("last_ip") or defaults.get("last_ip", "")
            if ip:
                port = device.get("tcpip_port") or defaults.get("tcpip_port", 5555)
                targets.add("%s:%s" % (ip, port))
        return targets

    def _probe_loop(self):
        while True:
            self._wake.wait()
            self._wake.clear()
            for target in self._targets():
                self._set(target, cam.wifi_reachable(target))

    def _track_devices(self):
        while True:
            try:
                stream = socket.create_connection(AdbMonitor.ADB_HOST, timeout=10)
            except ConnectionRefusedError:
                if subprocess.run(["adb", "start-server"], capture_output=True, timeout=10).returncode != 0:
                    print("[reachability] adb start-server failed")
                    time.sleep(1)
                continue
            except OSError as e:
                print("[reachability] adb server unavailable: %s" % e)
                time.sleep(1)
                continue
            try:
                stream.settimeout(None)
                request = "host:track-devices-l"
                stream.sendall(("%04x%s" % (len(request), request)).encode())
                if stream.recv(4) != b"OKAY":
                    raise OSError("adb refused track-devices")
                while True:
                    header = AdbMonitor._recvall(stream, 4)
                    if header is None:
                        break
                    size = int(header, 16)
                    payload = AdbMonitor._recvall(stream, size) if size else b""
                    if payload is None:
                        break
                    self._on_devices(payload.decode(errors="replace"))
            except OSError as e:
                print("[reachability] adb device stream closed: %s" % e)
            finally:
                stream.close()
            self._usb = None
            time.sleep(1)

    def _on_devices(self, payload):
        usb = set()
        wifi = set()
        for line in payload.splitlines():
            parts = line.split()
            if len(parts) < 2 or parts[1] != "device":
                continue
            if "usb:" in line:
                usb.add(parts[0])
            else:
                wifi.add(parts[0])
        for target in self._targets():
            if target in wifi:
                self._set(target, True)
            else:
                with self._lock:
                    was = self._state.get(target)
                if was:
                    self._set(target, False)
        if usb != self._usb:
            self._usb = usb
            self._wake.set()

    def _dbus_loop(self):
        from gi.repository import Gio, GLib

        context = GLib.MainContext.new()
        context.push_thread_default()
        wake = lambda *args: self._wake.set()
        session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        session.signal_subscribe(None, "org.kde.kdeconnect.device", "reachableChanged", None, None,
                                 Gio.DBusSignalFlags.NONE, wake)
        system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        system.signal_subscribe("org.freedesktop.NetworkManager", "org.freedesktop.NetworkManager",
                                "StateChanged", "/org/freedesktop/NetworkManager", None,
                                Gio.DBusSignalFlags.NONE, wake)
        GLib.MainLoop(context).run()


_watcher = None
_watcher_lock = threading.Lock()


def watcher():
    global _watcher
    with _watcher_lock:
        if _watcher is None:
            _watcher = ReachabilityWatcher()
            _watcher.start()
        return _watcher
