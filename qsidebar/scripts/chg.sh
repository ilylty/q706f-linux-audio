#!/bin/bash
# chg —— 充电开关控制（手动）
#
# 用法:
#   chg            显示状态
#   chg on         开始充电（同时清除自动跳闸标记）
#   chg off        停止充电
#   chg toggle     切换
#   chg state      输出 1=正在充电 0=未充电（给 qsidebar 的 initstate_cmd 用）
#
# 硬件事实（本机实测）:
#   1. smb5 的 AICL 硬件环路会绕过 USBIN_CURRENT_LIMIT_CFG，
#      写 current_max / icl_limit 都无法真正限制电流。
#   2. 唯一有效的控制手段是 charging_enabled（0 关 / 1 开）。
#   3. 因此限流只能靠 chgtrip 做「超阈值关断 + 手动恢复」。

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FLAG=/run/chg.tripped
FULLFLAG=/run/chg.full
CONF=/etc/chgtrip.conf

rd() { cat "$1" 2>/dev/null || echo 0; }

limit_ma() {
    local v=800
    [ -f "$CONF" ] && v=$(grep -E '^LIMIT_MA=' "$CONF" 2>/dev/null | cut -d= -f2)
    case "$v" in ''|*[!0-9]*) v=800 ;; esac
    echo "$v"
}

stop_at() {
    local v=95
    [ -f "$CONF" ] && v=$(grep -E '^STOP_AT=' "$CONF" 2>/dev/null | cut -d= -f2)
    case "$v" in ''|*[!0-9]*) v=95 ;; esac
    echo "$v"
}

resume_at() {
    local v=90
    [ -f "$CONF" ] && v=$(grep -E '^RESUME_AT=' "$CONF" 2>/dev/null | cut -d= -f2)
    case "$v" in ''|*[!0-9]*) v=90 ;; esac
    echo "$v"
}

# 手动开充电时：如果电量已经到截止线，就提醒（但仍允许强制开启）
cap_now() { cat "$B/capacity" 2>/dev/null || echo 0; }

case "$1" in
  on)
    rm -f "$FLAG" "$FULLFLAG"
    echo 1 > "$P/charging_enabled" 2>/dev/null
    logger -t chg "手动开启充电"
    cap=$(cap_now)
    if [ "$cap" -ge "$(stop_at)" ]; then
        echo "已开启充电（注意：电量 ${cap}% 已达截止线 $(stop_at)%，守护进程会马上再次停充）"
    else
        echo "已开启充电（净充上限 $(limit_ma)mA，满电截止 $(stop_at)%）"
    fi
    ;;

  off)
    echo 0 > "$P/charging_enabled" 2>/dev/null
    rm -f "$FULLFLAG"
    logger -t chg "手动停止充电"
    echo "已停止充电"
    ;;

  toggle)
    if [ "$(rd $P/charging_enabled)" = "1" ]; then
        echo 0 > "$P/charging_enabled" 2>/dev/null
        logger -t chg "手动停止充电"
        echo "已停止充电"
    else
        rm -f "$FLAG" "$FULLFLAG"
        echo 1 > "$P/charging_enabled" 2>/dev/null
        logger -t chg "手动开启充电"
        cap=$(cap_now)
        if [ "$cap" -ge "$(stop_at)" ]; then
            echo "已开启充电（电量 ${cap}% 已达截止线，守护会马上再停）"
        else
            echo "已开启充电"
        fi
    fi
    ;;

  state)
    # 给 qsidebar toggle 按钮用：1 = 亮起（正在充）
    # 满电截止时也算「未充电」→ 灯灭，符合直觉
    en=$(rd $P/charging_enabled)
    st=$(cat "$B/status" 2>/dev/null)
    if [ "$en" = "1" ] && [ "$st" = "Charging" ]; then
        echo 1
    else
        echo 0
    fi
    ;;

  ''|status)
    en=$(rd $P/charging_enabled)
    st=$(cat "$B/status" 2>/dev/null)
    cap=$(rd $B/capacity)
    cur=$(rd $B/current_now)
    usb=$(rd $P/current_now)
    icl=$(rd $P/current_max)
    lim=$(limit_ma)

    printf "充电开关     : %s\n" "$([ "$en" = 1 ] && echo '开启' || echo '关闭')"
    printf "电池状态     : %s\n" "$st"
    printf "电量         : %s%%\n" "$cap"
    printf "电池电流     : %s mA\n" "$((cur/1000))"
    printf "USB ADC      : %s mA  (未校准，仅供参照)\n" "$((usb/1000))"
    printf "驱动档位     : %s mA  (AICL 可绕过，非实际限流)\n" "$((icl/1000))"
    printf "自动保护阈值 : %s mA\n" "$lim"
    printf "满电截止     : >=%s%% 停止, <=%s%% 恢复\n" "$(stop_at)" "$(resume_at)"

    if [ -f "$FULLFLAG" ]; then
        echo
        echo "已因满电停止充电 (记录: $(cat "$FULLFLAG" 2>/dev/null))"
        echo "  掉到 $(resume_at)% 以下会自动恢复；也可 chg on 强制开"
    fi

    if [ -f "$FLAG" ]; then
        echo
        echo "★ 已被自动保护跳闸"
        echo "  原因: $(cat "$FLAG" 2>/dev/null)"
        echo "  恢复: chg on  （或点控制中心的充电按钮）"
    fi

    if pgrep -f 'chgtrip' >/dev/null 2>&1; then
        echo
        echo "守护进程     : 运行中 (PID $(pgrep -f chgtrip | tr '\n' ' '))"
    else
        echo
        echo "守护进程     : 未运行"
    fi
    ;;

  *)
    echo "用法: chg [on|off|toggle|state|status]"
    exit 1
    ;;
esac
