#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
CONTAINER="android-daemon-install-test"
IMAGE="${ANDROID_DAEMON_TEST_IMAGE:-archlinux:latest}"

as_root() {
    docker exec "$CONTAINER" "$@"
}

as_tester() {
    docker exec -u tester -w /home/tester/Android-Daemon -e USER=tester -e LOGNAME=tester -e XDG_RUNTIME_DIR=/run/user/1000 \
        -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus -e WAYLAND_DISPLAY=wayland-0 "$CONTAINER" "$@"
}

step() {
    printf '\n==> %s\n' "$1"
}

step "Starting an Arch Linux system with Plasma"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock "$IMAGE" /usr/lib/systemd/systemd >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT
as_root pacman -Syu --noconfirm --needed plasma-desktop sudo git
as_root bash -c 'useradd -m -u 1000 tester && echo "tester ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/tester'
docker cp . "$CONTAINER:/home/tester/Android-Daemon"
docker cp tests/install/. "$CONTAINER:/opt/install-test"
as_root chown -R tester: /home/tester/Android-Daemon
as_tester git config --global --add safe.directory '*'

step "Installing Android-Daemon's dependencies"
as_tester packaging/dependencies.sh

step "Starting a Plasma session"
as_root bash -c 'loginctl enable-linger tester; for _ in $(seq 60); do [[ -S /run/user/1000/bus ]] && exit 0; sleep 1; done; exit 1'
as_tester /opt/install-test/session.sh
as_root /opt/install-test/snapshot.sh before

step "Installing Android-Daemon"
as_tester ./install.sh
sleep 15

step "Checking that the services and widgets are installed and running"
as_tester /opt/install-test/verify.sh

step "Uninstalling Android-Daemon"
as_tester ./uninstall.sh
sleep 10

step "Checking that uninstalling left the system as it was"
as_root /opt/install-test/snapshot.sh after
as_root /opt/install-test/compare.sh
