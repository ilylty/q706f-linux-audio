#!/bin/sh
W=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2- | head -1)
[ -z "$W" ] && W=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)
[ -z "$W" ] && W="未连接"
echo "WiFi $W"
