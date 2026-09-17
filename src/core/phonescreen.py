import os
import re
import glob
import json
import time
import shutil
import threading
import subprocess

from core import camera as cam
from core import reachability
import scrcpy_launch as sl

TITLE_TOKEN = "PhoneScreenPinned"
KWIN_RULE_ID = "phonescreen"

RUNTIME_DIR = cam.RUNTIME_DIR
STATUS_PATH = os.path.join(RUNTIME_DIR, "phonescreen.json")
CLAIM_GLOB = os.path.join(RUNTIME_DIR, "phonescreen_claim_*.json")
WINDOW_PATH = os.path.join(RUNTIME_DIR, "phonescreen_window")
LOG_PATH = os.path.join(RUNTIME_DIR, "phonescreen.log")
LAUNCHER = os.path.join(cam.REPO_DIR, "src", "scrcpy_launch.py")

CLAIM_TTL = 5.0
WINDOW_GRACE = 20.0

_TEXTURE_RE = re.compile(r"Texture:\s*(\d+)\s*x\s*(\d+)")

_status_lock = threading.Lock()


def _runtime():
    os.makedirs(RUNTIME_DIR, exist_ok=True)


def _claim_path(name):
    return os.path.join(RUNTIME_DIR, "phonescreen_claim_%s.json" % name)


def write_claim(name, **data):
    _runtime()
    try:
        with open(_claim_path(name), "w") as f:
            json.dump(data, f)
    except OSError:
        pass


def remove_claim(name):
    try:
        os.remove(_claim_path(name))
    except OSError:
        pass


def read_claims():
    out = []
    now = time.time()
    for path in glob.glob(CLAIM_GLOB):
        try:
            if now - os.path.getmtime(path) > CLAIM_TTL:
                continue
            with open(path) as f:
                c = json.load(f)
        except (OSError, ValueError):
            continue
        c["name"] = os.path.basename(path)[len("phonescreen_claim_"):-len(".json")]
        out.append(c)
    return out


def pick_winner(claims):
    live = [c for c in claims if c.get("visible")]
    if not live:
        return None
    return max(live, key=lambda c: c.get("priority", 0))


_status_written = {"body": None}


def write_status(**kw):
    _runtime()
    body = json.dumps(kw)
    with _status_lock:
        if body == _status_written["body"] and os.path.exists(STATUS_PATH):
            return
        try:
            tmp = STATUS_PATH + ".tmp"
            with open(tmp, "w") as f:
                f.write(body)
            os.replace(tmp, STATUS_PATH)
            _status_written["body"] = body
        except OSError:
            pass


