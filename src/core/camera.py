import os
import re
import json
import subprocess

REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_PATH = os.path.join(REPO_DIR, "config.json")

RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "Linux-Android-Daemon")
STATUS_PATH = os.path.join(RUNTIME_DIR, "phonecam.json")
PREVIEW_HEARTBEAT = os.path.join(RUNTIME_DIR, "phonecam_preview")
PROBE_REQUEST = os.path.join(RUNTIME_DIR, "phonecam_probe")
CAPS_PATH = os.path.join(RUNTIME_DIR, "phonecam_caps.json")
SIZES_PATH = os.path.join(RUNTIME_DIR, "phonecam_sizes.json")
PREVIEW_JPG = os.path.join(RUNTIME_DIR, "preview.jpg")

FALLBACK_SIZES = [(3840, 2160), (2560, 1440), (1920, 1440), (1920, 1080),
                  (1440, 1080), (1280, 720), (1088, 1088), (960, 720),
                  (720, 720), (640, 480), (640, 360), (352, 288), (320, 240)]

CARD_LABEL = "Phone Camera"

OUTPUT_FOURCC = "YU12"
DEFAULT_RESOLUTION = "1280x720"

CAMERA_DEFAULTS = {
    "active_serial": "",
    "video_nr": 9,
    "facing": "back",
    "camera_id": "",
    "resolution": "2160",
    "fps": 60,
    "aspect_ratio": "16:9",
    "zoom": 1.0,
    "rotation": "@0",
    "high_speed": False,
    "torch": False,
    "extra_args": [],
}


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    cfg.setdefault("defaults", {})
    cfg.setdefault("devices", {})
    cfg.setdefault("camera", {})
    return cfg


def save_config(cfg):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=4)
    os.replace(tmp, CONFIG_PATH)


def camera_settings(cfg):
    s = dict(CAMERA_DEFAULTS)
    s.update(cfg.get("camera", {}) or {})
    return s


def adb(target, *args, timeout=10, capture=False):
    cmd = ["adb"]
    if target:
        cmd += ["-s", target]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=capture, text=True, timeout=timeout)


ADB_SERVER = ("127.0.0.1", 5037)


def _adb_read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise OSError("adb server closed the connection")
        data += chunk
    return data


def _adb_server_once(request, transport, timeout):
    import socket
    with socket.create_connection(ADB_SERVER, timeout=timeout) as sock:
        sock.settimeout(timeout)

        def send(text):
            payload = text.encode()
            sock.sendall(b"%04x" % len(payload) + payload)

        def status():
            head = _adb_read_exact(sock, 4)
            if head == b"OKAY":
                return True, b""
            if head == b"FAIL":
                return False, _adb_read_exact(sock, int(_adb_read_exact(sock, 4), 16))
            raise OSError("unexpected adb server reply %r" % head)

        if transport:
            send("host:transport:" + transport)
            ok, message = status()
            if not ok:
                return False, message
        send(request)
        ok, message = status()
        if not ok:
            return False, message
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        return True, b"".join(chunks)


