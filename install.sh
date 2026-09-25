#!/bin/bash
set -e

SOURCE_DIR="${LINUX_ANDROID_DAEMON_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SUPPORT_DIR="${LINUX_ANDROID_DAEMON_SUPPORT:-$SOURCE_DIR/packaging}"
PLASMA_SERVICE="plasma-plasmashell.service"
PLASMA_OVERRIDE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$PLASMA_SERVICE.d"
PLASMA_OVERRIDE="$PLASMA_OVERRIDE_DIR/linux-android-daemon.conf"
if [ ! -f "$SOURCE_DIR/src/daemon.py" ]; then
    echo "Please run install.sh from the Android-Daemon repository."
    exit 1
fi
source "$SUPPORT_DIR/lib.sh"
PATH="$HOME/.local/bin:$PATH:/usr/sbin:/sbin"

AUR=false
SYSTEM_UPDATE=false
SYSTEM_UPDATE_ROOT=false
VIDEO_NR=9
UINPUT_RULE="/etc/udev/rules.d/70-linux-android-daemon-uinput.rules"
ENVIRONMENT_FILE="$HOME/.config/environment.d/linux-android-daemon.conf"
YDOTOOL_ENVIRONMENT_FILE="$HOME/.config/environment.d/ydotool.conf"
SERVICE_PATH="%h/.local/bin:/usr/local/bin:/usr/bin:/bin"
[[ ${LINUX_ANDROID_DAEMON_AUR:-} == @(1|true|yes) ]] && AUR=true
while [ $# -gt 0 ]; do
    case "$1" in
    --aur) AUR=true ;;
    --system-update) SYSTEM_UPDATE=true ;;
    --system-update-root) SYSTEM_UPDATE_ROOT=true ;;
    --owner) shift ;;
    -h|--help)
        echo "Usage: ./install.sh [--aur]"
        echo "Installs the daemon and widgets and, for a git checkout on a pacman system, updates them with every system update."
        echo "  --aur  Installed by a package (also LINUX_ANDROID_DAEMON_AUR=true); no update hook is registered."
        exit 0
        ;;
    *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

root_run() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

configure_camera_module() {
    modinfo v4l2loopback >/dev/null 2>&1 || return 0
    echo "Writing /etc/modprobe.d + /etc/modules-load.d for the 'Phone Camera' device..."
    root_run tee /etc/modprobe.d/linux-phonecam.conf >/dev/null <<EOF
# Android-Daemon :: phone webcam sink.
# exclusive_caps=0 keeps the device always visible so apps can select it while
# idle (selecting/opening it is what wakes the on-demand feed).
options v4l2loopback video_nr=$VIDEO_NR card_label="Phone Camera" exclusive_caps=0 max_width=4096 max_height=4096
EOF
    echo v4l2loopback | root_run tee /etc/modules-load.d/linux-phonecam.conf >/dev/null
    if [ -z "$(python3 -B -c "import sys;sys.path.insert(0,sys.argv[1]);from core import camera as c;print(c.loopback_devnode($VIDEO_NR) or '')" "$SOURCE_DIR/src" 2>/dev/null)" ]; then
        root_run modprobe -r v4l2loopback 2>/dev/null || true
        root_run modprobe v4l2loopback || echo "  ! modprobe v4l2loopback failed (a reboot will load it from modules-load.d)"
    fi
}

remove_legacy_uinput_setup() {
    if [ "$(cat /etc/modules-load.d/uinput.conf 2>/dev/null)" = uinput ]; then
        root_run rm -f /etc/modules-load.d/uinput.conf
    fi
    if grep -qx 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' /etc/udev/rules.d/99-uinput-ydotool.rules 2>/dev/null; then
        root_run rm -f /etc/udev/rules.d/99-uinput-ydotool.rules
    fi
}

configure_uinput() {
    command -v ydotoold >/dev/null 2>&1 || return 0
    remove_legacy_uinput_setup
    printf '%s\n' 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' \
        | root_run install -Dm644 /dev/stdin "$UINPUT_RULE"
    lsmod | grep -q '^uinput' || root_run modprobe uinput 2>/dev/null || echo "  ! could not load uinput"
    root_run udevadm control --reload-rules 2>/dev/null && root_run udevadm trigger --sysname-match=uinput 2>/dev/null || true
}

if $SYSTEM_UPDATE_ROOT; then
    [ "$EUID" -eq 0 ] || { echo "--system-update-root runs from the pacman hook"; exit 1; }
    install_update_hook "$SOURCE_DIR"
    configure_camera_module
    configure_uinput
    exit 0
