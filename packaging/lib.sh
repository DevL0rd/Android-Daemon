#!/usr/bin/env bash

UPDATE_ID="linux-android-daemon"
UPDATE_TITLE="Linux Android Daemon"
UPDATE_UNIT="$UPDATE_ID-update.service"
UPDATE_HOOK="/usr/share/libalpm/hooks/$UPDATE_ID-update.hook"
UPDATE_LEGACY_HOOK="/etc/pacman.d/hooks/$UPDATE_ID-update.hook"
UPDATE_STATE_DIR="/var/lib/$UPDATE_ID"
UPDATER_DIR="/usr/lib/$UPDATE_ID"
UPDATE_PENDING="$HOME/.local/state/$UPDATE_ID/update-pending"
USER_STATE_DIR="$HOME/.local/state/$UPDATE_ID"
USER_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$UPDATE_ID"
APP_DIR="$USER_DATA_DIR/app"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Linux-Android-Daemon"
APP_CONFIG_FILE="$APP_CONFIG_DIR/config.json"
SESSION_ENV_FILE="$USER_STATE_DIR/session-env"
SCRCPY_VERSION="4.1"
SCRCPY_SHA256="ad56ae8bfeedf41e824945c11dbf55fcb092b3e615b9b486f48a50e30d389635"
SCRCPY_DIR="$USER_DATA_DIR/scrcpy-v$SCRCPY_VERSION"

ATOMIC=""
if [[ -e /run/ostree-booted ]]; then
    ATOMIC="fedora"
elif [[ $(. /etc/os-release && printf '%s' "$ID") == steamos ]]; then
    ATOMIC="steamos"
fi

update_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_update_hook() {
    local checkout="$1"
    update_as_root install -Dm755 "$checkout/packaging/system-update" "$UPDATER_DIR/system-update"
    update_as_root install -Dm755 "$checkout/install.sh" "$UPDATER_DIR/install"
    update_as_root install -Dm644 "$checkout/packaging/lib.sh" "$UPDATER_DIR/lib.sh"
    update_as_root install -Dm644 "$checkout/packaging/$UPDATE_ID-update.hook" "$UPDATE_HOOK"
    if grep -qa 'NetworkAccess' /usr/lib/libalpm.so.*; then
        update_as_root sed -i '/^Exec = /a NetworkAccess = allowed' "$UPDATE_HOOK"
    fi
    if [[ -e $UPDATE_LEGACY_HOOK ]]; then
        update_as_root rm -f "$UPDATE_LEGACY_HOOK"
    fi
}

register_system_updates() {
    local checkout="$1" aur="$2"
    if [[ $aur == true || -n $ATOMIC ]] || ! command -v pacman >/dev/null || ! git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
        unregister_system_updates
        return 0
    fi
    echo "Registering $UPDATE_TITLE with system updates..."
    install_update_hook "$checkout"
    printf '%s\n%s\n' "$checkout" "$(id -un)" | update_as_root install -Dm644 /dev/stdin "$UPDATE_STATE_DIR/source"
    install_update_unit "$checkout"
    systemctl --user enable "$UPDATE_UNIT" >/dev/null 2>&1
}

install_update_unit() {
    local checkout="$1" units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$units"
    sed -e "s|@CHECKOUT@|$checkout|g" -e "s|@UPDATER_DIR@|$UPDATER_DIR|g" "$checkout/packaging/$UPDATE_ID-update.service.in" >"$units/$UPDATE_UNIT"
    systemctl --user daemon-reload
}

unregister_system_updates() {
    if [[ -e $UPDATE_HOOK || -e $UPDATE_LEGACY_HOOK || -e $UPDATE_STATE_DIR || -e $UPDATER_DIR ]]; then
        update_as_root rm -rf "$UPDATE_HOOK" "$UPDATE_LEGACY_HOOK" "$UPDATE_STATE_DIR" "$UPDATER_DIR"
    fi
    local unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UPDATE_UNIT"
    if [[ -e $unit ]]; then
        systemctl --user disable "$UPDATE_UNIT" >/dev/null 2>&1 || true
        rm -f "$unit"
        systemctl --user daemon-reload
    fi
    rm -f "$UPDATE_PENDING"
}

remove_legacy_checkout_files() {
    local checkout="$1" d
    [[ -w $checkout ]] || return 0
    for d in "$checkout"/plasmoids/org.devl0rd.phonecam "$checkout"/plasmoids/org.devl0rd.phonescreen; do
        rm -rf "$d/contents/ui/lib"
        rm -f "$d/contents/ui/FileWatcher.qml"
    done
    find "$checkout/bin" "$checkout/src" -name __pycache__ -type d -prune -exec rm -rf {} +
}