def adb_server(request, transport=None, timeout=10):
    try:
        return _adb_server_once(request, transport, timeout)
    except ConnectionRefusedError:
        try:
            subprocess.run(["adb", "start-server"], capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return False, b""
        return _adb_server_once(request, transport, timeout)


def wifi_reachable(target, timeout=2):
    try:
        adb_server("host:connect:" + target, timeout=timeout)
        if adb_server("shell:true", transport=target, timeout=timeout)[0]:
            return True
    except Exception:
        pass
    try:
        adb_server("host:disconnect:" + target, timeout=4)
    except Exception:
        pass
    return False


def adb_device_lines(timeout=10):
    ok, reply = adb_server("host:devices-l", timeout=timeout)
    if not ok:
        raise OSError(reply.decode(errors="replace"))
    return reply[4:].decode(errors="replace").splitlines()


def usb_serials():
    out_map = {}
    try:
        lines = adb_device_lines()
    except Exception:
        return out_map
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2 or parts[1] != "device" or "usb:" not in line:
            continue
        model = ""
        for p in parts:
            if p.startswith("model:"):
                model = p.split(":", 1)[1].replace("_", " ")
        out_map[parts[0]] = model
    return out_map


def resolve_target(serial, cfg, usb_map=None):
    if not serial:
        return (None, "")
    if usb_map is None:
        usb_map = usb_serials()
    if serial in usb_map:
        return (serial, "usb")
    dev = cfg.get("devices", {}).get(serial, {})
    ip = dev.get("last_ip", "")
    if ip:
        port = dev.get("tcpip_port", 5555)
        return (f"{ip}:{port}", "wifi")
    return (None, "")


def pick_active_serial(settings, cfg, usb_map=None):
    if usb_map is None:
        usb_map = usb_serials()
    devices = cfg.get("devices", {})

    def enabled(s):
        return devices.get(s, {}).get("enabled", True)

    sel = settings.get("active_serial", "")
    if sel and sel in devices and enabled(sel):
        return sel
    for s in usb_map:
        if enabled(s):
            return s
    for s, d in devices.items():
        if d.get("last_ip") and enabled(s):
            return s
    return next((s for s in devices if enabled(s)), "")


def loopback_devnode(video_nr=None, label=CARD_LABEL):
    base = "/sys/class/video4linux"
    matches = []
    try:
        nodes = os.listdir(base)
    except OSError:
        return None
    for n in nodes:
        if not n.startswith("video"):
            continue
        try:
            with open(os.path.join(base, n, "name")) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == label:
            num = int(n[5:]) if n[5:].isdigit() else -1
            matches.append((num, "/dev/" + n))
    if not matches:
        return None
    if video_nr is not None:
        for num, dev in matches:
            if num == video_nr:
                return dev
    matches.sort()
    return matches[0][1]


def _comm(pid):
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def _consumers_proc_scan(devnode, exclude):
    real = os.path.realpath(devnode)
    targets = (devnode, real)
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        p = int(pid)
        if p in exclude:
            continue
        hit = False
        fddir = "/proc/%s/fd" % pid
        try:
            for fd in os.listdir(fddir):
                try:
                    link = os.readlink(os.path.join(fddir, fd))
                except OSError:
                    continue
                if link in targets:
                    hit = True
                    break
        except OSError:
            pass
        if not hit:
            try:
                with open("/proc/%s/maps" % pid) as f:
                    for line in f:
                        if devnode in line or real in line:
                            hit = True
                            break
            except OSError:
                pass
        if hit:
            found.append({"pid": p, "name": _comm(p)})
    return found


def device_consumers(devnode, exclude_pids=()):
    exclude = set(exclude_pids)
    try:
        out = subprocess.run(["fuser", devnode], capture_output=True, text=True, timeout=5)
        blob = (out.stdout or "") + " " + (out.stderr or "")
    except FileNotFoundError:
        return _consumers_proc_scan(devnode, exclude)
    except Exception:
        return []
    pids = set()
    for tok in blob.split():
        m = re.match(r"(\d+)", tok)
        if m:
            pids.add(int(m.group(1)))
    return [{"pid": p, "name": _comm(p)} for p in sorted(pids) if p not in exclude]


def _holds_device(pid, targets):
    fddir = "/proc/%d/fd" % pid
    try:
        for fd in os.listdir(fddir):
            try:
                if os.readlink(os.path.join(fddir, fd)) in targets:
                    return True
            except OSError:
                continue
    except OSError:
        return False
    try:
        with open("/proc/%d/maps" % pid) as f:
            for line in f:
                if any(target in line for target in targets):
                    return True
    except OSError:
        pass
    return False


class ConsumerWatch:

    IN_OPEN = 0x20
    IN_CLOSE = 0x08 | 0x10
    IN_NONBLOCK = 0o4000
    IN_CLOEXEC = 0o2000000

    def __init__(self):
        import ctypes
        self._libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self._fd = self._libc.inotify_init1(self.IN_NONBLOCK | self.IN_CLOEXEC)
        if self._fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self._wd = -1
        self._devnode = None
        self._known = []
        self._scan_due = True

    def _watch(self, devnode):
        if devnode == self._devnode and self._wd >= 0:
            return
        if self._wd >= 0:
            self._libc.inotify_rm_watch(self._fd, self._wd)
        self._wd = self._libc.inotify_add_watch(self._fd, devnode.encode(), self.IN_OPEN | self.IN_CLOSE)
        self._devnode = devnode
        self._scan_due = True

    def _drain(self):
        import struct
        opens = closes = 0
        while True:
            try:
                data = os.read(self._fd, 4096)
            except BlockingIOError:
                return opens > closes
            except OSError:
                self._wd = -1
                return True
            if not data:
                return opens > closes
            offset = 0
            while offset + 16 <= len(data):
                _, mask, _, length = struct.unpack_from("iIII", data, offset)
                if mask & self.IN_OPEN:
                    opens += 1
                if mask & self.IN_CLOSE:
                    closes += 1
                offset += 16 + length

    def consumers(self, devnode, exclude_pids=()):
        exclude = set(exclude_pids)
        self._watch(devnode)
        if self._drain() or self._wd < 0:
            self._scan_due = True
        if not self._scan_due:
            targets = (devnode, os.path.realpath(devnode))
            known = [c for c in self._known if c["pid"] not in exclude]
            if all(_holds_device(c["pid"], targets) for c in known):
                return known
        self._scan_due = False
        self._known = device_consumers(devnode, exclude)
        return self._known


ASPECT_RATIOS = {"16:9": (16, 9), "4:3": (4, 3), "1:1": (1, 1), "3:2": (3, 2)}

_SIZE_LINE = re.compile(r"^\s*-\s*(\d+)x(\d+)\s*$")
_CAM_HDR = re.compile(r"--camera-id=\S+\s+\((\w+)")


def parse_camera_sizes(output):
    cams, cur = {}, None
    for line in output.splitlines():
        m = _CAM_HDR.search(line)
        if m:
            cur = m.group(1)
            cams.setdefault(cur, [])
            continue
        m = _SIZE_LINE.match(line)
        if m and cur:
            cams[cur].append((int(m.group(1)), int(m.group(2))))
    return cams


def probe_camera_sizes(target, timeout=20):
    try:
        out = subprocess.run(["scrcpy", "-s", target, "--list-camera-sizes"],
                             capture_output=True, text=True, timeout=timeout)
    except Exception:
        return {}
    return parse_camera_sizes((out.stdout or "") + (out.stderr or ""))


def load_camera_sizes():
    try:
        with open(SIZES_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_camera_sizes(sizes):
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        tmp = SIZES_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sizes, f)
        os.replace(tmp, SIZES_PATH)
    except OSError:
        pass


def pick_supported_size(sizes, target_w, target_h):
    if not sizes:
        return "%dx%d" % (target_w, target_h)
    ta = target_w / float(target_h)
    tarea = target_w * target_h

    def score(s):
        w, h = s
        return (abs((w / float(h)) - ta), abs(w * h - tarea))

    w, h = min(sizes, key=score)
    return "%dx%d" % (w, h)


def effective_resolution(settings):
    r = str(settings.get("resolution", "") or "").strip().lower()
    if "x" in r:
        return r
    try:
        h = int(r)
    except ValueError:
        h = 720
    aw, ah = ASPECT_RATIOS.get(str(settings.get("aspect_ratio", "") or "16:9"), (16, 9))
    target_w = int(round(h * aw / float(ah)))

    facing = str(settings.get("facing", "back") or "back")
    sizes = load_camera_sizes().get(facing)
    sizes = [tuple(s) for s in sizes] if sizes else FALLBACK_SIZES
    return pick_supported_size(sizes, target_w, h)


def _is_portrait_rotation(settings):
    rot = str(settings.get("rotation", "") or "").lstrip("@").replace("flip", "")
    return rot in ("90", "270")


def effective_output_size(settings):
    res = effective_resolution(settings)
    if "x" not in res:
        return res
    w, h = res.split("x", 1)
    return ("%sx%s" % (h, w)) if _is_portrait_rotation(settings) else res


def pin_caps(devnode, settings):
    res = effective_output_size(settings)
    try:
        subprocess.run(["v4l2-ctl", "-d", devnode, "-c", "keep_format=0"],
                       capture_output=True, timeout=5)
        out = subprocess.run(["v4l2loopback-ctl", "set-caps", devnode,
                              "%s:%s" % (OUTPUT_FOURCC, res)],
                             capture_output=True, text=True, timeout=5)
        fmt = subprocess.run(["v4l2-ctl", "-d", devnode, "--get-fmt-video"],
                             capture_output=True, text=True, timeout=5).stdout
        w, h = res.split("x")
        return res if ("%s/%s" % (w, h)) in fmt else None
    except Exception:
        return None


def start_preview_stream(devnode, fps=15):
    try:
        fps = max(1, min(int(fps or 15), 60))
    except (TypeError, ValueError):
        fps = 15
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        return subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
             "-f", "v4l2", "-i", devnode,
             "-vf", "fps=%d,scale=360:-2" % fps,
             "-q:v", "6", "-update", "1", "-y", PREVIEW_JPG],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return None


