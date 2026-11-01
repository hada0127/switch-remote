#!/bin/sh
# Poll the bound gadget, rebind only after a sustained unconfigured state.
set -eu
bad=0
delay=12
last=
while :; do
    state=$(/opt/videogamefilter-controller/native/usb-control.sh status 2>/dev/null || echo unavailable)
    if [ "$state" != "$last" ]; then echo "USB state: $state"; last=$state; fi
    if [ -e /run/vgf-usb-manual-detach ]; then bad=0; delay=12
    elif [ "$state" = configured ]; then bad=0; delay=12
    else
        bad=$((bad + 1))
        if [ "$bad" -ge "$delay" ]; then
            echo "USB not configured for ${bad}s; rebinding"
            if [ ! -e /sys/kernel/config/usb_gadget/vgf-controller/UDC ]; then
                /opt/videogamefilter-controller/native/usb-gadget.sh || true
            fi
            if [ -e /sys/kernel/config/usb_gadget/vgf-controller/UDC ] &&
               [ "$(/opt/videogamefilter-controller/native/usb-control.sh status 2>/dev/null || true)" != configured ]; then
                /opt/videogamefilter-controller/native/usb-control.sh recover || true
            fi
            bad=0
            delay=$((delay * 2)); [ "$delay" -le 120 ] || delay=120
        fi
    fi
    sleep 1
done
