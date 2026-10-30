#!/bin/bash
# chgtrip —— 电池满电截止守护进程
#
# 只做一件事：电量到 STOP_AT 就停止充电，掉到 RESUME_AT 自动恢复。
#
# ── 为什么不做过流跳闸 ──────────────────────────────────────────────
#
# 曾经做过，现在移除了。原因：
#
#   1. 内核已经做了硬保护。驱动补丁 USB_ICL_HARD_LIMIT_UA=1500000
#      把 PMIC 的输入限流钉死在 1.5A。不管插 2.5A 还是 10A 的充电器，
#      实际能进来的最多 1.5A，接口不会被灌爆。软件跳闸纯属重复。
#
#   2. 软件跳闸会误杀。实测 2.5A 充电器净充稳定在 950~1005mA，
#      阈值定 800 会在 2 秒内把正常充电打断；定 1300 又因为 ICL
#      天花板（净充上不了 1100mA）而永远触发不了——两边都不对。
#
#   3. 跳闸是「关断」而非「限流」，代价太大。关断后系统吃电池，
#      电量往下掉；而且反复通断对电池的伤害比慢充更大。
#
# 如果以后内核天花板放开了（提高 USB_ICL_HARD_LIMIT_UA），需要重新
# 考虑是否加入过流保护——那时应该优先用调 ICL 限流，而不是关断。
#
# ── ICL 是真实有效的（修正旧结论）──────────────────────────────────
#
# 早期结论「AICL 绕过 ICL，改 icl_limit 无效」是错的。实测线性度：
#     ICL 1500mA → 净充 ~945mA
#     ICL 1200mA → 净充 ~640mA
#     ICL 1000mA → 净充 ~430mA
#     ICL  800mA → 净充 ~220mA
#     ICL  600mA → 净充    0mA（系统自耗刚好抵消）
#     ICL  400mA → 净充 -235mA（放电）
# 也就是说 icl_limit 是最干净的限流手段，需要限流时优先用它。
#
# 用法:
#   chgtrip            前台运行（一般交给 systemd）
#   chgtrip -t         只打印一次状态，不动作（调试用）

set -u

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
CONF=/etc/chgtrip.conf
FULLFLAG=/run/chg.full
LOG=/var/log/chgtrip.log

# ── 默认参数（可被 /etc/chgtrip.conf 覆盖）──────────────────────────
STOP_AT=95            # 电量 >= 此值停止充电
RESUME_AT=90          # 电量 <= 此值自动恢复充电
INTERVAL=5            # 采样间隔（秒）。只是看电量，不需要很密

[ -f "$CONF" ] && . "$CONF"

# ── 参数自检：滞回必须 RESUME_AT < STOP_AT，否则会死循环 ──
#
# 实测过 RESUME_AT >= STOP_AT 的情况：电量卡在两者之间时脚本会
# 不停地在「停止充电」和「自动恢复」之间来回切。这里强制拉开 1%。
if [ "$RESUME_AT" -ge "$STOP_AT" ]; then
    RESUME_AT=$(( STOP_AT - 1 ))
    [ "$RESUME_AT" -lt 1 ] && RESUME_AT=1
fi

rd() { cat "$1" 2>/dev/null || echo 0; }

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

# ── 调试模式 ─────────────────────────────────────────────────────────
if [ "${1:-}" = "-t" ]; then
    cap=$(rd "$B/capacity")
    printf '电量       : %s%%\n' "$cap"
    printf '电池状态   : %s\n' "$(rd $B/status)"
    printf '电池电流   : %s mA\n' "$(( $(rd $B/current_now) / 1000 ))"
    printf '电池温度   : %s °C\n' "$(( $(rd $B/temp) / 10 ))"
    printf '充电开关   : %s\n' "$(rd $P/charging_enabled)"
    printf '满电截止   : >=%s%% 停止, <=%s%% 恢复\n' "$STOP_AT" "$RESUME_AT"
    if [ -f "$FULLFLAG" ]; then
        printf '当前状态   : 已因满电停止 (记录 %s)\n' "$(cat "$FULLFLAG" 2>/dev/null)"
    elif [ "$cap" -ge "$STOP_AT" ]; then
        printf '当前状态   : 已达截止线（下次循环会停充）\n'
    else
        printf '当前状态   : 正常充电中\n'
    fi
    exit 0
fi

# ── 守护循环 ─────────────────────────────────────────────────────────
log "启动: 满电截止 >=${STOP_AT}% 停止, <=${RESUME_AT}% 恢复, 采样 ${INTERVAL}s"

was_enabled=""

while :; do
    en=$(rd "$P/charging_enabled")
    cap=$(rd "$B/capacity")
    st=$(rd "$B/status")

    if [ -f "$FULLFLAG" ]; then
        # 已处于满电截止态：只有掉到 RESUME_AT 以下才恢复
        if [ "$cap" -le "$RESUME_AT" ]; then
            # 只有在开关是关闭状态时才自动打开——用户手动 off 过的话
            # 到 RESUME_AT 以下也不擅自开，避免覆盖用户意图。
            if [ "$en" != "1" ]; then
                echo 1 > "$P/charging_enabled" 2>/dev/null
                log "电量 ${cap}% <= ${RESUME_AT}%，自动恢复充电"
            fi
            rm -f "$FULLFLAG"
            was_enabled=""
        fi
    elif [ "$en" = "1" ] && [ "$cap" -ge "$STOP_AT" ]; then
        # 正在充电且到了截止电量：停止
        echo 0 > "$P/charging_enabled" 2>/dev/null
        printf '%s %s%%\n' "$(date '+%F %T')" "$cap" > "$FULLFLAG"
        log "★ 满电截止: 电量 ${cap}% >= ${STOP_AT}%，已停止充电（掉到 ${RESUME_AT}% 自动恢复）"
        was_enabled=0
    fi

    # 开关状态变化记一笔（便于排查）
    if [ "$en" != "$was_enabled" ]; then
        if [ "$en" = "1" ]; then
            log "充电已开启 (状态 $st, ${cap}%)"
        else
            log "充电已关闭 (电量 ${cap}%)"
        fi
        was_enabled=$en
    fi

    sleep "$INTERVAL"
done
