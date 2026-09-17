#!/bin/bash
set -e

REPO_DIR=$(pwd)
PLASMA_SERVICE="plasma-plasmashell.service"
PLASMA_OVERRIDE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$PLASMA_SERVICE.d"
PLASMA_OVERRIDE="$PLASMA_OVERRIDE_DIR/linux-android-daemon.conf"
if [ ! -f "$REPO_DIR/src/daemon.py" ]; then
    echo "Please run this script from the repository directory."
    exit 1
fi
source "$REPO_DIR/packaging/lib.sh"

AUR=false
SYSTEM_UPDATE=false
SYSTEM_UPDATE_ROOT=false
INSTALL_USER="$(id -un)"
VIDEO_NR=9
[[ ${LINUX_ANDROID_DAEMON_AUR:-} == @(1|true|yes) ]] && AUR=true
while [ $# -gt 0 ]; do
    case "$1" in
    --aur) AUR=true ;;
    --system-update) SYSTEM_UPDATE=true ;;
    --system-update-root) SYSTEM_UPDATE_ROOT=true ;;
    --owner) INSTALL_USER="$2"; shift ;;
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
    pacman -Qq v4l2loopback-dkms >/dev/null 2>&1 || return 0
    echo "Writing /etc/modprobe.d + /etc/modules-load.d for the 'Phone Camera' device..."
    root_run tee /etc/modprobe.d/linux-phonecam.conf >/dev/null <<EOF
# Android-Daemon :: phone webcam sink.
# exclusive_caps=0 keeps the device always visible so apps can select it while
# idle (selecting/opening it is what wakes the on-demand feed).
options v4l2loopback video_nr=$VIDEO_NR card_label="Phone Camera" exclusive_caps=0 max_width=4096 max_height=4096
EOF
    echo v4l2loopback | root_run tee /etc/modules-load.d/linux-phonecam.conf >/dev/null
    if [ -z "$(python3 -c "import sys;sys.path.insert(0,'$REPO_DIR/src');from core import camera as c;print(c.loopback_devnode($VIDEO_NR) or '')" 2>/dev/null)" ]; then
        root_run modprobe -r v4l2loopback 2>/dev/null || true
        root_run modprobe v4l2loopback || echo "  ! modprobe v4l2loopback failed (a reboot will load it from modules-load.d)"
    fi
}

configure_uinput() {
    lsmod | grep -q '^uinput' || root_run modprobe uinput 2>/dev/null || echo "  ! could not load uinput"
    echo uinput | root_run tee /etc/modules-load.d/uinput.conf >/dev/null 2>&1 || true
    root_run tee /etc/udev/rules.d/99-uinput-ydotool.rules >/dev/null 2>&1 <<'EOF' || true
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
    root_run udevadm control --reload-rules 2>/dev/null && root_run udevadm trigger 2>/dev/null || true
    if ! id -nG "$INSTALL_USER" | grep -qw input; then
        root_run usermod -aG input "$INSTALL_USER" 2>/dev/null \
            && echo "  added $INSTALL_USER to the 'input' group; log out and in once for it to take effect" || true
    fi
}

if $SYSTEM_UPDATE_ROOT; then
    [ "$EUID" -eq 0 ] || { echo "--system-update-root runs from the pacman hook"; exit 1; }
    configure_camera_module
    configure_uinput
    exit 0
fi

configure_plasma_local_file_access() {
    if [ -L "$PLASMA_OVERRIDE" ]; then
        echo "Error: refusing to overwrite symbolic link $PLASMA_OVERRIDE" >&2
        exit 1
    fi
    mkdir -p "$PLASMA_OVERRIDE_DIR" "$HOME/.config/environment.d"
    printf '[Service]\nEnvironment=QML_XHR_ALLOW_FILE_READ=1\n' > "$PLASMA_OVERRIDE"
    chmod 0644 "$PLASMA_OVERRIDE"
    printf 'QML_XHR_ALLOW_FILE_READ=1\n' > "$HOME/.config/environment.d/linux-android-daemon.conf"
    systemctl --user set-environment QML_XHR_ALLOW_FILE_READ=1 2>/dev/null || true
    systemctl --user daemon-reload
    echo "Enabled local file access for managed Plasma sessions."
}

