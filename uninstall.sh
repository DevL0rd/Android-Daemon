#!/bin/bash
set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packaging/lib.sh"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_DIR="$CONFIG_DIR/systemd/user"
PLASMA_OVERRIDE_DIR="$UNIT_DIR/plasma-plasmashell.service.d"
UINPUT_RULE="/etc/udev/rules.d/70-linux-android-daemon-uinput.rules"
LEGACY_UINPUT_RULE="/etc/udev/rules.d/99-uinput-ydotool.rules"
LEGACY_UINPUT_MODULE="/etc/modules-load.d/uinput.conf"

echo "Removing the system update hook..."
unregister_system_updates

echo "Stopping and removing the systemd user services..."
for unit in linux-android-daemon.service linux-phonecam.service linux-android-adb.service ydotoold.service; do
    systemctl --user disable --now "$unit" 2>/dev/null || true
    rm -f "$UNIT_DIR/$unit"
done
rm -f "$PLASMA_OVERRIDE_DIR/linux-android-daemon.conf"
systemctl --user daemon-reload 2>/dev/null || true

echo "Removing the Phone Screen KWin rule..."
"$HOME/.local/bin/phonescreenctl" rule-clear 2>/dev/null || true

echo "Removing the ydotool helper bits (leaving the ydotool/kdotool packages)..."
rm -f "$CONFIG_DIR/environment.d/ydotool.conf"
remove_system_files=()
[ -e "$UINPUT_RULE" ] && remove_system_files+=("$UINPUT_RULE")
grep -qx 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' "$LEGACY_UINPUT_RULE" 2>/dev/null && remove_system_files+=("$LEGACY_UINPUT_RULE")
[ "$(cat "$LEGACY_UINPUT_MODULE" 2>/dev/null)" = uinput ] && remove_system_files+=("$LEGACY_UINPUT_MODULE")
if [ ${#remove_system_files[@]} -gt 0 ]; then
    update_as_root rm -f "${remove_system_files[@]}"
    update_as_root udevadm control --reload-rules 2>/dev/null || true
fi

echo "Removing phonecamctl + phonescreenctl + applets..."
rm -f "$HOME/.local/bin/phonecamctl" "$HOME/.local/bin/phonescreenctl"
rm -f "$CONFIG_DIR/environment.d/linux-android-daemon.conf"
unset_session_env
for id in org.devl0rd.phonecam org.devl0rd.phonescreen; do
    kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1 \
        && echo "  removed $id" || true
done

if [ -e /etc/modprobe.d/linux-phonecam.conf ] || [ -e /etc/modules-load.d/linux-phonecam.conf ]; then
    echo "Removing the v4l2loopback 'Phone Camera' device (needs sudo)..."
    update_as_root rm -f /etc/modprobe.d/linux-phonecam.conf /etc/modules-load.d/linux-phonecam.conf
    update_as_root modprobe -r v4l2loopback 2>/dev/null || true
fi

remove_scrcpy_release
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/Linux-Android-Daemon" "$USER_STATE_DIR"
for directory in "$CONFIG_DIR/environment.d" "$PLASMA_OVERRIDE_DIR" "$UNIT_DIR/default.target.wants" "$UNIT_DIR/graphical-session.target.wants" "$UNIT_DIR" "$CONFIG_DIR/systemd" "$HOME/.local/bin" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids" "${XDG_DATA_HOME:-$HOME/.local/share}/plasma"; do
    [ -d "$directory" ] && rmdir --ignore-fail-on-non-empty "$directory"
done

echo "  (left the system packages installed: adb, scrcpy, ffmpeg, v4l2loopback, ydotool)"
echo "  (kept config.json in the repository folder and adb's key in ~/.android that your phones trust)"

echo "Uninstallation complete!"