def read_status():
    try:
        with open(STATUS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def touch(path):
    _runtime()
    try:
        open(path, "w").close()
    except OSError:
        pass


def _fresh(path, ttl):
    try:
        return (time.time() - os.path.getmtime(path)) < ttl
    except OSError:
        return False


LOCKED_PATH = os.path.join(RUNTIME_DIR, "phonescreen_locked")


def set_locked(flag):
    _runtime()
    if flag:
        try:
            open(LOCKED_PATH, "w").close()
        except OSError:
            pass
    else:
        try:
            os.remove(LOCKED_PATH)
        except OSError:
            pass


def get_locked():
    return os.path.exists(LOCKED_PATH)


LOCK_PENDING_PATH = os.path.join(RUNTIME_DIR, "phonescreen_lockpending")
LOCK_PENDING_TTL = 5.0


def mark_lock_pending():
    touch(LOCK_PENDING_PATH)


def lock_pending():
    return _fresh(LOCK_PENDING_PATH, LOCK_PENDING_TTL)


WIDGET_UNLOCKED_PATH = os.path.join(RUNTIME_DIR, "phonescreen_widget_unlocked")
ROTATION_LOCKED_PATH = os.path.join(RUNTIME_DIR, "phonescreen_rotation_locked")


def _write_serial_marker(path, serial):
    _runtime()
    try:
        with open(path, "w") as f:
            f.write(serial or "")
    except OSError:
        pass


def _read_serial_marker(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _clear_marker(path):
    try:
        os.remove(path)
    except OSError:
        pass


def widget_unlocked(serial=""):
    owner = _read_serial_marker(WIDGET_UNLOCKED_PATH)
    return bool(owner) and (not serial or owner == serial)


def _effective_device_config(serial):
    cfg = cam.load_config()
    out = dict(cfg.get("defaults", {}))
    out.update(cfg.get("devices", {}).get(serial, {}))
    return out


def apply_widget_rotation_lock(serial, target):
    cfg = _effective_device_config(serial)
    mode = str(cfg.get("mode", "clone") or "clone").lower()
    orientation = str(cfg.get("orientation", "portrait") or "portrait").lower()
    if mode not in ("extended", "display", "dex") \
            and sl.lock_rotation(target, orientation):
        _write_serial_marker(ROTATION_LOCKED_PATH, serial)


def dex_requested(serial):
    cfg = _effective_device_config(serial)
    mode = str(cfg.get("mode", "clone") or "clone").lower()
    return mode in ("extended", "display", "dex") and cfg.get("dex_desktop_mode") is True


def release_widget_rotation_lock(target=""):
    serial = _read_serial_marker(ROTATION_LOCKED_PATH)
    if not serial:
        return
    sl.restore_rotation(adb_target(serial) or target)
    _clear_marker(ROTATION_LOCKED_PATH)


def phone_locked(target=""):
    release_widget_rotation_lock(target)
    _clear_marker(WIDGET_UNLOCKED_PATH)
    set_locked(True)


BLANK_REQ_PATH = os.path.join(RUNTIME_DIR, "phonescreen_blankreq")
BLANK_REQ_TTL = 8.0


def request_blank():
    touch(BLANK_REQ_PATH)


def take_blank_request():
    fresh = _fresh(BLANK_REQ_PATH, BLANK_REQ_TTL)
    try:
        os.remove(BLANK_REQ_PATH)
    except OSError:
        pass
    return fresh


def resolve_serial(serial=""):
    if serial and serial != "auto":
        return serial
    cfg = cam.load_config()
    return cam.camera_settings(cfg).get("active_serial", "") \
        or cam.pick_active_serial(cam.camera_settings(cfg), cfg) \
        or next(iter(cfg.get("devices", {})), "")


def usb_present(serial):
    if not serial:
        return False
    try:
        lines = cam.adb_device_lines(timeout=8)
    except OSError:
        return False
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == serial and parts[1] == "device" and "usb:" in line:
            return True
    return False


def last_ip(serial):
    cfg = cam.load_config()
    d = cfg.get("devices", {}).get(serial, {})
    return d.get("last_ip", "") or cfg.get("defaults", {}).get("last_ip", "")


def reachable(serial):
    if not serial:
        return False
    if usb_present(serial):
        return True
    ip = last_ip(serial)
    if not ip:
        return False
    cfg = cam.load_config()
    port = cfg.get("devices", {}).get(serial, {}).get("tcpip_port") \
        or cfg.get("defaults", {}).get("tcpip_port", 5555)
    return reachability.watcher().reachable("%s:%s" % (ip, port))


def adb_target(serial):
    if not serial:
        return serial
    if usb_present(serial):
        return serial
    ip = last_ip(serial)
    if ip:
        cfg = cam.load_config()
        port = cfg.get("devices", {}).get(serial, {}).get("tcpip_port") \
            or cfg.get("defaults", {}).get("tcpip_port", 5555)
        return "%s:%s" % (ip, port)
    return serial


def is_locked(target):
    if not target:
        return False
    try:
        return sl.is_locked(target)
    except Exception:
        return False


def lock_phone(target):
    if not target:
        return
    try:
        sl.adb(target, "shell", "input", "keyevent", "223")
    except Exception:
        pass
    phone_locked(target)


def unlock_phone(serial, target):
    request_blank()
    mark_lock_pending()
    _write_serial_marker(WIDGET_UNLOCKED_PATH, serial)
    set_locked(False)
    cfg = _effective_device_config(serial)
    pin = str(cfg.get("lock_pin", "") or "")
    sl.adb(target, "shell", "input", "keyevent", "224")
    if sl.is_locked(target) and pin:
        sl.adb(target, "shell", "input", "keyevent", "62")
        time.sleep(0.1)
        sl.adb(target, "shell", "input", "text", pin)
        sl.adb(target, "shell", "input", "keyevent", "66")
    apply_widget_rotation_lock(serial, target)


def screen_off_enabled(serial):
    cfg = cam.load_config()
    dev = cfg.get("devices", {}).get(serial, {})
    if "screen_off" in dev:
        return bool(dev["screen_off"])
    return bool(cfg.get("defaults", {}).get("screen_off", True))


def _scrcpy_pids():
    try:
        out = subprocess.run(["pgrep", "-x", "scrcpy"], capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]
    except OSError:
        return []


def _cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid) as f:
            return f.read().replace("\0", " ")
    except OSError:
        return ""


def _is_camera(cmd):
    return "--v4l2-sink" in cmd or "--video-source=camera" in cmd


def external_mirror():
    for p in _scrcpy_pids():
        c = _cmdline(p)
        if c and TITLE_TOKEN not in c and not _is_camera(c):
            return True
    return _fresh(WINDOW_PATH, WINDOW_GRACE)


_fs_cache = {"t": 0.0, "v": False}


def fullscreen_active():
    now = time.time()
    if now - _fs_cache["t"] < 1.5:
        return _fs_cache["v"]
    v = False
    try:
        out = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW"],
                             capture_output=True, text=True, timeout=4).stdout
        toks = out.strip().split()
        wid = toks[-1] if toks else ""
        if wid.startswith("0x") and int(wid, 16) != 0:
            st = subprocess.run(["xprop", "-id", wid, "_NET_WM_STATE"],
                               capture_output=True, text=True, timeout=4).stdout
            v = "_NET_WM_STATE_FULLSCREEN" in st
    except (OSError, subprocess.TimeoutExpired, ValueError):
        v = False
    _fs_cache.update(t=now, v=v)
    return v


