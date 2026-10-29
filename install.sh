#!/bin/bash
# q706f-linux-audio — Lenovo Xiaoxin Pad Pro 12.6 音频安装脚本
# 用法: sudo ./install.sh [--skip-ucm] [--skip-pipewire]
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_UCM=0
SKIP_PW=0
for arg in "$@"; do
    case "$arg" in
        --skip-ucm)      SKIP_UCM=1 ;;
        --skip-pipewire) SKIP_PW=1 ;;
        -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
ok()   { echo "${GRN}  ✓${RST} $*"; }
warn() { echo "${YEL}  !${RST} $*"; }
err()  { echo "${RED}  ✗${RST} $*"; }
step() { echo; echo "${BLU}==>${RST} $*"; }

[ "$(id -u)" -eq 0 ] || { err "需要 root 权限"; exit 1; }

# ---------------------------------------------------------------- 1. 前置检查
step "检查硬件与固件"

if ! ls /sys/firmware/devicetree/base/model >/dev/null 2>&1; then
    warn "找不到 devicetree，可能不是 ARM 设备"
fi
MODEL="$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || echo unknown)"
echo "    设备: $MODEL"

if ! echo "$MODEL" | grep -qiE 'q706f|Xiaoxin Pad Pro'; then
    warn "设备型号不是 Xiaoxin Pad Pro 12.6，继续可能会有问题"
fi

# as33970 固件
ASFW=/lib/firmware/as33970/partition_boot2flash.img
if [ -f "$ASFW" ]; then
    ok "as33970 固件已存在 ($(stat -c%s "$ASFW") 字节)"
else
    err "缺少 $ASFW"
    cat <<'EOF'

    这个文件需要从 Android vendor 分区提取：
      lpunpack -p vendor_a /dev/disk/by-partlabel/super /tmp/lp
      mount -o ro /tmp/lp/vendor_a.img /mnt/vend
      mkdir -p /lib/firmware/as33970
      cp /mnt/vend/firmware/partition_boot2flash.img /lib/firmware/as33970/

EOF
    read -rp "    继续安装（稍后自行补固件）？[y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 1
fi

# cs35l45 DSP 固件
CSFW=/lib/firmware/cirrus/cs35l45-dsp1-spk-prot.wmfw
if [ -f "$CSFW" ]; then
    ok "cs35l45 DSP 固件已存在"
else
    warn "缺少 $CSFW（扬声器保护 DSP 固件）"
    if ls /lib/firmware/SPK1-cs35l45-dsp1-spk-prot.wmfw >/dev/null 2>&1; then
        mkdir -p /lib/firmware/cirrus
        cp /lib/firmware/SPK1-cs35l45-dsp1-spk-prot.wmfw /lib/firmware/cirrus/cs35l45-dsp1-spk-prot.wmfw
        cp /lib/firmware/SPK1-cs35l45-dsp1-spk-prot.bin  /lib/firmware/cirrus/cs35l45-dsp1-spk-prot.bin
        ok "已从 SPK1-* 复制到 /lib/firmware/cirrus/"
    else
        warn "请从 Android vendor 提取 SPK*-cs35l45-* 到 /lib/firmware/"
    fi
fi

# ---------------------------------------------------------------- 2. 脚本与服务
step "安装 q706f-audio-setup 与音量配置"

install -Dm755 "$REPO_DIR/files/usr/local/bin/q706f-audio-setup" /usr/local/bin/q706f-audio-setup
ok "/usr/local/bin/q706f-audio-setup"

if [ -f /etc/q706f-audio/speakers.conf ]; then
    warn "/etc/q706f-audio/speakers.conf 已存在，保留原值"
else
    install -Dm644 "$REPO_DIR/files/etc/q706f-audio/speakers.conf" /etc/q706f-audio/speakers.conf
    ok "/etc/q706f-audio/speakers.conf (ANALOG=1 DIGITAL=300)"
fi

install -Dm644 "$REPO_DIR/files/etc/systemd/system/q706f-audio.service" \
    /etc/systemd/system/q706f-audio.service
ok "/etc/systemd/system/q706f-audio.service"

# ---------------------------------------------------------------- 3. alsa-restore
step "屏蔽 alsa-restore.service"

if systemctl list-unit-files alsa-restore.service >/dev/null 2>&1; then
    systemctl disable --now alsa-restore.service 2>/dev/null || true
    systemctl mask alsa-restore.service 2>/dev/null || true
    ok "已 mask（alsactl store 会被 HALO_STATE 只写控件卡死）"
else
    warn "未找到 alsa-restore.service，跳过"
fi

