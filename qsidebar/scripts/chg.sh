#!/bin/bash
# chg —— 充电开关控制（手动）
#
# 用法:
#   chg            显示状态
#   chg on         开始充电（同时清除满电截止标记）
#   chg off        停止充电
#   chg toggle     切换
#   chg state      输出 1=正在充电 0=未充电（给 qsidebar 的 initstate_cmd 用）
#
# 硬件事实（本机实测）:
#   1. 输入限流由内核钉死在 1.5A（USB_ICL_HARD_LIMIT_UA），
#      写 current_max 超过它会被驱动拒绝。这是防烧接口的真正保障。
#   2. icl_limit 是可用的限流手段（实测线性有效）：
#        ICL 1500mA → 净充 ~945mA
#        ICL 1200mA → 净充 ~640mA
#        ICL 1000mA → 净充 ~430mA
#        ICL  800mA → 净充 ~220mA
#        ICL  600mA → 净充    0mA
#        ICL  400mA → 净充 -235mA（放电）
#      需要限流时改 icl_limit，不要用关断。
#   3. charging_enabled（0 关 / 1 开）是硬开关，用于满电截止和手动控制。
#   4. 满电截止由 chgtrip 守护进程负责，阈值为 STOP_AT / RESUME_AT。

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FULLFLAG=/run/chg.full
CONF=/etc/chgtrip.conf

rd() { cat "$1" 2>/dev/null || echo 0; }

conf_int() {
    local key=$1 default=$2 v
    v=$default
    [ -f "$CONF" ] && v=$(grep -E "^${key}=" "$CONF" 2>/dev/null | cut -d= -f2)
    case "$v" in ''|*[!0-9]*) v=$default ;; esac
    echo "$v"
}

stop_at()   { conf_int STOP_AT 95;  }
resume_at() { conf_int RESUME_AT 90; }

cap_now() { cat "$B/capacity" 2>/dev/null || echo 0; }

case "$1" in
  on)
    rm -f "$FULLFLAG"
    echo 1 > "$P/charging_enabled" 2>/dev/null
    logger -t chg "手动开启充电"
    cap=$(cap_now)
    if [ "$cap" -ge "$(stop_at)" ]; then
        echo "已开启充电（注意：电量 ${cap}% 已达截止线 $(stop_at)%，守护进程会马上再次停充）"
    else
        echo "已开启充电（满电截止 $(stop_at)%，掉到 $(resume_at)% 自动恢复）"
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
        rm -f "$FULLFLAG"
        logger -t chg "手动停止充电"
        echo "已停止充电"
    else
        rm -f "$FULLFLAG"
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

    printf "充电开关     : %s\n" "$([ "$en" = 1 ] && echo '开启' || echo '关闭')"
    printf "电池状态     : %s\n" "$st"
    printf "电量         : %s%%\n" "$cap"
    printf "电池电流     : %s mA\n" "$((cur/1000))"
    printf "USB ADC      : %s mA  (未校准，仅供参照)\n" "$((usb/1000))"
    printf "驱动档位     : %s mA  (内核硬上限 1500mA)\n" "$((icl/1000))"
    printf "满电截止     : >=%s%% 停止, <=%s%% 恢复\n" "$(stop_at)" "$(resume_at)"

    if [ -f "$FULLFLAG" ]; then
        echo
        echo "已因满电停止充电 (记录: $(cat "$FULLFLAG" 2>/dev/null))"
        echo "  掉到 $(resume_at)% 以下会自动恢复；也可 chg on 强制开"
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