# Install the tools the daemon shells out to (official repos: pacman).
#   adb  -> android-tools     scrcpy -> scrcpy     preview/feed -> ffmpeg
# (v4l2loopback for the virtual webcam is installed in the Phone Camera step below.)
if ! $SYSTEM_UPDATE; then
echo "Checking dependencies..."
deps=()
pacman -Qq android-tools >/dev/null 2>&1 || deps+=(android-tools)
pacman -Qq scrcpy        >/dev/null 2>&1 || deps+=(scrcpy)
pacman -Qq ffmpeg        >/dev/null 2>&1 || deps+=(ffmpeg)
if [ ${#deps[@]} -gt 0 ]; then
    echo "Installing: ${deps[*]} (needs sudo)..."
    sudo pacman -S --needed "${deps[@]}" || \
        echo "  ! could not install ${deps[*]} — install them manually before using the service"
else
    echo "  base dependencies present (adb, scrcpy, ffmpeg)."
fi
fi

# Generate the local (git-ignored) config from the template on first install.
# It holds per-device settings and the optional lock PIN, so it never goes in git.
if [ ! -f "$REPO_DIR/config.json" ]; then
    cp "$REPO_DIR/config.example.json" "$REPO_DIR/config.json"
    echo "Created config.json from config.example.json."
    echo "  -> To auto-unlock, set \"lock_pin\" in config.json (it is git-ignored)."
fi

echo "Setting up systemd user service..."
mkdir -p ~/.config/systemd/user

cat <<EOF > ~/.config/systemd/user/linux-android-adb.service
[Unit]
Description=Android-Daemon adb server
After=graphical-session.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/adb -L tcp:5037 kill-server
ExecStart=/usr/bin/adb -L tcp:5037 server nodaemon
ExecStop=/usr/bin/adb -L tcp:5037 kill-server
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
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $REPO_DIR/src/daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$REPO_DIR/src

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

# 1. v4l2loopback (the virtual camera kernel module) from the official repos
if ! $SYSTEM_UPDATE && ! pacman -Qq v4l2loopback-dkms >/dev/null 2>&1; then
    echo "Installing v4l2loopback-dkms + utils (needs sudo)..."
    sudo pacman -S --needed v4l2loopback-dkms v4l2loopback-utils || \
        echo "  ! could not install v4l2loopback; the webcam won't work until it is installed"
fi

# 2. Make the loopback device persistent and named, created on boot
$SYSTEM_UPDATE || configure_camera_module

# 3. phonecamctl + phonescreenctl onto PATH (symlinked back to the repo)
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
chmod +x "$REPO_DIR/bin/phonecamctl" "$REPO_DIR/bin/phonescreenctl"
ln -sf "$REPO_DIR/bin/phonecamctl" "$BIN_DIR/phonecamctl"
ln -sf "$REPO_DIR/bin/phonescreenctl" "$BIN_DIR/phonescreenctl"
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
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $REPO_DIR/src/camera_daemon.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=$REPO_DIR/src

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now linux-phonecam.service >/dev/null 2>&1 \
    && echo "Enabled linux-phonecam.service" \
    || echo "  ! could not enable linux-phonecam.service — enable it manually"

# 6. install the plasmoids (tray Phone Camera + desktop Phone Screen)
if [ ! -e "$REPO_DIR/shared/common/FileWatcher.qml" ]; then
    echo "  ! shared/common (Plasma-Shared submodule) is empty." >&2
    echo "    Run: git submodule update --init --recursive" >&2
    exit 1
fi
if command -v kpackagetool6 >/dev/null 2>&1; then
    echo "Installing the Plasma widgets..."
    for d in "$REPO_DIR"/plasmoids/org.devl0rd.phonecam "$REPO_DIR"/plasmoids/org.devl0rd.phonescreen; do
        id=$(basename "$d")
        rm -f "$d/contents/ui/FileWatcher.qml"
        mkdir -p "$d/contents/ui/lib"
        cp "$REPO_DIR/shared/common/"*.qml "$REPO_DIR/shared/common/"*.js "$REPO_DIR/shared/lib/"* "$d/contents/ui/lib/"
        if kpackagetool6 -t Plasma/Applet -u "$d" >/dev/null 2>&1; then
            echo "  upgraded $id"
        else
            kpackagetool6 -t Plasma/Applet -i "$d" >/dev/null 2>&1 \
                && echo "  installed $id" \
                || echo "  ! applet install failed — run: kpackagetool6 -t Plasma/Applet -i $d"
        fi
    done
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
echo "Setting up ydotool + kdotool (Phone Screen: panel-off after unlock)..."
if ! $SYSTEM_UPDATE; then
    if ! command -v ydotool >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm ydotool 2>/dev/null \
            || echo "  ! could not install ydotool (panel-off-after-unlock will be skipped)"
    fi
    if ! command -v kdotool >/dev/null 2>&1; then
        if command -v paru >/dev/null 2>&1; then
            paru -S --needed --noconfirm kdotool 2>/dev/null \
                || echo "  ! could not install kdotool from the AUR (panel-off-after-unlock will be skipped)"
        else
            echo "  ! paru not found; install 'kdotool' from the AUR for panel-off-after-unlock"
        fi
    fi
    configure_uinput
fi
# ydotoold user daemon (owns the socket ydotool talks to)
if command -v ydotoold >/dev/null 2>&1; then
    cat > "$HOME/.config/systemd/user/ydotoold.service" <<EOF
[Unit]
Description=ydotool daemon (virtual input for Phone Screen)
After=graphical-session.target

[Service]
ExecStart=/usr/bin/ydotoold --socket-path=%t/.ydotool_socket --socket-own=$(id -u):$(id -g)
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    echo "YDOTOOL_SOCKET=\"$XDG_RUNTIME_DIR/.ydotool_socket\"" > "$HOME/.config/environment.d/ydotool.conf"
    systemctl --user set-environment YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" 2>/dev/null || true
    systemctl --user daemon-reload || true
    systemctl --user enable --now ydotoold.service 2>/dev/null \
        && echo "  ydotoold running" \
        || echo "  ! could not start ydotoold — run: systemctl --user enable --now ydotoold.service"
fi

# The daemon now owns the Phone Screen pinned mirror, so it needs the graphical
# session env (KWin minimize, xprop fullscreen, ydotool screen-off). Import those
# into the user manager and restart the daemon so it inherits them.
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY YDOTOOL_SOCKET QML_XHR_ALLOW_FILE_READ 2>/dev/null || true
systemctl --user restart linux-android-daemon.service 2>/dev/null || true

if $SYSTEM_UPDATE; then
    notify_updated "The phone daemon and its widgets are up to date. Restart Plasma or log out and back in to load the updated widgets."
    exit 0
fi
register_system_updates "$REPO_DIR" "$AUR"

echo ""
echo "Done!"
echo "  Screen mirror : plug in over USB (wireless adb + scrcpy), or the 'Phone' shortcut."
echo "  Webcam        : add the 'Phone Camera' widget to your system tray / panel."
echo "                  It connects the phone only when an app uses the camera"
echo "                  (or while the popup is open), and follows USB<->WiFi live."
echo "  Desktop screen: add the 'Phone Screen' widget directly to your desktop."
echo "                  Press Show to pin the real (interactive) scrcpy mirror over"
echo "                  it; it stays connected and auto-picks USB/Wi-Fi."
echo "  Edit config.json to tweak per-phone behavior; camera settings live under \"camera\"."
echo "  Logs: journalctl --user -u linux-android-daemon.service -u linux-phonecam.service -f"

echo "Restarting Plasma…"
systemctl --user restart "$PLASMA_SERVICE"
