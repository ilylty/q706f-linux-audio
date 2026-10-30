#!/bin/sh
# chg_label.sh —— 给 qsidebar 按钮显示充电状态（单行，供 label_cmd 调用）
#
# 输出形态（尽量短，按钮宽度有限）：
#   跳闸 312mA      已跳闸，显示跳闸原因里的电流
#   充电 1450mA     正在充电，净充电流
#   充电 1450mA!    正在充电且接近阈值（80% 以上）
#   已关 66%        手动关闭充电
#   充满 100%       电池已满
#   USB 66%         有外部供电但未充电

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FLAG=/run/chg.tripped
FULLFLAG=/run/chg.full
CONF=/etc/chgtrip.conf

rd() { cat "$1" 2>/dev/null || echo 0; }

LIMIT_MA=800
[ -f "$CONF" ] && LIMIT_MA=$(grep -E '^LIMIT_MA=' "$CONF" 2>/dev/null | cut -d= -f2)
case "$LIMIT_MA" in ''|*[!0-9]*) LIMIT_MA=800 ;; esac

en=$(rd $P/charging_enabled)
cap=$(rd $B/capacity)
cur=$(( $(rd $B/current_now) / 1000 ))
st=$(rd $B/status)

RESUME_AT=90
[ -f "$CONF" ] && RESUME_AT=$(grep -E '^RESUME_AT=' "$CONF" 2>/dev/null | cut -d= -f2)
case "$RESUME_AT" in ''|*[!0-9]*) RESUME_AT=90 ;; esac

# 已跳闸：优先显示跳闸
if [ -f "$FLAG" ]; then
    # /run/chg.tripped 第一行形如：
    #   2026-10-30 16:12:03 ★ 跳闸: 净充312mA>800 ...
    ma=$(grep -oE '[0-9]+mA' "$FLAG" 2>/dev/null | head -1)
    [ -n "$ma" ] && printf '跳闸 %s\n' "$ma" || printf '跳闸\n'
    exit 0
fi

# 满电截止（滞回）：显示当前电量 + 恢复点，让主人知道何时会自动充
if [ -f "$FULLFLAG" ]; then
    printf '满电 %s%%\n' "$cap"
    exit 0
fi

# 电池已满
if [ "$cap" -ge 100 ] || [ "$st" = "Full" ]; then
    printf '充满 %s%%\n' "$cap"
    exit 0
fi

# 开关关闭
if [ "$en" != "1" ]; then
    printf '已关 %s%%\n' "$cap"
    exit 0
fi

# 开关打开但没有实际充电（外部供电不足 / 温度保护中）
if [ "$st" != "Charging" ]; then
    printf 'USB %s%%\n' "$cap"
    exit 0
fi

# 正在充电，超过 80% 阈值时加叹号提示
if [ "$cur" -gt $(( LIMIT_MA * 8 / 10 )) ]; then
    printf '充电 %smA!\n' "$cur"
else
    printf '充电 %smA\n' "$cur"
fi