def _kwrite(key, value):
    subprocess.run(["kwriteconfig6", "--file", "kwinrulesrc",
                    "--group", KWIN_RULE_ID, "--key", key, str(value)], capture_output=True)


def _kwrite_general(key, value):
    subprocess.run(["kwriteconfig6", "--file", "kwinrulesrc", "--group", "General",
                    "--key", key, str(value)], capture_output=True)


def _kread(group, key, default=""):
    try:
        out = subprocess.run(["kreadconfig6", "--file", "kwinrulesrc",
                              "--group", group, "--key", key],
                             capture_output=True, text=True).stdout.strip()
        return out or default
    except OSError:
        return default


def kwin_reconfigure():
    subprocess.run(["dbus-send", "--session", "--type=method_call",
                    "--dest=org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"], capture_output=True)


def _ensure_rule_listed():
    ids = [r for r in _kread("General", "rules", "").split(",") if r]
    if KWIN_RULE_ID not in ids:
        ids.append(KWIN_RULE_ID)
    _kwrite_general("rules", ",".join(ids))
    _kwrite_general("count", str(len(ids)))


def apply_window(x, y, w, h, above=False, borderless=True, minimized=False):
    _kwrite("Description", "Phone Screen (pinned by org.devl0rd.phonescreen)")
    _kwrite("title", TITLE_TOKEN)
    _kwrite("titlematch", 2)
    _kwrite("types", 1)
    _kwrite("position", "%d,%d" % (x, y))
    _kwrite("positionrule", 2)
    _kwrite("size", "%d,%d" % (w, h))
    _kwrite("sizerule", 2)
    _kwrite("noborder", "true" if borderless else "false")
    _kwrite("noborderrule", 2)
    _kwrite("above", "true" if above else "false")
    _kwrite("aboverule", 2)
    _kwrite("below", "false" if above else "true")
    _kwrite("belowrule", 2)
    _kwrite("minimize", "true" if minimized else "false")
    _kwrite("minimizerule", 2)
    _kwrite("skiptaskbar", "true")
    _kwrite("skiptaskbarrule", 2)
    _kwrite("skippager", "true")
    _kwrite("skippagerrule", 2)
    _kwrite("skipswitcher", "true")
    _kwrite("skipswitcherrule", 2)
    _ensure_rule_listed()
    kwin_reconfigure()


def set_minimized(flag):
    _kwrite("minimize", "true" if flag else "false")
    _kwrite("minimizerule", 2)
    kwin_reconfigure()


def _kwinrulesrc_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "kwinrulesrc")


def _strip_group_block(path, group):
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return
    out, skipping, header = [], False, "[%s]" % group
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            skipping = (s == header)
        if not skipping:
            out.append(line)
    try:
        with open(path, "w") as f:
            f.writelines(out)
    except OSError:
        pass


