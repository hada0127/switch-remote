#!/bin/sh
# Run on Linux with util-linux flock. All paths are temporary test fixtures.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/gadget" "$root/udc/test.udc" "$root/run"
echo test.udc > "$root/gadget/UDC"
echo 'not attached' > "$root/udc/test.udc/state"
export VGF_USB_GADGET="$root/gadget" VGF_USB_UDC_ROOT="$root/udc" VGF_USB_RUN_ROOT="$root/run" VGF_USB_REBIND_DELAY=0
helper=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/usb-control.sh
# Simulate a successful attach holding the same lock while recover waits.
flock -x "$root/run/vgf-usb-control.lock" sh -c 'echo ready > "$1/ready"; sleep 0.2; echo configured > "$1/udc/test.udc/state"' sh "$root" &
holder=$!
while [ ! -e "$root/ready" ]; do sleep 0.01; done
output=$(sh "$helper" recover)
wait "$holder"
[ -z "$output" ]
[ "$(cat "$root/gadget/UDC")" = test.udc ]
echo 'PASS recover does not detach a gadget configured while waiting for the lock'
