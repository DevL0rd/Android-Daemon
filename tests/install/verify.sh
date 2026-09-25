#!/usr/bin/env bash
set -uo pipefail

failed=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo "ok: $1"
    else
        echo "FAILED: $1"
        failed=1
    fi
}

for service in linux-android-adb linux-android-daemon linux-phonecam; do
    check "$service.service runs" "systemctl --user is-active $service.service"
    check "$service.service is enabled" "systemctl --user is-enabled $service.service"
done
check "ydotoold.service is enabled" "systemctl --user is-enabled ydotoold.service"
check "the adb server answers" "adb -L tcp:5037 devices"
check "the webcam daemon writes its status" "python3 -c 'import json, sys; json.load(open(sys.argv[1]))' $XDG_RUNTIME_DIR/Linux-Android-Daemon/phonecam.json"
check "phonecamctl runs" "$HOME/.local/bin/phonecamctl state | python3 -c 'import json, sys; json.load(sys.stdin)'"
check "phonescreenctl runs" "$HOME/.local/bin/phonescreenctl state | python3 -c 'import json, sys; json.load(sys.stdin)'"
for widget in org.devl0rd.phonecam org.devl0rd.phonescreen; do
    check "the $widget widget is installed" "kpackagetool6 -t Plasma/Applet --show $widget"
done
check "Plasma may read the status files" "systemctl --user show-environment | grep -qx QML_XHR_ALLOW_FILE_READ=1"
check "the system update hook is registered" "test -f /usr/share/libalpm/hooks/linux-android-daemon-update.hook"
check "the update service is enabled" "systemctl --user is-enabled linux-android-daemon-update.service"
check "Plasma runs" "systemctl --user is-active plasma-plasmashell.service"
errors=$(journalctl --user -u linux-android-daemon -u linux-phonecam --no-pager -o cat | grep -A3 Traceback)
check "the daemons logged no Python errors" "[[ -z \"\$errors\" ]]"
[[ -n $errors ]] && echo "$errors"
exit "$failed"
