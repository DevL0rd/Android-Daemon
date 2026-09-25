#!/usr/bin/env bash
set -uo pipefail

checkout="$1"
config="${XDG_CONFIG_HOME:-$HOME/.config}/Linux-Android-Daemon/config.json"
app="${XDG_DATA_HOME:-$HOME/.local/share}/linux-android-daemon/app"
failed=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo "ok: $1"
    else
        echo "FAILED: $1"
        failed=1
    fi
}

check "the old config.json left the checkout" "[[ ! -e $checkout/config.json ]]"
check "the old config.json moved to $config" "python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))[\"test_marker\"] == \"legacy\"' $config"
check "the config is private" "[[ \$(stat -c %a $config) == 600 ]]"
check "the daemons are installed in $app" "[[ -f $app/src/daemon.py && -f $app/src/camera_daemon.py && -x $app/bin/phonecamctl && -x $app/bin/phonescreenctl ]]"
check "the updater is installed" "[[ -x /usr/lib/linux-android-daemon/install && -f /usr/lib/linux-android-daemon/lib.sh && -x /usr/lib/linux-android-daemon/system-update ]]"
check "the update source is recorded" "[[ \$(head -n1 /var/lib/linux-android-daemon/source) == $checkout ]]"
references=$(grep -rsF "$checkout" "$HOME/.config/systemd/user" "$HOME/.config/environment.d" "$HOME/.local/bin" "$app" "$HOME/.local/share/plasma/plasmoids" /usr/lib/linux-android-daemon \
    | grep -v 'LINUX_ANDROID_DAEMON_SOURCE=')
links=$(find "$HOME/.local/bin" -maxdepth 1 -type l -lname "$checkout/*")
check "nothing installed points into the checkout" "[[ -z \"\$references\" && -z \"\$links\" ]]"
[[ -n $references ]] && echo "$references"
[[ -n $links ]] && echo "$links"
leftovers=$(git -C "$checkout" status --ignored --porcelain)
check "installing left no files in the checkout" "[[ -z \"\$leftovers\" ]]"
[[ -n $leftovers ]] && echo "$leftovers"
exit "$failed"