setup_config() {
    local checkout="$1" legacy="$1/config.json" kept
    mkdir -p "$APP_CONFIG_DIR"
    if [[ -f $legacy && -e $APP_CONFIG_FILE ]]; then
        kept="$APP_CONFIG_DIR/config.json.legacy-$(date +%Y%m%d-%H%M%S)"
        mv "$legacy" "$kept"
        chmod 0600 "$kept"
        echo "Kept your settings in $APP_CONFIG_FILE and moved the old config.json from the repository folder to $kept."
    elif [[ -f $legacy ]]; then
        mv "$legacy" "$APP_CONFIG_FILE"
        echo "Moved config.json from the repository folder to $APP_CONFIG_FILE."
    elif [[ ! -e $APP_CONFIG_FILE ]]; then
        cp "$checkout/config.example.json" "$APP_CONFIG_FILE"
        echo "Created $APP_CONFIG_FILE from config.example.json."
        echo "  -> To auto-unlock, set \"lock_pin\" in it."
    fi
    chmod 0600 "$APP_CONFIG_FILE"
}

install_runtime() {
    local checkout="$1" staging previous="$USER_DATA_DIR/.app.previous.$$"
    mkdir -p "$USER_DATA_DIR"
    staging=$(mktemp -d "$USER_DATA_DIR/.app.XXXXXX")
    cp -r "$checkout/bin" "$checkout/src" "$staging/"
    find "$staging" -name __pycache__ -type d -prune -exec rm -rf {} +
    chmod 0755 "$staging" "$staging/bin/phonecamctl" "$staging/bin/phonescreenctl"
    if [[ -e $APP_DIR ]]; then
        mv "$APP_DIR" "$previous"
    fi
    mv "$staging" "$APP_DIR"
    rm -rf "$previous"
    echo "Installed the daemons into $APP_DIR"
}

remove_runtime() {
    rm -rf "$APP_DIR" "$USER_DATA_DIR"/.app.*
}

notify_updated() {
    rm -f "$UPDATE_PENDING"
    gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify "$UPDATE_TITLE" 0 system-software-update "$UPDATE_TITLE updated" "$1" '[]' '{}' 10000 >/dev/null 2>&1 || true
}

owned_by_us() {
    [[ -L $1 && $(readlink -f "$1") == "$USER_DATA_DIR"/* ]]
}

install_scrcpy_release() {
    local bin_dir="$HOME/.local/bin" archive other
    if [[ $(uname -m) != x86_64 ]]; then
        echo "scrcpy isn't packaged for this system and its official build is for x86_64 only. Install scrcpy, then run ./install.sh again." >&2
        exit 1
    fi
    if [[ ! -x $SCRCPY_DIR/scrcpy ]]; then
        echo "Installing scrcpy $SCRCPY_VERSION from its official release into $SCRCPY_DIR..."
        archive=$(mktemp)
        if ! curl -fsSL -o "$archive" "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-linux-x86_64-v$SCRCPY_VERSION.tar.gz" \
            || ! printf '%s  %s\n' "$SCRCPY_SHA256" "$archive" | sha256sum -c --quiet; then
            rm -f "$archive"
            echo "Could not download scrcpy $SCRCPY_VERSION." >&2
            exit 1
        fi
        mkdir -p "$SCRCPY_DIR"
        tar -xzf "$archive" -C "$SCRCPY_DIR" --strip-components=1
        rm -f "$archive"
    fi
    for other in "$USER_DATA_DIR"/scrcpy-v*; do
        [[ $other == "$SCRCPY_DIR" ]] || rm -rf "$other"
    done
    mkdir -p "$bin_dir"
    ln -sfn "$SCRCPY_DIR/scrcpy" "$bin_dir/scrcpy"
    if owned_by_us "$bin_dir/adb" || ! command -v adb >/dev/null; then
        ln -sfn "$SCRCPY_DIR/adb" "$bin_dir/adb"
    fi
}

remove_scrcpy_release() {
    local link
    for link in "$HOME/.local/bin/scrcpy" "$HOME/.local/bin/adb"; do
        owned_by_us "$link" && rm -f "$link"
    done
    rm -rf "$USER_DATA_DIR"
}

set_session_env() {
    if ! systemctl --user show-environment 2>/dev/null | grep -q "^$1=" || grep -qs "^$1=" "${3:-/dev/null}"; then
        mkdir -p "$USER_STATE_DIR"
        grep -qx "$1" "$SESSION_ENV_FILE" 2>/dev/null || printf '%s\n' "$1" >>"$SESSION_ENV_FILE"
    fi
    systemctl --user set-environment "$1=$2" 2>/dev/null || true
}

unset_session_env() {
    local name
    [[ -f $SESSION_ENV_FILE ]] || return 0
    while IFS= read -r name; do
        [[ -n $name ]] && systemctl --user unset-environment "$name" 2>/dev/null
    done <"$SESSION_ENV_FILE"
    rm -f "$SESSION_ENV_FILE"
}
