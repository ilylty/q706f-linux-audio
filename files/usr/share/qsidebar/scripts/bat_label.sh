#!/bin/sh
C=$(cat /sys/class/power_supply/bq27541-0/capacity 2>/dev/null || echo "?")
S=$(cat /sys/class/power_supply/bq27541-0/status 2>/dev/null)
case "$S" in
  Charging) echo "充电中 ${C}%" ;;
  Full)     echo "已充满 ${C}%" ;;
  *)        echo "电量 ${C}%" ;;
esac