# ---------------------------------------------------------------- 4. UCM
if [ "$SKIP_UCM" -eq 0 ]; then
    step "安装简化版 UCM"

    UCM_DIR=/usr/share/alsa/ucm2/Lenovo/q706f
    mkdir -p "$UCM_DIR"
    if [ -f "$UCM_DIR/HiFi.conf" ] && [ ! -f "$UCM_DIR/HiFi.conf.upstream" ]; then
        cp -a "$UCM_DIR/HiFi.conf" "$UCM_DIR/HiFi.conf.upstream"
        ok "已备份上游 HiFi.conf → HiFi.conf.upstream"
    fi
    install -m644 "$REPO_DIR/files/usr/share/alsa/ucm2/Lenovo/q706f/HiFi.conf" "$UCM_DIR/HiFi.conf"
    ok "$UCM_DIR/HiFi.conf（最小版，不设功放参数）"

    # conf.d 的转发文件应该已经由 alsa-ucm-conf 提供
    if [ ! -e "/usr/share/alsa/ucm2/conf.d/sm8250/Xiaoxin Pad Pro.conf" ]; then
        mkdir -p /usr/share/alsa/ucm2/conf.d/sm8250
        ln -sfn ../../Lenovo/q706f/q706f.conf \
            "/usr/share/alsa/ucm2/conf.d/sm8250/Xiaoxin Pad Pro.conf"
        ok "创建 conf.d 转发链接"
    fi
fi

# ---------------------------------------------------------------- 5. pipewire
if [ "$SKIP_PW" -eq 0 ]; then
    step "配置 wireplumber（强制 S16_LE）"

    WPD=/etc/wireplumber/wireplumber.conf.d
    mkdir -p "$WPD"
    install -m644 "$REPO_DIR/files/etc/wireplumber/wireplumber.conf.d/51-q706f-s16.conf" \
        "$WPD/51-q706f-s16.conf"
    ok "$WPD/51-q706f-s16.conf（TDM 通路只接受 16 位）"

    step "配置 pipewire（root 下需要去掉 ConditionUser=!root）"

    for u in pipewire.service pipewire.socket pipewire-pulse.service wireplumber.service; do
        d="/root/.config/systemd/user/${u}.d"
        mkdir -p "$d"
        cat > "$d/override.conf" <<'EOF'
[Unit]
ConditionUser=
EOF
        ok "$d/override.conf"
    done

    # 让 systemd --user 能看到
    if command -v systemctl >/dev/null 2>&1; then
        XDG_RUNTIME_DIR=/run/user/0 systemctl --user daemon-reload 2>/dev/null || \
            warn "systemctl --user daemon-reload 失败（登录后再执行）"
    fi
fi

# ---------------------------------------------------------------- 6. 启动
step "启用服务"

systemctl daemon-reload
systemctl enable q706f-audio.service >/dev/null 2>&1 && ok "q706f-audio.service enabled"
systemctl start  q706f-audio.service 2>&1 | tail -1
sleep 1
systemctl is-active q706f-audio.service >/dev/null && ok "q706f-audio.service 已运行" || \
    err "q706f-audio.service 启动失败，看 journalctl -u q706f-audio"

# ---------------------------------------------------------------- 7. 验证
step "验证"

if [ -f /proc/asound/card0/id ]; then
    ok "声卡 0: $(tr -d '\n' < /proc/asound/card0/id)"
else
    err "声卡 0 不存在 —— as33970 固件可能还没就位"
fi

if amixer -c 0 sget 'SPK1 Amplifier Mode' >/dev/null 2>&1; then
    A=$(amixer -c 0 sget 'SPK1 Analog PCM'  2>/dev/null | grep -oE 'Mono: [0-9]+' | head -1)
    D=$(amixer -c 0 sget 'SPK1 Digital PCM' 2>/dev/null | grep -oE 'Mono: [0-9]+' | head -1)
    P=$(amixer -c 0 sget 'SPK1 DSP1 Preload' 2>/dev/null | grep -o '\[\(on\|off\)\]')
    ok "SPK1 $A  $D  preload=$P"
else
    err "找不到 SPK 控件"
fi

cat <<EOF

$(echo "${GRN}安装完成${RST}")

下一步：
  1. 检查音量:      cat /etc/q706f-audio/speakers.conf
  2. 重新应用:      sudo q706f-audio-setup
  3. 测试（小声）:  sudo q706f-audio-setup 1 200
                    for i in 1 2 3 4; do amixer -c 0 sset "SPK\$i AMP Enable" on; done
                    speaker-test -D hw:0,0 -c2 -t wav -l1
                    for i in 1 2 3 4; do amixer -c 0 sset "SPK\$i AMP Enable" off; done
  4. 桌面音量条:    需要带音量条的 qsidebar，见 qsidebar/ 目录

$(echo "${YEL}警告：不要把 Analog 设到 3 同时 Digital 设到 409${RST}")
那是原厂满增益，低电量时四个功放会触发 PMIC 欠压保护直接黑屏死机。

EOF