def clear_rule():
    ids = [r for r in _kread("General", "rules", "").split(",") if r and r != KWIN_RULE_ID]
    _kwrite_general("rules", ",".join(ids))
    _kwrite_general("count", str(len(ids)))
    _strip_group_block(_kwinrulesrc_path(), KWIN_RULE_ID)
    kwin_reconfigure()


def screen_off_via_scrcpy():
    if not (shutil.which("ydotool") and shutil.which("kdotool")):
        return False
    try:
        subprocess.run(["kdotool", "search", "--name", TITLE_TOKEN, "windowactivate"],
                       capture_output=True, timeout=6)
        time.sleep(0.25)
        subprocess.run(["ydotool", "key", "125:1", "24:1", "24:0", "125:0"],
                       capture_output=True, timeout=6)
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


class PinnedMirror:

    def __init__(self):
        self.proc = None
        self.serial = ""
        self.target = ""
        self.started = 0.0
        self.connected = False
        self.next_launch = 0.0
        self.applied = None
        self.no_claim_since = 0.0
        self.size_wh = (9, 19)
        self._last_status = {"visible": False, "status": "off", "running": False,
                             "locked": False, "owner": ""}
        self.persist = False
        self.last_geom = None
        self.borderless = True
        self.extra = []
        self.link = ""
        self.dex_support = {}
        subprocess.run(["pkill", "-f", TITLE_TOKEN], capture_output=True)

    def _alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _dex_blocked(self, serial):
        if not dex_requested(serial):
            return False
        if serial not in self.dex_support:
            supported = sl.dex_supported(adb_target(serial))
            if supported is None:
                return True
            self.dex_support[serial] = supported
            if not supported:
                print("[phonescreen] Samsung DeX is on for %s but the phone doesn't support it" % serial)
                sl.notify("Samsung DeX isn't available", "This phone doesn't support DeX. Turn off \"Samsung DeX on external\" in Phone Manager settings.", "dialog-error", "critical")
        return not self.dex_support[serial]

    def switch_transport(self):
        p = self.proc
        if p:
            try:
                p.terminate()
            except OSError:
                pass
        self.next_launch = 0.0

    def wants(self, serial):
        win = pick_winner(read_claims())
        if win:
            return (win.get("serial") or resolve_serial()) == serial
        return self.persist and bool(self.serial) and self.serial == serial

    def reconcile(self):
        win = pick_winner(read_claims())
        if win is None:
            if not self.persist or self.last_geom is None:
                return
            x, y, w, h, above, borderless = self.last_geom
            want_min = True
        else:
            x, y = int(win.get("x", 0)), int(win.get("y", 0))
            w, h = int(win.get("w", 400)), int(win.get("h", 800))
            above = bool(win.get("above", False))
            borderless = bool(win.get("borderless", True))
            self.last_geom = (x, y, w, h, above, borderless)
            serial = win.get("serial") or resolve_serial()
            want_min = bool(win.get("min", False)) or get_locked() \
                or not widget_unlocked(serial)
        desired = (x, y, w, h, above, borderless, want_min)
        if desired != self.applied:
            prev_min = self.applied[6] if self.applied else True
            self.applied = desired
            apply_window(x, y, w, h, above=above, borderless=borderless, minimized=want_min)
            if prev_min and not want_min and take_blank_request() and screen_off_enabled(self.serial):
                threading.Thread(target=self._screen_off_soon, daemon=True).start()

    def _screen_off_soon(self):
        time.sleep(0.4)
        if self._alive():
            screen_off_via_scrcpy()

    def _stop(self):
        if self.proc:
            try:
                self.proc.terminate()
            except OSError:
                pass
            self.proc = None
        self.connected = False
        self.applied = None

    def _launch(self, serial, borderless, extra):
        flags = ["--no-unlock", "--no-rotation-lock", "--no-power-on",
                 "--window-title", TITLE_TOKEN, "--no-audio", "--no-window-aspect-ratio-lock"]
        if borderless:
            flags.append("--window-borderless")
        flags += extra
        try:
            _runtime()
            proc = subprocess.Popen(["python3", "-u", LAUNCHER, "--auto", serial] + flags,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1)
        except OSError as e:
            print("[phonescreen] launch failed: %s" % e)
            return None
        threading.Thread(target=self._read_output, args=(proc,), daemon=True).start()
        return proc

    def _read_output(self, proc):
        try:
            with open(LOG_PATH, "a") as log:
                for line in proc.stdout:
                    log.write(line)
                    log.flush()
                    m = _TEXTURE_RE.search(line)
                    if not m or proc is not self.proc:
                        continue
                    wh = (int(m.group(1)), int(m.group(2)))
                    if wh != self.size_wh and wh[0] > 0 and wh[1] > 0:
                        self.size_wh = wh
                        self.applied = None
                        self._publish_size()
        except Exception:
            pass

    def _publish_size(self):
        w, h = self.size_wh
        write_status(width=w, height=h, link=self.link, **self._last_status)

    def _status(self, **kw):
        self._last_status = kw
        w, h = self.size_wh
        write_status(width=w, height=h, link=self.link, **kw)

    def poll_lock(self):
        if lock_pending():
            return
        if not self._alive() or not self.link:
            return
        win = pick_winner(read_claims())
        managed = widget_unlocked(self.serial)
        if (not win or bool(win.get("min", False))) and not managed:
            return
        target = self.target or adb_target(self.serial)
        if is_locked(target):
            phone_locked(target)
        elif managed:
            set_locked(False)
        else:
            set_locked(True)

    def tick(self):
        win = pick_winner(read_claims())

        ls = (win.get("serial") if win else self.serial) or resolve_serial()
        if ls and usb_present(ls):
            self.link = "usb"
        elif ls and reachable(ls):
            self.link = "wifi"
        else:
            self.link = ""

        if win is None:
            if not self.persist:
                self._status(visible=False, status="off", running=False,
                             locked=get_locked(), owner="")
                return
            if not self.no_claim_since:
                self.no_claim_since = time.time()
                lock_phone(self.target or adb_target(self.serial))
            serial = self.serial or resolve_serial()
            self.serial = serial
            if serial and reachable(serial):
                if not self._alive() and not external_mirror():
                    now = time.time()
                    if now >= self.next_launch and not self._dex_blocked(serial):
                        self.next_launch = now + 2.0
                        self.target = adb_target(serial)
                        set_minimized(True)
                        self.proc = self._launch(serial, self.borderless, self.extra)
                        self.started = now
                        self.applied = None
            elif self._alive():
                self._stop()
            self._status(visible=False, status="minimized", running=self._alive(),
                         locked=get_locked(), owner="", serial=serial)
            return
        self.no_claim_since = 0.0

        serial = win.get("serial") or resolve_serial()
        owner = win.get("name", "")
        self.serial = serial
        self.borderless = bool(win.get("borderless", True))
        self.extra = win.get("extra", []) or []
        borderless = self.borderless
        extra = self.extra

        if external_mirror():
            self._stop()
            self._status(visible=True, status="external", running=False, locked=False, serial=serial, owner=owner)
            return
        if fullscreen_active():
            self._stop()
            self._status(visible=True, status="fullscreen", running=False, locked=False, serial=serial, owner=owner)
            return
        if not serial or not reachable(serial):
            self._stop()
            self._status(visible=True, status="offline", running=False, locked=False, serial=serial, owner=owner)
            return

        if not self._alive() and self._dex_blocked(serial):
            status = "dex-unsupported" if self.dex_support.get(serial) is False else "connecting"
            self._status(visible=True, status=status, running=False, locked=False, serial=serial, owner=owner)
            return

        if not self._alive():
            now = time.time()
            if now < self.next_launch:
                self._status(visible=True, status="connecting", running=False, locked=get_locked(), serial=serial, owner=owner)
                return
            self.next_launch = now + 2.0
            self.target = adb_target(serial)
            if is_locked(self.target):
                phone_locked(self.target)
            elif widget_unlocked(serial):
                set_locked(False)
            else:
                set_locked(True)
            self.proc = self._launch(serial, borderless, extra)
            self.started = now
            self.connected = False
            self.persist = True
            self.applied = None
            self._status(visible=True, status="connecting", running=False, locked=get_locked(), serial=serial, owner=owner)
            return

        if not self.connected and time.time() - self.started > 3.0:
            self.connected = True

        self._status(visible=True, status="connected" if self.connected else "connecting",
                     running=self.connected, locked=get_locked(), serial=serial, owner=owner)
