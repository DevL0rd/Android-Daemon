#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PATH="$HOME/.local/bin:$PATH:/usr/sbin:/sbin"

ARCH_PACKAGES=(git python python-gobject android-tools scrcpy ffmpeg v4l-utils v4l2loopback-dkms psmisc procps-ng xorg-xprop libnotify glib2 dbus qt6-tools kconfig kpackage ydotool)
FEDORA_PACKAGES=(git curl python3 python3-gobject android-tools ffmpeg-free v4l-utils psmisc procps-ng xprop libnotify glib2 dbus-tools qt6-qttools kf6-kconfig kf6-kpackage ydotool kdotool)
SUSE_PACKAGES=(git python3 python3-gobject android-tools scrcpy ffmpeg v4l-utils v4l2loopback-kmp-default psmisc procps xprop libnotify-tools glib2-tools dbus-1-tools qt6-tools-qdbus kf6-kconfig kf6-kpackage ydotool)
DEBIAN_PACKAGES=(git curl python3 python3-gi adb ffmpeg v4l-utils v4l2loopback-dkms psmisc procps x11-utils libnotify-bin libglib2.0-bin dbus-bin qdbus-qt6 libkf6config-bin kpackagetool6 ydotool)
FEDORA_WEBCAM_DRIVER="akmod-v4l2loopback"
PANEL_OFF="turning the phone's screen off after unlocking it from the widget"

scrcpy_needed() {
    local scrcpy
    scrcpy=$(command -v scrcpy) || return 0
    owned_by_us "$scrcpy"
}

install_kdotool_from_aur() {
    command -v kdotool >/dev/null && return 0
    if [[ $EUID -ne 0 ]] && command -v paru >/dev/null; then
        paru -S --needed --noconfirm kdotool || echo "  ! could not install kdotool from the AUR, so $PANEL_OFF is skipped"
    else
        echo "  ! install 'kdotool' from the AUR for $PANEL_OFF"
    fi
}

check_atomic_system() {
    local missing=() packages=() features=() command feature
    local -A seen=()
    for command in python3 gdbus kpackagetool6 kwriteconfig6 kreadconfig6; do
        command -v "$command" >/dev/null || missing+=("$command")
    done
    if ((${#missing[@]})); then
        echo "This system is missing ${missing[*]}, which Android-Daemon needs and the read-only system has to provide." >&2
        exit 1
    fi
    python3 -c 'import gi' 2>/dev/null || { packages+=(python3-gobject); features+=("reconnecting the moment KDE Connect or your network changes"); }
    command -v notify-send >/dev/null || { packages+=(libnotify); features+=("desktop notifications"); }
    command -v ffmpeg >/dev/null || { packages+=(ffmpeg-free); features+=("the webcam preview"); }
    command -v v4l2-ctl >/dev/null || { packages+=(v4l-utils); features+=("the Phone Camera webcam"); }
    modinfo v4l2loopback >/dev/null 2>&1 || { packages+=("$FEDORA_WEBCAM_DRIVER"); features+=("the Phone Camera webcam"); }
    command -v fuser >/dev/null || { packages+=(psmisc); features+=("showing which app uses the webcam"); }
    command -v xprop >/dev/null || { packages+=(xprop); features+=("stepping aside for fullscreen X11 games"); }
    command -v ydotoold >/dev/null || { packages+=(ydotool); features+=("$PANEL_OFF"); }
    command -v kdotool >/dev/null || { packages+=(kdotool); features+=("$PANEL_OFF"); }
    ((${#packages[@]})) || return 0
    echo "  ! This system doesn't include what these need, so they stay off:"
    for feature in "${features[@]}"; do
        [[ -n ${seen[$feature]:-} ]] && continue
        seen[$feature]=1
        echo "      - $feature"
    done
    if [[ $ATOMIC == fedora ]]; then
        echo "    To add them, run: rpm-ostree install ${packages[*]}"
        echo "    ($FEDORA_WEBCAM_DRIVER comes from RPM Fusion), reboot and run ./install.sh again."
    fi
}

install_packages() {
    if [[ -n $ATOMIC ]]; then
        check_atomic_system
    elif command -v pacman >/dev/null; then
        update_as_root pacman -S --needed --noconfirm "${ARCH_PACKAGES[@]}"
        install_kdotool_from_aur
    elif command -v dnf >/dev/null; then
        update_as_root dnf install -y "${FEDORA_PACKAGES[@]}"
        if dnf -q info "$FEDORA_WEBCAM_DRIVER" >/dev/null 2>&1; then
            update_as_root dnf install -y "$FEDORA_WEBCAM_DRIVER"
        else
            echo "  ! the Phone Camera webcam needs $FEDORA_WEBCAM_DRIVER from RPM Fusion: enable RPM Fusion and run ./install.sh again"
        fi
    elif command -v zypper >/dev/null; then
        update_as_root zypper --non-interactive install "${SUSE_PACKAGES[@]}"
        command -v kdotool >/dev/null || echo "  ! kdotool isn't packaged for openSUSE, so $PANEL_OFF is skipped"
    elif command -v apt-get >/dev/null; then
        update_as_root apt-get install -y "${DEBIAN_PACKAGES[@]}"
        command -v kdotool >/dev/null || echo "  ! kdotool isn't packaged for Debian, so $PANEL_OFF is skipped"
    else
        echo "Unsupported package manager: install adb, scrcpy, ffmpeg, v4l2loopback, ydotool and kdotool yourself, then run ./install.sh again." >&2
        exit 1
    fi
}

install_packages
if scrcpy_needed; then
    install_scrcpy_release
fi
