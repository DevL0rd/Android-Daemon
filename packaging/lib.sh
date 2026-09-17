#!/usr/bin/env bash

UPDATE_ID="linux-android-daemon"
UPDATE_TITLE="Linux Android Daemon"
UPDATE_UNIT="$UPDATE_ID-update.service"
UPDATE_HOOK="/etc/pacman.d/hooks/$UPDATE_ID-update.hook"
UPDATE_STATE_DIR="/var/lib/$UPDATE_ID"
UPDATE_PENDING="$HOME/.local/state/$UPDATE_ID/update-pending"

update_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

register_system_updates() {
    local checkout="$1" aur="$2"
    if [[ $aur == true ]] || ! command -v pacman >/dev/null || ! git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
        unregister_system_updates
        return 0
    fi
    echo "Registering $UPDATE_TITLE with system updates..."
    update_as_root install -Dm755 "$checkout/packaging/system-update" "/usr/lib/$UPDATE_ID/system-update"
    update_as_root install -Dm644 "$checkout/packaging/$UPDATE_ID-update.hook" "$UPDATE_HOOK"
    printf '%s\n%s\n' "$checkout" "$(id -un)" | update_as_root install -Dm644 /dev/stdin "$UPDATE_STATE_DIR/source"
    local units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$units"
    sed "s|@CHECKOUT@|$checkout|g" "$checkout/packaging/$UPDATE_ID-update.service.in" >"$units/$UPDATE_UNIT"
    systemctl --user daemon-reload
    systemctl --user enable "$UPDATE_UNIT" >/dev/null 2>&1
}

unregister_system_updates() {
    if [[ -e $UPDATE_HOOK || -e $UPDATE_STATE_DIR || -e /usr/lib/$UPDATE_ID ]]; then
        update_as_root rm -rf "$UPDATE_HOOK" "$UPDATE_STATE_DIR" "/usr/lib/$UPDATE_ID"
    fi
    local unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UPDATE_UNIT"
    if [[ -e $unit ]]; then
        systemctl --user disable "$UPDATE_UNIT" >/dev/null 2>&1 || true
        rm -f "$unit"
        systemctl --user daemon-reload
    fi
    rm -f "$UPDATE_PENDING"
}

notify_updated() {
    rm -f "$UPDATE_PENDING"
    gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify "$UPDATE_TITLE" 0 system-software-update "$UPDATE_TITLE updated" "$1" '[]' '{}' 10000 >/dev/null 2>&1 || true
}