fi

configure_plasma_local_file_access() {
    if [ -L "$PLASMA_OVERRIDE" ]; then
        echo "Error: refusing to overwrite symbolic link $PLASMA_OVERRIDE" >&2
        exit 1
    fi
    set_session_env QML_XHR_ALLOW_FILE_READ 1 "$ENVIRONMENT_FILE"
    mkdir -p "$PLASMA_OVERRIDE_DIR" "$(dirname "$ENVIRONMENT_FILE")"
    printf '[Service]\nEnvironment=QML_XHR_ALLOW_FILE_READ=1\n' > "$PLASMA_OVERRIDE"
    chmod 0644 "$PLASMA_OVERRIDE"
    printf 'QML_XHR_ALLOW_FILE_READ=1\n' > "$ENVIRONMENT_FILE"
    systemctl --user daemon-reload
    echo "Enabled local file access for managed Plasma sessions."
}

if ! $SYSTEM_UPDATE; then
    echo "Installing dependencies..."
    "$SOURCE_DIR/packaging/dependencies.sh"
fi
ADB_BIN=$(command -v adb) || { echo "adb is missing; install it and run ./install.sh again." >&2; exit 1; }
PYTHON_BIN=$(command -v python3) || { echo "python3 is missing; install it and run ./install.sh again." >&2; exit 1; }

systemctl --user stop linux-android-daemon.service linux-phonecam.service 2>/dev/null || true
remove_legacy_checkout_files "$SOURCE_DIR"
setup_config "$SOURCE_DIR"
install_runtime "$SOURCE_DIR"

echo "Setting up systemd user service..."
mkdir -p ~/.config/systemd/user

cat <<EOF > ~/.config/systemd/user/linux-android-adb.service
[Unit]
Description=Android-Daemon adb server
After=graphical-session.target

[Service]
Type=simple
ExecStartPre=-$ADB_BIN -L tcp:5037 kill-server
ExecStart=$ADB_BIN -L tcp:5037 server nodaemon
ExecStop=$ADB_BIN -L tcp:5037 kill-server
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

cat <<EOF > ~/.config/systemd/user/linux-android-daemon.service
[Unit]
Description=Android-Daemon (wireless ADB + scrcpy + USB tethering failover)
Wants=linux-android-adb.service
After=graphical-session.target linux-android-adb.service

[Service]
Type=simple
ExecStart=$PYTHON_BIN $APP_DIR/src/daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$APP_DIR/src
Environment=PATH=$SERVICE_PATH

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now linux-android-adb.service
systemctl --user enable --now linux-android-daemon.service

# ===========================================================================
# Phone-as-webcam: v4l2loopback "Phone Camera" + on-demand daemon + tray applet
# This part needs root (kernel module) and reloads Plasma at the end. It is
# guarded so a hiccup here never undoes the screen-mirror daemon set up above.
# ===========================================================================
echo ""
echo "Setting up the Phone Camera (virtual webcam)..."

# 2. Make the loopback device persistent and named, created on boot
$SYSTEM_UPDATE || configure_camera_module

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sfn "$APP_DIR/bin/phonecamctl" "$BIN_DIR/phonecamctl"
ln -sfn "$APP_DIR/bin/phonescreenctl" "$BIN_DIR/phonescreenctl"
echo "Linked phonecamctl + phonescreenctl into $BIN_DIR"

# 4. let the applet read the tmpfs status snapshot in-process via QML XHR
configure_plasma_local_file_access

# 5. the on-demand camera daemon (separate service; does NOT auto-launch on plug-in)
cat <<EOF > ~/.config/systemd/user/linux-phonecam.service
[Unit]
Description=Android-Daemon phone webcam (on-demand camera feed)
Wants=linux-android-adb.service
After=graphical-session.target linux-android-adb.service

[Service]
Type=simple
ExecStart=$PYTHON_BIN $APP_DIR/src/camera_daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$APP_DIR/src
Environment=PATH=$SERVICE_PATH

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable linux-phonecam.service >/dev/null 2>&1 && systemctl --user restart linux-phonecam.service \
    && echo "Enabled linux-phonecam.service" \
    || echo "  ! could not enable linux-phonecam.service — enable it manually"

# 6. install the plasmoids (tray Phone Camera + desktop Phone Screen)
if [ ! -e "$SOURCE_DIR/shared/common/FileWatcher.qml" ]; then
    echo "  ! shared/common (Plasma-Shared submodule) is empty." >&2
    echo "    Run: git submodule update --init --recursive" >&2
    exit 1
