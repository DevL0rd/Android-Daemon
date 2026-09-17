import time
import queue
import socket
import threading
import subprocess


class AdbMonitor:

    ADB_HOST = ("127.0.0.1", 5037)

    def __init__(self, on_connect, on_disconnect):
        self.on_connect = on_connect
        self.on_disconnect = on_disconnect
        self.active = {}
        self.events = queue.Queue()

    def start(self):
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._worker, daemon=True).start()


    def _worker(self):
        while True:
            kind, serial, model = self.events.get()
            try:
                if kind == "connect":
                    self.on_connect(serial, model)
                else:
                    self.on_disconnect(serial)
            except Exception:
                pass


    def _open_stream(self):
        s = socket.create_connection(self.ADB_HOST, timeout=10)
        s.settimeout(None)
        cmd = "host:track-devices-l"
        s.sendall(("%04x%s" % (len(cmd), cmd)).encode())
        if s.recv(4) != b"OKAY":
            s.close()
            raise OSError("adb refused track-devices")
        return s

    @staticmethod
    def _recvall(s, n):
        buf = b""
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def _read_msg(self, s):
        hdr = self._recvall(s, 4)
        if hdr is None:
            return None
        n = int(hdr, 16)
        if n == 0:
            return ""
        data = self._recvall(s, n)
        return None if data is None else data.decode()

    def _reader(self):
        while True:
            s = None
            try:
                subprocess.run(["adb", "start-server"], capture_output=True, timeout=10)
                s = self._open_stream()
                while True:
                    msg = self._read_msg(s)
                    if msg is None:
                        break
                    self._diff(self._parse(msg))
            except FileNotFoundError:
                print("[AdbMonitor] 'adb' not found in PATH.")
                return
            except Exception:
                pass
            finally:
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass
            time.sleep(1)


    @staticmethod
    def _parse(payload):
        devices = {}
        for line in payload.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            serial = parts[0]
            state = parts[1] if len(parts) > 1 else ""
            if state != "device" or "usb:" not in line:
                continue
            model = ""
            for p in parts:
                if p.startswith("model:"):
                    model = p.split(":", 1)[1].replace("_", " ")
            devices[serial] = model
        return devices

    def _diff(self, current):
        for serial, model in current.items():
            if serial not in self.active:
                self.active[serial] = model
                self.events.put(("connect", serial, model))
        for serial in list(self.active):
            if serial not in current:
                self.active.pop(serial, None)
                self.events.put(("disconnect", serial, None))
