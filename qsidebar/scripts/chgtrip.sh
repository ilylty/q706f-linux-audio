#!/bin/bash
# chgtrip —— 充电口过流 / 过热保护守护进程
#
# 设计目标：防止「插上 10A 之类的异常供电」把接口或电池烧了。
# 判定策略是「秒级 + 宽判定」：
#   - 采样 1 秒一次，连续 2 次命中即跳闸，最快约 1 秒动作
#   - 不要求 status=Charging（充满 / 涓流 / 温度保护时照样判）
#   - 三个独立条件，任一命中都跳闸
#
# 为什么不只看 bq27541 的净充电流：
#   那是「流进电池」的电流，异常供电灌进来时，多出来的功率被
#   充电 IC 吃掉（变成发热）而不是进电池，净充电流可能反而很低。
#   所以必须同时看「充电口协商电流」和「芯片温度」。
#
# 本机实测节点（Linux 7.1.0-1-gd5f7815e9a86 / lenovo-q706f）：
#   pm8150b-charger  有 charging_enabled / current_now / usb_type，但没有 temp
#   bq27541-0        有 current_now（净充电流）/ temp（0.1°C 单位）/ status / capacity
#   tcpm-source-psy  有 usb_type / current_max（协商电流）/ voltage_now（协商电压）
#   thermal_zone27   是 pm8150b-thermal（充电 IC 所在 PMIC 的芯片温度）
#
# 跳闸后不会自动恢复，必须手动 `chg on`。
#
# 用法:
#   chgtrip            前台运行（一般交给 systemd）
#   chgtrip -t         只打印一次采样结果，不动作（调试用）

set -u

P=/sys/class/power_supply/pm8150b-charger
B=/sys/class/power_supply/bq27541-0
T=/sys/class/power_supply/tcpm-source-psy-c440000.spmi:pmic@2:typec@1500
CONF=/etc/chgtrip.conf
FLAG=/run/chg.tripped
FULLFLAG=/run/chg.full
LOG=/var/log/chgtrip.log

# ── 默认阈值（可被 /etc/chgtrip.conf 覆盖）────────────────────────────
LIMIT_MA=800          # 净充电流上限（防电池被灌爆）
LIMIT_PORT_MA=3300    # 充电口协商电流上限（防接口过流）
LIMIT_TEMP=45         # 电池温度上限 °C
LIMIT_PMIC_TEMP=60    # 充电 IC 所在 PMIC 温度上限 °C
SAMPLES=2             # 连续命中次数
INTERVAL=1            # 采样间隔（秒）
GRACE=8               # 每次开启充电后的宽限期（秒），避开接通瞬间冲高

# ── 满电截止（滞回式，像笔记本一样）──────────────────────────────────
# 电量 >= STOP_AT 时停止充电；掉到 <= RESUME_AT 时自动恢复充电。
#
# 为什么用滞回而不是单门限：如果只在 95% 单向关断，电量掉到 94%
# 用户就会手动点开，充到 96% 又停，反复按压对电池更伤。
# 留 5% 的间隔，充放都在一个周期内完成，不会来回抖动。
#
# 注意：满电截止和过流跳闸是两套独立机制
#   满电截止  → 自动恢复（滞回）
#   过流跳闸  → 不自动恢复，必须手动 chg on
STOP_AT=95
RESUME_AT=90

[ -f "$CONF" ] && . "$CONF"

# ── 参数自检：滞回必须 RESUME_AT < STOP_AT，否则会死循环 ──
#
# 实测过：如果 RESUME_AT >= STOP_AT，电量卡在两者之间时脚本会
# 不停地在「满电截止」和「自动恢复」之间来回，每秒开关一次。
# 这里强制拉开 1% 间隔，防止配置文件写错把充放电反复按压。
if [ "$RESUME_AT" -ge "$STOP_AT" ]; then
    RESUME_AT=$(( STOP_AT - 1 ))
    [ "$RESUME_AT" -lt 1 ] && RESUME_AT=1
fi

rd() { cat "$1" 2>/dev/null || echo 0; }

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

