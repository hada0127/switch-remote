#!/bin/sh
# net-watch.sh (vgf-net-watch): self-heal Wi-Fi without human intervention.
# Runs every 2 min (vgf-net-watch.timer). Fail streak kept in /run.
#   3 fails (~6 min)  -> reconnect Wi-Fi (radio off/on)
#   8 fails (~16 min) -> reboot (only if uptime > 20 min, avoids reboot loops)
STATE=/run/vgf-net-watch.fails
GW=$(ip -4 route show default dev wlan0 2>/dev/null | awk "/default/{print \$3; exit}")
[ -n "$GW" ] || GW=192.168.0.1
if ping -c 3 -W 3 -I wlan0 "$GW" >/dev/null 2>&1; then
  [ -s "$STATE" ] && [ "$(cat $STATE)" != 0 ] && logger -t vgf-net-watch "recovered (gw $GW)"
  echo 0 > "$STATE"; exit 0
fi
N=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$STATE"
logger -t vgf-net-watch "gateway $GW unreachable, streak=$N"
UP=$(cut -d. -f1 /proc/uptime)
if [ "$N" -ge 8 ] && [ "$UP" -gt 1200 ]; then
  logger -t vgf-net-watch "rebooting after $N failures"; systemctl reboot
elif [ "$N" -ge 3 ] && [ $((N % 3)) -eq 0 ]; then
  logger -t vgf-net-watch "cycling Wi-Fi"
  nmcli radio wifi off; sleep 3; nmcli radio wifi on
fi
