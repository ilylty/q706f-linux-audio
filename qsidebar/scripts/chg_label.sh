#!/bin/sh
# chg_label.sh —— 给 qsidebar 按钮显示充电状态（单行，供 label_cmd 调用）
#
# 输出形态（尽量短，按钮宽度有限）：
#   满电 95%        已因满电截止
#   充满 100%       电池真的满了
#   充电 945mA      正在充电，净充电流
#   已关 66%        手动关闭充电
#   USB 66%         有外部供电但未充电
#
# 过流跳闸已移除（内核已用 1.5A 输入上限保护接口），所以不再有「跳闸」形态。

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FULLFLAG=/run/chg.full

rd() { cat "$1" 2>/dev/null || echo 0; }

en=$(rd $P/charging_enabled)
cap=$(rd $B/capacity)
cur=$(( $(rd $B/current_now) / 1000 ))
st=$(rd $B/status)

# 满电截止
if [ -f "$FULLFLAG" ]; then
    printf '满电 %s%%\n' "$cap"
    exit 0
fi

# 电池真的满了
if [ "$cap" -ge 100 ] || [ "$st" = "Full" ]; then
    printf '充满 %s%%\n' "$cap"
    exit 0
fi

# 开关关闭
if [ "$en" != "1" ]; then
    printf '已关 %s%%\n' "$cap"
    exit 0
fi

# 开关打开但没有实际充电
if [ "$st" != "Charging" ]; then
    printf 'USB %s%%\n' "$cap"
    exit 0
fi

# 正在充电
printf '充电 %smA\n' "$cur"
