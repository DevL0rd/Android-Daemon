function describe(state) {
    if (state.resizing)
        return { key: "resizing", icon: "transform-scale", text: i18n("Resizing…"), detail: i18n("Release to pin the mirror at the new size"), tone: "neutral", busy: false }
    if (!state.ready)
        return { key: "nodaemon", icon: "dialog-error", text: i18n("Daemon not running"), detail: i18n("Start linux-android-daemon to mirror your phone"), tone: "negative", busy: false }
    if (state.elsewhere)
        return { key: "elsewhere", icon: "window-duplicate", text: i18n("In the Phone Manager"), detail: i18n("The mirror comes back here when the popup closes"), tone: "accent", busy: false }
    if (state.status === "external")
        return { key: "external", icon: "window", text: i18n("In another window"), detail: i18n("Close the pop-out window to bring it back"), tone: "accent", busy: false }
    if (state.status === "fullscreen")
        return { key: "fullscreen", icon: "view-fullscreen", text: i18n("Fullscreen"), detail: i18n("Leave fullscreen to bring it back"), tone: "accent", busy: false }
    if (state.status === "dex-unsupported")
        return { key: "dex", icon: "dialog-error", text: i18n("DeX isn't available"), detail: i18n("Turn off Samsung DeX on external in settings"), tone: "negative", busy: false }
    if (state.status === "offline" || !state.reachable)
        return { key: "offline", icon: "network-disconnect", text: i18n("Phone offline"), detail: i18n("Plug in USB or connect over Wi-Fi"), tone: "negative", busy: false }
    if (state.locked)
        return { key: "locked", icon: "object-locked", text: i18n("Locked"), detail: i18n("Double-click to unlock"), tone: "neutral", busy: false }
    if (state.status === "connected")
        return { key: "live", icon: "video-display", text: i18n("Live"), detail: "", tone: "positive", busy: false }
    return { key: "connecting", icon: "smartphone", text: i18n("Connecting…"), detail: i18n("Starting the mirror"), tone: "neutral", busy: true }
}

function toneColor(tone, theme) {
    if (tone === "positive") return theme.positiveTextColor
    if (tone === "negative") return theme.negativeTextColor
    if (tone === "neutral") return theme.neutralTextColor
    return theme.highlightColor
}

function linkText(link) {
    if (link === "usb") return i18n("USB")
    if (link === "wifi") return i18n("Wi-Fi")
    return i18n("Offline")
}

function linkIcon(link) {
    if (link === "usb") return "drive-removable-media-usb"
    if (link === "wifi") return "network-wireless"
    return "network-disconnect"
}