fi
if command -v kpackagetool6 >/dev/null 2>&1; then
    echo "Installing the Plasma widgets..."
    PLASMOID_STAGE=$(mktemp -d)
    trap 'rm -rf "$PLASMOID_STAGE"' EXIT
    for id in org.devl0rd.phonecam org.devl0rd.phonescreen; do
        d="$PLASMOID_STAGE/$id"
        cp -r "$SOURCE_DIR/plasmoids/$id" "$d"
        mkdir -p "$d/contents/ui/lib"
        cp "$SOURCE_DIR/shared/common/"*.qml "$SOURCE_DIR/shared/common/"*.js "$SOURCE_DIR/shared/lib/"* "$d/contents/ui/lib/"
        if kpackagetool6 -t Plasma/Applet -u "$d" >/dev/null 2>&1; then
            echo "  upgraded $id"
        else
            kpackagetool6 -t Plasma/Applet -i "$d" >/dev/null 2>&1 \
                && echo "  installed $id" \
                || echo "  ! applet install failed for $id — run ./install.sh again"
        fi
    done
    rm -rf "$PLASMOID_STAGE"
else
    echo "  ! kpackagetool6 not found — install the applets manually from plasmoids/"
fi

# 7. "Turn the phone panel off after an in-widget unlock" for Phone Screen.
#    Unlocking wakes the phone's panel; to put it back to sleep WITHOUT reopening
#    scrcpy we press scrcpy's MOD+o shortcut, which needs to inject a key into the
#    (native-Wayland) mirror window. That takes ydotool (uinput key injection) +
#    kdotool (focus the window on KWin). All optional — skipped if it can't be set
#    up, and the only cost is the panel staying on after unlock.
echo ""
echo "Setting up ydotool (Phone Screen: panel-off after unlock)..."
$SYSTEM_UPDATE || configure_uinput
# ydotoold user daemon (owns the socket ydotool talks to)
if YDOTOOLD_BIN=$(command -v ydotoold); then
    cat > "$HOME/.config/systemd/user/ydotoold.service" <<EOF
[Unit]
Description=ydotool daemon (virtual input for Phone Screen)
After=graphical-session.target

[Service]
ExecStart=$YDOTOOLD_BIN --socket-path=%t/.ydotool_socket --socket-own=$(id -u):$(id -g)
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    set_session_env YDOTOOL_SOCKET "$XDG_RUNTIME_DIR/.ydotool_socket" "$YDOTOOL_ENVIRONMENT_FILE"
    echo "YDOTOOL_SOCKET=\"$XDG_RUNTIME_DIR/.ydotool_socket\"" > "$YDOTOOL_ENVIRONMENT_FILE"
    systemctl --user daemon-reload || true
    systemctl --user enable --now ydotoold.service 2>/dev/null \
        && echo "  ydotoold running" \
        || echo "  ! could not start ydotoold — run: systemctl --user enable --now ydotoold.service"
fi

# The daemon now owns the Phone Screen pinned mirror, so it needs the graphical
# session env (KWin minimize, xprop fullscreen, ydotool screen-off). Import those
# into the user manager and restart the daemon so it inherits them.
for name in DISPLAY WAYLAND_DISPLAY; do
    [ -n "${!name:-}" ] && set_session_env "$name" "${!name}"
done
systemctl --user restart linux-android-daemon.service 2>/dev/null || true

if $SYSTEM_UPDATE; then
    [ -e "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UPDATE_UNIT" ] && install_update_unit "$SOURCE_DIR" "$SOURCE_DIR"
    notify_updated "The phone daemon and its widgets are up to date. Restart Plasma or log out and back in to load the updated widgets."
    exit 0
fi
register_system_updates "$SOURCE_DIR" "$AUR"

echo ""
echo "Done!"
echo "  Screen mirror : plug in over USB (wireless adb + scrcpy), or the 'Phone' shortcut."
echo "  Webcam        : add the 'Phone Camera' widget to your system tray / panel."
echo "                  It connects the phone only when an app uses the camera"
echo "                  (or while the popup is open), and follows USB<->WiFi live."
echo "  Desktop screen: add the 'Phone Screen' widget directly to your desktop."
echo "                  Press Show to pin the real (interactive) scrcpy mirror over"
echo "                  it; it stays connected and auto-picks USB/Wi-Fi."
echo "  Edit $APP_CONFIG_FILE to tweak per-phone behavior; camera settings live under \"camera\"."
echo "  Logs: journalctl --user -u linux-android-daemon.service -u linux-phonecam.service -f"

echo "Restarting Plasma…"
systemctl --user restart "$PLASMA_SERVICE"
