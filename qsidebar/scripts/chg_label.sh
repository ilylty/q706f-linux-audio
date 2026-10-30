#!/bin/sh
# chg_label.sh —— 给 qsidebar 按钮显示充电状态
#
# 输出优先级:
#   跳闸中     → "跳闸 640mA"
#   充电中     → "充电 660mA"
#   已关闭     → "已关 60%"
#   已充满     → "充满 100%"
#
# 注意: 电池侧 bq27541 的 current_now 比 USB ADC 可信得多
#       （USB ADC 未校准，恒定在 176mA 附近，与实际无关）

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FLAG=/run/chg.tripped

rd() { cat "$1" 2>/dev/null || echo 0; }

en=$(rd $P/charging_enabled)
st=$(cat "$B/status" 2>/dev/null)
cap=$(rd $B/capacity)
cur=$(( $(rd $B/current_now) / 1000 ))

if [ -f "$FLAG" ]; then
    echo "跳闸 ${cur}mA"
elif [ "$st" = "Full" ]; then
    echo "充满 ${cap}%"
elif [ "$en" = "1" ] && [ "$st" = "Charging" ]; then
    echo "充电 ${cur}mA"
elif [ "$en" = "1" ]; then
    echo "待充 ${cap}%"
else
    echo "已关 ${cap}%"
fi
