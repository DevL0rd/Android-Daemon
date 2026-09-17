#!/usr/bin/env python3
import os
import sys
import json
import time
import signal
import threading
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from core import camera as cam
from core import reachability

POLL = 0.5
PREVIEW_TTL = 4.0
SETTINGS_DEBOUNCE = 0.5
PROBE_TTL = 30.0
SIZE_PROBE_RETRY = 30.0
STATUS_REFRESH = 30.0
CONSUMER_GRACE = 5.0
GEOM_KEYS = ("resolution", "aspect_ratio", "rotation", "facing", "camera_id")


class CameraDaemon:
    def __init__(self):
        self.proc = None
        self.preview_proc = None
        self.cur_target = None
        self.cur_transport = ""
        self.cur_sig = None
        self.cur_serial = ""
        self.pending_at = 0.0
        self.gen = 0
        self.start_time = 0.0
        self.fail_count = 0
        self.backoff_until = 0.0
        self.pinned = None
        self.pin_gen = 0
        self.geom = None
        self.last_pin_try = 0.0
        self.last_consumer_seen = 0.0
        self.consumer_watch = cam.ConsumerWatch()
        self.reachability = reachability.watcher()
        self._status_body = ""
        self._status_written = 0.0
        self.error = ""
        self.config_mtime = 0.0
        self.config = {}
        self.caps = cam.load_caps()
        self._probing = set()
        self._size_probe_failure = (None, 0.0)
        os.makedirs(cam.RUNTIME_DIR, exist_ok=True)


    def _geom_of(self, settings):
        return {k: settings.get(k) for k in GEOM_KEYS}

    def _effective(self, settings):
        s = dict(settings)
        if self.geom:
            s.update(self.geom)
        return s

    def _reload_config(self):
        try:
            mtime = os.path.getmtime(cam.CONFIG_PATH)
        except OSError:
            mtime = 0.0
        if mtime != self.config_mtime or not self.config:
            self.config = cam.load_config()
            self.config_mtime = mtime
            return True
        return False

    def _feeder_alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _feeder_pids(self):
        pids = set()
        if self._feeder_alive():
            pids.add(self.proc.pid)
        if self.preview_proc is not None and self.preview_proc.poll() is None:
            pids.add(self.preview_proc.pid)
        return pids

    def _preview_alive(self):
        return self.preview_proc is not None and self.preview_proc.poll() is None

    def _stop_preview(self):
        if self.preview_proc is None:
            return
        if self._preview_alive():
            try:
                self.preview_proc.terminate()
                try:
                    self.preview_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.preview_proc.kill()
            except Exception:
                pass
        self.preview_proc = None

    def _manage_preview(self, devnode, preview_wanted, app_using, fps):
        want = preview_wanted and self._feeder_alive() and not app_using
        if want and not self._preview_alive():
            self.preview_proc = cam.start_preview_stream(devnode, fps)
        elif not want and self._preview_alive():
            self._stop_preview()

    def _preview_active(self):
        try:
            return (time.time() - os.path.getmtime(cam.PREVIEW_HEARTBEAT)) <= PREVIEW_TTL
        except OSError:
            return False

    def _stop(self, why=""):
        if self.proc is None:
            return
        if self._feeder_alive():
            print("[feed] stopping%s (pid %s)" % ((" — " + why) if why else "", self.proc.pid))
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            except Exception:
                pass
        self.proc = None
        self.cur_target = None
        self.cur_transport = ""
        self.cur_sig = None
        self.cur_serial = ""
        self.pending_at = 0.0

    def _start(self, serial, target, transport, settings, devnode, sig):
        if transport == "wifi":
            try:
                cam.adb(None, "connect", target, timeout=10)
            except Exception:
                pass
        command = cam.build_scrcpy_cmd(target, settings, devnode)
        self.gen += 1
        print("[feed] start gen=%d (%s over %s): %s" % (self.gen, serial, transport, " ".join(command)))
        try:
            self.proc = subprocess.Popen(command,
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
            self.error = ""
        except FileNotFoundError:
            self.error = "scrcpy not found"
            self.proc = None
            return
        self.cur_target = target
        self.cur_transport = transport
        self.cur_serial = serial
        self.cur_sig = sig
        self.pending_at = 0.0
        self.start_time = time.time()

    def _maybe_probe(self, serial, target):
        if not serial or not target or serial in self.caps or serial in self._probing:
            return
        self._probing.add(serial)

        def run():
            cams = cam.probe_cameras(target)
            if cams:
                self.caps[serial] = cams
                cam.save_caps(self.caps)
                print("[probe] %s -> %s" % (serial, cams))
            self._probing.discard(serial)

        threading.Thread(target=run, daemon=True).start()

    def _maybe_probe_sizes(self, target):
        if not target or self._feeder_alive() or "sizes" in self._probing:
            return
        failed_target, failed_at = self._size_probe_failure
        if failed_target == target and time.time() - failed_at < SIZE_PROBE_RETRY:
            return
        if cam.load_camera_sizes():
            return
        self._probing.add("sizes")

        def run():
            sizes = cam.probe_camera_sizes(target)
            if sizes:
                cam.save_camera_sizes(sizes)
                self._size_probe_failure = (None, 0.0)
                print("[probe] camera sizes cached: %s" % {k: len(v) for k, v in sizes.items()})
            else:
                self._size_probe_failure = (target, time.time())
            self._probing.discard("sizes")

        threading.Thread(target=run, daemon=True).start()

    def _probe_requested(self):
        try:
            return (time.time() - os.path.getmtime(cam.PROBE_REQUEST)) <= PROBE_TTL
        except OSError:
            return False


    def _write_status(self, devnode, settings, consumers, preview, serial, target, transport):
        usb_map = cam.usb_serials()
        devices = []
        seen = set()
        for s, d in self.config.get("devices", {}).items():
            seen.add(s)
            devices.append({
                "serial": s,
                "name": d.get("name") or s,
                "usb": s in usb_map,
                "last_ip": d.get("last_ip", ""),
                "config": dict(d),
            })
        for s, model in usb_map.items():
            if s not in seen:
                devices.append({"serial": s, "name": model or s, "usb": True,
                                "last_ip": "", "config": {}})

        active_name = ""
        for d in devices:
            if d["serial"] == serial:
                active_name = d["name"]
                break

        status = {
            "ts": time.time(),
            "loopback": devnode is not None,
            "devnode": devnode or "",
            "streaming": self._feeder_alive(),
            "gen": self.gen,
            "transport": transport if self._feeder_alive() else "",
            "target": target or "",
            "active_serial": serial,
            "active_name": active_name,
            "consumers": consumers,
            "preview": preview,
            "pinned": self.pinned or "",
            "pin_gen": self.pin_gen,
            "error": self.error,
            "settings": settings,
            "devices": devices,
            "defaults": dict(self.config.get("defaults", {})),
            "caps": self.caps,
        }
        body = json.dumps({k: v for k, v in status.items() if k != "ts"}, sort_keys=True)
        now = time.monotonic()
        if body == self._status_body and now - self._status_written < STATUS_REFRESH:
            return
        try:
            tmp = cam.STATUS_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(status, f)
            os.replace(tmp, cam.STATUS_PATH)
            self._status_body = body
            self._status_written = now
        except OSError as e:
            print("[status] write failed: %s" % e)


    def run(self):
        print("Starting phone-camera daemon. Feed comes up only on demand.")
        while True:
            try:
                self._tick()
            except Exception as e:
                self.error = str(e)
                print("[loop] error: %s" % e)
            time.sleep(POLL)

    def _tick(self):
        self._reload_config()
        settings = cam.camera_settings(self.config)
        try:
            video_nr = int(settings.get("video_nr", 9))
        except (TypeError, ValueError):
            video_nr = 9
        devnode = cam.loopback_devnode(video_nr)

        if devnode is None:
            self._stop("loopback gone")
            self.error = "v4l2loopback 'Phone Camera' device not found (run install.sh)"
            self._write_status(None, settings, [], self._preview_active(), "", None, "")
            return

        if self.proc is not None and not self._feeder_alive():
            ran = time.time() - self.start_time
            self.proc = None
            self.cur_sig = None
            self.cur_target = None
            self.cur_serial = ""
            if ran < 5.0:
                self.fail_count += 1
                if self.fail_count >= 3:
                    self.backoff_until = time.time() + 15.0
                    self.error = "camera feed keeps exiting (device busy or unsupported format?)"
                    print("[feed] %d rapid failures — backing off 15s" % self.fail_count)
            else:
                self.fail_count = 0

        consumers = self.consumer_watch.consumers(devnode, exclude_pids=self._feeder_pids())
        preview = self._preview_active()
        now0 = time.time()
        if [c for c in consumers if c.get("name") != "plasmashell"]:
            self.last_consumer_seen = now0
        recent_consumer = (now0 - self.last_consumer_seen) < CONSUMER_GRACE
        want = bool(consumers) or preview or recent_consumer

        usb_map = cam.usb_serials()
        serial = cam.pick_active_serial(settings, self.config, usb_map)
        target, transport = cam.resolve_target(serial, self.config, usb_map)
        if transport == "wifi" and not self.reachability.reachable(target):
            target, transport = None, ""

        self._maybe_probe_sizes(target)
        if self._probe_requested():
            self._maybe_probe(serial, target)

        if self.geom is None and want and target:
            self.geom = self._geom_of(settings)
        eff = self._effective(settings)

        if want and target and time.time() < self.backoff_until:
            pass
        elif want and target:
            self.error = ""
            sig = cam.settings_signature(eff, devnode)
            if self.proc is None:
                self._start(serial, target, transport, eff, devnode, sig)
            elif serial != self.cur_serial or target != self.cur_target:
                print("[feed] transport/device change %s/%s -> %s/%s" %
                      (self.cur_serial, self.cur_transport, serial, transport))
                self._stop("transport swap")
                self._start(serial, target, transport, eff, devnode, sig)
            elif sig != self.cur_sig:
                now = time.time()
                if self.pending_at == 0.0:
                    self.pending_at = now + SETTINGS_DEBOUNCE
                elif now >= self.pending_at:
                    self._stop("settings change")
                    self._start(serial, target, transport, eff, devnode, sig)
            else:
                self.pending_at = 0.0
        elif want and not target:
            self.error = "no reachable phone (plug in USB or connect over WiFi)"
            self._stop("phone unreachable")
        else:
            self._stop("no consumers")
            self._stop_preview()
            self.fail_count = 0
            self.backoff_until = 0.0
            live_geom = self._geom_of(settings)
            desired = cam.effective_output_size(settings)
            now = time.time()
            if not consumers and (now - self.last_pin_try) > 1.0:
                if self.pinned != desired:
                    self.last_pin_try = now
                    res = cam.pin_caps(devnode, settings)
                    if res:
                        self.pinned = res
                        self.geom = live_geom
                        self.pin_gen += 1
                        print("[caps] pinned %s -> YU12:%s (gen %d)" % (devnode, res, self.pin_gen))
                elif self.geom != live_geom:
                    self.geom = live_geom

        self._manage_preview(devnode, preview, bool(consumers), settings.get("fps"))
        self._write_status(devnode, settings, consumers, preview, serial, target, transport)


def _term(*_):
    raise SystemExit(0)


if __name__ == "__main__":
    daemon = CameraDaemon()
    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)
    try:
        daemon.run()
    finally:
        daemon._stop("shutdown")
        daemon._stop_preview()
