#!/bin/bash
# chgtrip —— 充电电流自动保护（超过阈值关断，不自动恢复）
#
# 用法:
#   chgtrip            前台运行
#   chgtrip -d         后台运行
#   chgtrip --install  装成 systemd 服务并启动
#
# 规则:
#   监测电池电流（bq27541 current_now）。
#   连续 N 次采样都 > LIMIT_MA  → 立即 charging_enabled=0，写跳闸标记
#   跳闸后不自动恢复，必须 chg on 手动重置
#
# 阈值配置: /etc/chgtrip.conf
#   LIMIT_MA=400      电流阈值（mA）
#   SAMPLES=3         连续超限次数（防抖）
#   INTERVAL=5        采样间隔（秒）
#
# 为什么不用 current_max / icl_limit:
#   本机实测证明 smb5 的 AICL 硬件环路会绕过 USBIN_CURRENT_LIMIT_CFG，
#   icl_limit 从 100mA 到 1500mA 净充恒定 660mA，完全无效。
#   charging_enabled 是唯一真正能断电的开关。

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
FLAG=/run/chg.tripped
CONF=/etc/chgtrip.conf
LOG=/var/log/chgtrip.log

rd() { cat "$1" 2>/dev/null || echo 0; }

# ---------- 读配置 ----------
LIMIT_MA=400
SAMPLES=3
INTERVAL=5
if [ -f "$CONF" ]; then
    v=$(grep -E '^LIMIT_MA=' "$CONF" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && LIMIT_MA=$v
    v=$(grep -E '^SAMPLES='  "$CONF" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && SAMPLES=$v
    v=$(grep -E '^INTERVAL=' "$CONF" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && INTERVAL=$v
fi
case "$LIMIT_MA" in ''|*[!0-9]*) LIMIT_MA=400 ;; esac
case "$SAMPLES"  in ''|*[!0-9]*) SAMPLES=3   ;; esac
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5  ;; esac
LIMIT_UA=$(( LIMIT_MA * 1000 ))

log() {
    local m="$(date '+%F %T') $*"
    echo "$m" >> "$LOG" 2>/dev/null
    logger -t chgtrip "$*" 2>/dev/null
    [ "$QUIET" != "1" ] && echo "$m"
}

log "启动: 阈值 ${LIMIT_MA}mA, 连续 ${SAMPLES} 次, 采样 ${INTERVAL}s"

over=0
was_enabled=-1

while :; do
    en=$(rd $P/charging_enabled)
    cur=$(rd $B/current_now)
    st=$(cat "$B/status" 2>/dev/null)
    cap=$(rd $B/capacity)
    cur_ma=$(( cur / 1000 ))

    # 充电开关被手动改了，重置计数
    if [ "$en" != "$was_enabled" ]; then
        case "$en" in
          1) log "充电已开启 (状态 $st, ${cap}%)" ;;
          0) log "充电已关闭" ;;
        esac
        was_enabled=$en
        over=0
    fi

    # 只在「开关开启 且 正在充电」时判超限
    if [ "$en" = "1" ] && [ "$st" = "Charging" ]; then
        if [ "$cur_ma" -gt "$LIMIT_MA" ]; then
            over=$((over + 1))
            [ "$over" -ge "$SAMPLES" ] && {
                echo 0 > "$P/charging_enabled" 2>/dev/null
                printf '%s 电流 %smA > %smA 连续%s次，已关断 (电量 %s%%)\n' \
                    "$(date '+%F %T')" "$cur_ma" "$LIMIT_MA" "$SAMPLES" "$cap" > "$FLAG"
                log "★ 跳闸: 电流 ${cur_ma}mA > ${LIMIT_MA}mA (连续${SAMPLES}次)，已关断充电"
                log "  恢复方式: chg on  （不会自动恢复）"
                over=0
                was_enabled=0
                sleep "$INTERVAL"
                continue
            }
        else
            [ "$over" -gt 0 ] && log "电流回落 ${cur_ma}mA ≤ ${LIMIT_MA}mA，计数清零"
            over=0
        fi
    else
        over=0
    fi

    sleep "$INTERVAL"
done