def build_scrcpy_cmd(target, settings, devnode):
    cmd = [
        "scrcpy",
        "-s", target,
        "--video-source=camera",
        "--v4l2-sink=%s" % devnode,
        "--no-audio",
        "--no-window",
        "--no-control",
    ]
    cam_id = str(settings.get("camera_id", "") or "")
    if cam_id:
        cmd.append("--camera-id=%s" % cam_id)
    else:
        facing = str(settings.get("facing", "back") or "back")
        if facing in ("front", "back", "external"):
            cmd.append("--camera-facing=%s" % facing)
    cmd.append("--camera-size=%s" % effective_resolution(settings))
    try:
        fps = int(settings.get("fps", 0) or 0)
    except (TypeError, ValueError):
        fps = 0
    if fps > 0:
        cmd.append("--camera-fps=%d" % fps)
    try:
        zoom = float(settings.get("zoom", 1.0) or 1.0)
    except (TypeError, ValueError):
        zoom = 1.0
    if abs(zoom - 1.0) > 1e-6:
        cmd.append("--camera-zoom=%s" % ("%g" % zoom))
    rot = str(settings.get("rotation", "0") or "0")
    if rot and rot != "0":
        cmd.append("--capture-orientation=%s" % rot)
    if settings.get("high_speed"):
        cmd.append("--camera-high-speed")
    if settings.get("torch"):
        cmd.append("--camera-torch")
    for a in settings.get("extra_args", []) or []:
        cmd.append(str(a))
    return cmd


def settings_signature(settings, devnode):
    return tuple(build_scrcpy_cmd("?", settings, devnode))


_CAM_LINE = re.compile(r"--camera-id=(\S+)\s+\(([^,)]+)")


def probe_cameras(target, timeout=12):
    try:
        out = subprocess.run(
            ["scrcpy", "-s", target, "--list-cameras"],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return []
    blob = (out.stdout or "") + (out.stderr or "")
    cams = []
    for m in _CAM_LINE.finditer(blob):
        cams.append({"id": m.group(1), "facing": m.group(2).strip()})
    return cams


def load_caps():
    try:
        with open(CAPS_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_caps(caps):
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        tmp = CAPS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(caps, f)
        os.replace(tmp, CAPS_PATH)
    except OSError:
        pass
