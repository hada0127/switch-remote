#!/bin/sh
# Run net-watch.sh against stubs only. install.sh runs `make check` as root, so
# every command that could change the system must resolve to the stub directory
# before net-watch.sh runs; otherwise this test refuses to run it.
# Needs util-linux flock (Raspberry Pi OS).
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
stub="$root/bin"
mkdir -p "$stub"
for cmd in systemctl nmcli logger ip; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$cmd" "$root" > "$stub/$cmd"
    chmod 755 "$stub/$cmd"
done
# The gateway is unreachable.
printf '#!/bin/sh\necho "ping $*" >> "%s/calls"\nexit 1\n' "$root" > "$stub/ping"
chmod 755 "$stub/ping"
PATH="$stub:$PATH"
export PATH
for cmd in systemctl nmcli ping logger ip; do
    resolved=$(command -v "$cmd" || true)
    if [ "$resolved" != "$stub/$cmd" ]; then
        echo "FAIL $cmd resolves to '$resolved', not $stub/$cmd; refusing to run net-watch.sh" >&2
        exit 1
    fi
done
helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/net-watch.sh
export VGF_NET_STATE="$root/fails" VGF_CONTROLLER_LOCK="$root/controller.lock" VGF_UPTIME_FILE="$root/uptime"
echo '5000.00 100.00' > "$root/uptime"
: > "$root/controller.lock"
run_streak_8() {
    echo 7 > "$root/fails"
    : > "$root/calls"
    sh "$helper"
    [ "$(cat "$root/fails")" = 8 ]
    grep -q '^ping ' "$root/calls"
}

# A controller session (TLS or cable) holds its lock: no reboot.
exec 9>>"$root/controller.lock"
flock -x 9
run_streak_8
if grep -q '^systemctl reboot' "$root/calls"; then echo 'FAIL rebooted while the controller lock was held' >&2; exit 1; fi
grep -q 'skipping reboot' "$root/calls"
flock -u 9
exec 9>&-

# The lock is free: the existing reboot branch still runs.
run_streak_8
grep -q '^systemctl reboot' "$root/calls" || { echo 'FAIL no reboot with a free controller lock' >&2; exit 1; }
echo 'PASS net-watch skips reboot while a controller session holds its lock, reboots when free'