# 从 thermal_zone 找 pm8150b-thermal（编号可能随内核变，不能写死 27）
find_pmic_zone() {
    local z t
    for z in /sys/class/thermal/thermal_zone*/type; do
        t=$(cat "$z" 2>/dev/null)
        if [ "$t" = "pm8150b-thermal" ]; then
            dirname "$z"
            return 0
        fi
    done
    return 1
}

PMIC_ZONE=$(find_pmic_zone)

# 检查所有条件，把「超限原因」用 stdout 输出（空 = 一切正常）。
#
# ★ 为什么用 echo 而不是 return code 表示结果
#
#   bash 里 return 0 = 真、return 1 = 假，而「超限」直觉上像 0
#   （"非空" / "命中"），这个语义在本脚本里被写反过两次——一次导致
#   正常充电乱跳闸，一次导致真过流反而不跳。安全关键的代码不该
#   依赖这种容易记反的约定。
#
#   改成：输出字符串 = 有超限（原因），输出空 = 正常。
#   调用处 `reasons=$(check_over)` 一看就懂，没有真假颠倒的空间。
check_over() {
    local reasons=""

    # ① 净充电流（bq27541，单位 µA）
    local bq_ma
    bq_ma=$(( $(rd "$B/current_now") / 1000 ))
    if [ "$bq_ma" -gt "$LIMIT_MA" ]; then
        reasons="${reasons}净充${bq_ma}mA>${LIMIT_MA} "
    fi

    # ② 充电口协商电流（TCPM，单位 µA）—— 这条才是防接口过流的关键
    local port_ma
    port_ma=$(( $(rd "$T/current_max") / 1000 ))
    if [ "$port_ma" -gt "$LIMIT_PORT_MA" ]; then
        reasons="${reasons}协商${port_ma}mA>${LIMIT_PORT_MA} "
    fi

    # ③ 电池温度（bq27541，单位 0.1°C）
    local bt_c
    bt_c=$(( $(rd "$B/temp") / 10 ))
    if [ "$bt_c" -gt "$LIMIT_TEMP" ]; then
        reasons="${reasons}电池${bt_c}°C>${LIMIT_TEMP} "
    fi

    # ④ 充电 IC 所在 PMIC 温度（thermal_zone，单位 0.001°C）
    if [ -n "$PMIC_ZONE" ]; then
        local pt_c
        pt_c=$(( $(rd "$PMIC_ZONE/temp") / 1000 ))
        if [ "$pt_c" -gt "$LIMIT_PMIC_TEMP" ]; then
            reasons="${reasons}IC${pt_c}°C>${LIMIT_PMIC_TEMP} "
        fi
    fi

    printf '%s' "${reasons% }"
}

# ── 调试模式：采样一次就退出 ─────────────────────────────────────────
if [ "${1:-}" = "-t" ]; then
    printf '净充电流   : %s mA  (上限 %s)\n' "$(( $(rd $B/current_now) / 1000 ))" "$LIMIT_MA"
    printf '协商电流   : %s mA  (上限 %s)\n' "$(( $(rd $T/current_max) / 1000 ))" "$LIMIT_PORT_MA"
    printf '协商电压   : %s mV\n' "$(( $(rd $T/voltage_now) / 1000 ))"
    printf '电池温度   : %s °C  (上限 %s)\n' "$(( $(rd $B/temp) / 10 ))" "$LIMIT_TEMP"
    printf 'PMIC 温度  : %s °C  (上限 %s)  [%s]\n' \
        "$(( $(rd "$PMIC_ZONE/temp") / 1000 ))" "$LIMIT_PMIC_TEMP" "${PMIC_ZONE:-未找到}"
    printf '电池状态   : %s  电量 %s%%\n' "$(rd $B/status)" "$(rd $B/capacity)"
    printf '充电开关   : %s\n' "$(rd $P/charging_enabled)"
    printf '满电截止   : >=%s%% 停止, <=%s%% 恢复\n' "$STOP_AT" "$RESUME_AT"
    if [ -f "$FULLFLAG" ]; then
        printf '满电状态   : 已因满电停止 (%s%%)\n' "$(rd $B/capacity)"
    fi
    r=$(check_over)
    if [ -n "$r" ]; then
        printf '判定       : ★ 超限 —— %s\n' "$r"
    else
        printf '判定       : 正常\n'
    fi
    exit 0
