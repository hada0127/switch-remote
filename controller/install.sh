#!/bin/sh
set -eu
umask 077
cd "$(dirname "$0")"
if [ "$(id -u)" != 0 ]; then
    echo 'Run with sudo on the Raspberry Pi.' >&2
    exit 1
fi
apt-get update
apt-get install -y bluez avahi-daemon iw util-linux build-essential pkg-config libssl-dev libjson-c-dev libdbus-1-dev libbluetooth-dev
install -d -m 755 /opt/videogamefilter-controller
make -C native clean all check
install -d -m 755 /opt/videogamefilter-controller/native
install -m 755 native/vgf-controller native/usb-gadget.sh native/usb-control.sh native/usb-watch.sh /opt/videogamefilter-controller/native/
install -m 644 native/switch-controller.xml /opt/videogamefilter-controller/native/
install -m 644 vendor/NXBT-LICENSE /opt/videogamefilter-controller/native/
chown -R root:root /opt/videogamefilter-controller
chmod -R go-w /opt/videogamefilter-controller
rfkill unblock bluetooth
if [ -d identity ]; then
    install -d -m 700 /var/lib/videogamefilter-controller
    systemctl stop vgf-controller.service 2>/dev/null || true
    python3 install_identity.py identity /var/lib/videogamefilter-controller
fi
if [ -f /var/lib/videogamefilter-controller/device.json ]; then
    python3 - <<'PY'
import json,pathlib
identity=json.loads(pathlib.Path('/var/lib/videogamefilter-controller/device.json').read_text())
device=identity['id']
# IDs are generated UUIDs, never arbitrary XML input.
import uuid
assert str(uuid.UUID(device)) == device
pathlib.Path('/etc/avahi/services/vgf-controller.service').write_text('''<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group><name>Video Game Filter Pi '''+device[:8]+'''</name>
<service><type>_vgf-controller._tcp</type><port>24872</port>
<txt-record>id='''+device+'''</txt-record><txt-record>version=1</txt-record>
</service></service-group>''')
PY
    # Native controller owns HID L2CAP directly, as the previous NXBT runtime did.
    systemctl stop vgf-controller.service 2>/dev/null || true
    install -d /etc/systemd/system/bluetooth.service.d
    cat > /etc/systemd/system/bluetooth.service.d/vgf-controller.conf <<'BLUEZ'
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --compat --noplugin=*
BLUEZ
    # This is a dedicated Zero W image; leave unrelated board sections untouched.
    config=/boot/firmware/config.txt
    if [ -f "$config" ] && ! grep -q '^dtoverlay=dwc2,dr_mode=peripheral$' "$config"; then
        cp -n "$config" "$config.vgf-backup" || true
        printf '\n[all]\n# Video Game Filter USB controller\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$config"
    fi
    # Keep the gadget overlay in the serial rollback backup.
    if [ -f "$config" ] && { ! grep -q '^enable_uart=1$' "$config" || ! grep -q '^core_freq=250$' "$config"; }; then
        cp -n "$config" "$config.vgf-serial-backup" || true
    fi
    # Stable mini UART clock keeps 115200 reliable while Bluetooth retains PL011.
    if [ -f "$config" ]; then
        if ! grep -q '^enable_uart=1$' "$config"; then printf '\n[all]\nenable_uart=1\n' >> "$config"; fi
        if ! grep -q '^core_freq=250$' "$config"; then printf '\n[all]\ncore_freq=250\n' >> "$config"; fi
    fi
    cmdline=/boot/firmware/cmdline.txt
    if [ -f "$cmdline" ]; then
        cp -n "$cmdline" "$cmdline.vgf-serial-backup" || true
        python3 - <<'SERIAL_CMDLINE'
from pathlib import Path
import os, tempfile
path = Path('/boot/firmware/cmdline.txt')
original = path.read_text()
words = original.split()
updated = ' '.join(w for w in words if not w.startswith('console=serial0,')) + '\n'
if updated != original:
    fd, temporary = tempfile.mkstemp(prefix='cmdline.vgf-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(updated)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
SERIAL_CMDLINE
    fi
    systemctl disable --now serial-getty@ttyS0.service 2>/dev/null || true
    systemctl mask serial-getty@ttyS0.service 2>/dev/null || true
    cat > /etc/systemd/system/vgf-usb-gadget.service <<'GADGET'
[Unit]
Description=Video Game Filter USB controller gadget
After=systemd-modules-load.service
Before=vgf-controller.service
[Service]
Type=oneshot
ExecStart=/opt/videogamefilter-controller/native/usb-gadget.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
GADGET
    cat > /etc/systemd/system/vgf-usb-watch.service <<'WATCH'
[Unit]
Description=Video Game Filter USB gadget reattach watchdog
Requires=vgf-usb-gadget.service
After=vgf-usb-gadget.service
[Service]
Type=simple
ExecStart=/opt/videogamefilter-controller/native/usb-watch.sh
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
WATCH
    cat > /etc/systemd/system/vgf-controller.service <<'UNIT'
[Unit]
Description=Video Game Filter controller service
Wants=network-online.target bluetooth.service avahi-daemon.service vgf-usb-gadget.service
After=network-online.target bluetooth.service avahi-daemon.service vgf-usb-gadget.service
[Service]
Type=simple
ExecStartPre=/usr/sbin/rfkill unblock bluetooth
ExecStartPre=-/usr/sbin/iw dev wlan0 set power_save off
# ondemand ramps up only after load; input bursts are too short for that.
ExecStartPre=-/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$$g" ] && echo performance > "$$g"; done; true'
ExecStart=/opt/videogamefilter-controller/native/vgf-controller
Nice=-5
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStopSec=25
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl restart bluetooth.service
    systemctl enable --now vgf-usb-gadget.service
    systemctl enable vgf-usb-watch.service
    systemctl restart vgf-usb-watch.service
    systemctl enable --now avahi-daemon.service
    systemctl enable vgf-controller.service
    systemctl restart vgf-controller.service
    # Remove only this provisioner's generated secrets/artifacts after success.
    rm -f identity/device.json identity/server.key identity/server.crt
    rmdir identity 2>/dev/null || true
    for boot in /boot/firmware /boot; do
        if [ -f "$boot/vgf-controller/identity/device.json" ]; then
            rm -rf "$boot/vgf-controller"
            rm -f "$boot/vgf-firstboot.sh" "$boot/vgf-previous-run.txt" "$boot/vgf-cmdline-original.txt"
        fi
    done
fi
printf 'Controller service installed.\n'
