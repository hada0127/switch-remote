#!/bin/sh
# Serialize gadget changes from the service and the watchdog.
set -eu
gadget=${VGF_USB_GADGET:-/sys/kernel/config/usb_gadget/vgf-controller}
udc_root=${VGF_USB_UDC_ROOT:-/sys/class/udc}
run_root=${VGF_USB_RUN_ROOT:-/run}
manual=$run_root/vgf-usb-manual-detach
exec 9>"$run_root/vgf-usb-control.lock"
flock -x 9
case "${1:-}" in
    status)
        udc=$(cat "$gadget/UDC" 2>/dev/null || true)
        if [ -z "$udc" ]; then echo 'not attached'; else cat "$udc_root/$udc/state"; fi
        ;;
    detach)
        touch "$manual"
        if [ -n "$(cat "$gadget/UDC")" ]; then echo '' > "$gadget/UDC"; fi
        echo 'USB gadget manually detached'
        ;;
    attach|recover)
        if [ "$1" = recover ] && [ -e "$manual" ]; then exit 0; fi
        if [ "$1" = attach ]; then rm -f "$manual"; fi
        udc=$(cat "$gadget/UDC")
        if [ "$1" = recover ] && [ -n "$udc" ] &&
           [ "$(cat "$udc_root/$udc/state" 2>/dev/null || true)" = configured ]; then exit 0; fi
        if [ -z "$udc" ]; then
            set -- "$udc_root"/*
            [ -e "$1" ] || { echo 'No UDC available' >&2; exit 1; }
            udc=${1##*/}
        else
            echo '' > "$gadget/UDC"
        fi
        sleep "${VGF_USB_REBIND_DELAY:-2}"
        echo "$udc" > "$gadget/UDC"
        echo "USB gadget rebound to $udc"
        ;;
    *) echo 'usage: usb-control.sh status|detach|attach|recover' >&2; exit 2;;
esac