fi

# ── 守护循环 ─────────────────────────────────────────────────────────
log "启动: 净充<${LIMIT_MA}mA 协商<${LIMIT_PORT_MA}mA 电池<${LIMIT_TEMP}°C IC<${LIMIT_PMIC_TEMP}°C 连续${SAMPLES}次 采样${INTERVAL}s 宽限${GRACE}s"
log "满电截止: >=${STOP_AT}% 停止, <=${RESUME_AT}% 恢复"
log "PMIC 温度节点: ${PMIC_ZONE:-未找到}"

was_enabled=""
over=0
grace_until=0

while :; do
    en=$(rd "$P/charging_enabled")
    cap=$(rd "$B/capacity")
    st=$(rd "$B/status")

    # 开关状态变化时重置计数
    if [ "$en" != "$was_enabled" ]; then
        if [ "$en" = "1" ]; then
            grace_until=$(( $(date +%s) + GRACE ))
            log "充电已开启 (状态 $st, ${cap}%)，${GRACE}s 宽限期内不判超限"
        else
            log "充电已关闭"
        fi
        was_enabled=$en
        over=0
    fi

    # ── 满电截止（滞回）──────────────────────────────────────────
    #
    # >= STOP_AT  → 停止充电，写 FULLFLAG
    # <= RESUME_AT → 自动恢复充电，清除 FULLFLAG
    #
    # 放在过流判定之前：已经满电就没必要再判电流了。
    #
    # 注意人工干预：如果用户手动 chg off 之后电量还高，这里不会
    # 擅自把开关打开——只在「因满电截止」的情况下才自动恢复。
    if [ -f "$FULLFLAG" ]; then
        # 已处于满电截止态：只有掉到 RESUME_AT 以下才恢复
        if [ "$cap" -le "$RESUME_AT" ] && [ "$en" != "1" ]; then
            echo 1 > "$P/charging_enabled" 2>/dev/null
            rm -f "$FULLFLAG"
            log "电量 ${cap}% <= ${RESUME_AT}%，自动恢复充电"
            grace_until=$(( $(date +%s) + GRACE ))
            was_enabled=1
            sleep "$INTERVAL"
            continue
        fi
    elif [ "$en" = "1" ] && [ "$cap" -ge "$STOP_AT" ]; then
        # 正在充电且到了截止电量：停止
        echo 0 > "$P/charging_enabled" 2>/dev/null
        printf '%s %s%%\n' "$(date '+%F %T')" "$cap" > "$FULLFLAG"
        log "★ 满电截止: 电量 ${cap}% >= ${STOP_AT}%，已停止充电（掉到 ${RESUME_AT}% 自动恢复）"
        was_enabled=0
        sleep "$INTERVAL"
        continue
    fi

    # 只有开关打开时才判超限（关了就没电流，不用管）
    if [ "$en" != "1" ]; then
        sleep "$INTERVAL"
        continue
    fi

    # 宽限期
    if [ "$(date +%s)" -lt "$grace_until" ]; then
        over=0
        sleep "$INTERVAL"
        continue
    fi

    # ★ 关键：不检查 status，只要开关开着就判
    r=$(check_over)
    if [ -z "$r" ]; then
        over=0                    # 正常，计数清零
    else
        over=$(( over + 1 ))      # 有超限原因，累计
        if [ "$over" -ge "$SAMPLES" ]; then
            echo 0 > "$P/charging_enabled" 2>/dev/null
            {
                printf '%s ★ 跳闸: %s（连续%s次）\n' \
                    "$(date '+%F %T')" "$r" "$SAMPLES"
                printf '  电量 %s%%  状态 %s\n' "$cap" "$st"
                printf '  恢复方式: chg on  （不会自动恢复）\n'
            } > "$FLAG"
            log "★ 跳闸: ${r}（连续${SAMPLES}次），已关断充电"
            log "  电量 ${cap}%  恢复方式: chg on"
            over=0
            was_enabled=0
        fi
    fi

    sleep "$INTERVAL"
done
