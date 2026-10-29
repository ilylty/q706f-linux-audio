# q706f-linux-audio

Lenovo Xiaoxin Pad Pro 12.6 (`lenovo-q706f`, SM8250-AC / Snapdragon 870) 在 mainline Linux 上的**音频（4× CS35L45 扬声器）** 完整可用配置，附带桌面控制中心（qsidebar）扩展补丁。

配套仓库：[ilylty/marble-q706f-mmc](https://github.com/ilylty/marble-q706f-mmc)（内核 MMC 修复 + 构建流水线）

---

## 硬件构成

| 器件 | 型号 | I²C 地址 | 角色 |
|---|---|---|---|
| 扬声器功放 ×4 | Cirrus Logic CS35L45 | `5-0030` `5-0031` `5-0036` `5-0037` | 4 声道 Smart Amp |
| 麦克风阵列 DSP | Synaptics AS33970 | `5-0041` | Senary capture DAI 的 codec |
| 音频编解码 | Qualcomm WCD938x | SoundWire `sdw:2/3:0:0217:010d` | 耳机 / 麦克风 |
| 音频 DSP | ADSP (q6afe/q6asm) | — | TDM / MI2S 路由 |

**扬声器走 Primary TDM（`PRIMARY_TDM_RX_0`）→ ASP → 4 个 CS35L45。**

---

## 三个必须解决的坑（按顺序）

### 坑 1：AS33970 缺固件 → 整个声卡 probe 失败

**症状**

```
as33970 5-0041: loading as33970/partition_boot2flash.img
as33970 5-0041: Direct firmware load for as33970/partition_boot2flash.img failed with error -2
as33970 5-0041: probe with driver as33970 failed with error -2
...
platform sound: deferred probe pending: snd-sm8250: SENARY Capture: codec dai not found
```

`/proc/asound/cards` 为空，`/dev/snd` 只有 `timer`。

**原因**：DT 里 `senary-capture-dai-link` 的 codec 是 `syna,as33970`。它 probe 失败 → DAI 找不到 → **整张声卡卡在 deferred probe**。

**修复**：从 Android `vendor` 分区提取固件。

```bash
# vendor_a 在 super (sda17) 里
lpunpack -p vendor_a /dev/disk/by-partlabel/super /tmp/lp
mount -o ro /tmp/lp/vendor_a.img /mnt/vend
mkdir -p /lib/firmware/as33970
cp /mnt/vend/firmware/partition_boot2flash.img /lib/firmware/as33970/

# 重新绑定
echo 5-0041 > /sys/bus/i2c/drivers/as33970/unbind
echo 5-0041 > /sys/bus/i2c/drivers/as33970/bind
```

成功标志：

```
as33970 5-0041: firmware 4.17.8.0
 0 [Pro            ]: sm8250 - Xiaoxin Pad Pro
```

固件 md5：`dddffcaabec49395d5685c1149a6546f`（438,272 字节）

### 坑 2：CS35L45 的 DSP 没 preload → 完全没声音（但一切"看起来正常"）

**症状**：`aplay` 不报错、路由 `on`、电量不变、`dmesg` 一片干净——**就是没声**。

**原因**：`SPKx DSP1 Preload Switch` 是关着的。不开它，DSP 固件不加载，`DACPCM Source = ASP_RX1` 指向的通道是空的，功放收到全 0。

**修复**：打开 preload，然后 dmesg 应该吐出：

```
cs35l45 5-0030: DSP1: cirrus/cs35l45-dsp1-spk-prot.wmfw: format 3 timestamp 0x607d6ac4
cs35l45 5-0030: DSP1: Firmware: 4fa00 vendor: 0x2 v0.37.0, 5 algorithms
cs35l45 5-0030: DSP1: Protection: C:\Working\Project\P12 PRO\2021-08-16-new speaker 038\BOX1 MUSIC\SPK1-cs35l45-dsp1-spk-prot.bin
```

**注意固件名**：驱动会先从 `/lib/firmware/cirrus/` 找 `cs35l45-dsp1-spk-prot.wmfw`（不带 SPK 号）。

从 Android vendor 提取：

```bash
cp /mnt/vend/firmware/SPK*-cs35l45-* /lib/firmware/
mkdir -p /lib/firmware/cirrus
# 驱动默认路径（不带编号）
cp /mnt/vend/firmware/SPK1-cs35l45-dsp1-spk-prot.wmfw /lib/firmware/cirrus/cs35l45-dsp1-spk-prot.wmfw
cp /mnt/vend/firmware/SPK1-cs35l45-dsp1-spk-prot.bin  /lib/firmware/cirrus/cs35l45-dsp1-spk-prot.bin
```

### 坑 2.5：pipewire 默认 S24_LE，TDM 通路无声

**症状**：`aplay -D hw:0,0` 直连有声音，`paplay` / Firefox 走 pipewire **完全没声音**，但 sink 状态是 `RUNNING`、无任何报错。

**原因**：pipewire 的 SPA ALSA 用 **MMAP** 打开设备，**绕过 ALSA 的格式协商**。它挑了 `S24_LE`：

```
Sample Specification: s24-32le 2ch 48000Hz
hw_params: format: S24_LE
```

但这个声卡**硬件只支持 S16_LE**，用 `aplay` 手动指定会看到：

```
$ aplay -D hw:0,0 -f S24_LE ...
Warning: format is changed to S16_LE
$ aplay -D hw:0,0 -f S32_LE ...
Warning: format is changed to S16_LE
```

**MMAP 下发 S24_LE 时硬件不报错，但 TDM 总路上的数据位错位，DSP 读到的是垃圾 → 静音。**

**修复**：强制 pipewire 用 S16_LE。

```ini
# /etc/wireplumber/wireplumber.conf.d/51-q706f-s16.conf
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        audio.format = "S16LE"
        audio.rate = 48000
        audio.channels = 2
        audio.position = "FL,FR"
      }
    }
  }
]
```

改完 `systemctl --user restart pipewire wireplumber`，sink 会变成 `s16le 2ch 48000Hz`。

**验证是否格式问题**：播放时看 `/proc/asound/card0/pcm0p/sub0/hw_params` 里的 `format:` 字段。

### 坑 3：满增益四喇叭会拉垮电池 → 黑屏死机

**血泪教训**：把 `Analog PCM` 设成 3（19 dB）+ `Digital PCM` 设成 409（0 dB），四个功放一起响，**电池 3.89 V 时直接触发 PMIC 欠压保护，屏幕瞬间黑掉**。

**硬件增益范围**

| 控件 | 范围 | 含义 |
|---|---|---|
| `SPKx Analog PCM` | 0–3 | 10 / 13 / 16 / **19 dB** |
| `SPKx Digital PCM` | 0–457 | 0=静音，409=0 dB，457=+2 dB |

**原厂 UCM（postmarketOS）用的是 Analog=3 / Digital=409**，那是满功率，**在充电不足或低电量时会死机**。

**本仓库的默认值：`Analog=1`（13 dB）+ `Digital=300`（−27 dB）**，总衰减约 −33 dB，功率降到约 1/2000。四喇叭齐响实测电压不降反升，稳定。

---

## 快速安装

```bash
git clone https://github.com/ilylty/q706f-linux-audio
cd q706f-linux-audio
sudo ./install.sh
```

`install.sh` 会：

1. 检查固件是否就位（缺失则提示从 Android 分区提取）
2. 安装 `/usr/local/bin/q706f-audio-setup`
3. 安装 `/etc/q706f-audio/speakers.conf`（可编辑音量）
4. 安装 `/etc/systemd/system/q706f-audio.service` 并 enable
5. 安装简化版 UCM 到 `/usr/share/alsa/ucm2/Lenovo/q706f/`
6. **安装 `/etc/wireplumber/wireplumber.conf.d/51-q706f-s16.conf`（强制 S16_LE）**
7. mask 掉会被 HALO_STATE 卡住的 `alsa-restore.service`
8. 给 pipewire 的 systemd 单元加 `ConditionUser=` override（root 身份必需）

---

## 音量调整

编辑 `/etc/q706f-audio/speakers.conf`：

```ini
ANALOG=1          # 0..3  → 10/13/16/19 dB
DIGITAL=300       # 0..457 → 300 ≈ -27dB
```

然后：

```bash
sudo q706f-audio-setup          # 重新应用
# 或临时覆盖
sudo q706f-audio-setup 1 350    # Analog=1, Digital=350
```

**建议的调整顺序**：先把 `DIGITAL` 一格一格加到 350、380，**最后才动 `ANALOG`**。

### 常开的功放

```ini
ALWAYS_ON="2 4"     # 留空则 4 个都只在播放时开
```

**物理箱体编号和软件编号是交叉的**（从 DSP 固件加载日志可见）：

| DTS prefix | I²C | 物理箱体 |
|---|---|---|
| SPK1 | `5-0030` | BOX1 MUSIC |
| SPK2 | `5-0031` | BOX2 MUSIC |
| **SPK3** | `5-0036` | **BOX4 music** |
| **SPK4** | `5-0037` | **BOX3 MUSIC** |

所以“左右各一个”不能简单按 SPK1+SPK3 配，需要按 BOX 编号对应。

**桌面控制中心的音量条上限锁在 70%**（qsidebar 补丁 `MAX_VOLUME_PCT`），这是软件层；硬件层 `Analog` 和 `Digital` 是固定的，两道闸门互不冲突。

---

## UCM 为什么是"简化版"

`alsa-ucm-conf` 自带的 `Lenovo/q706f/HiFi.conf`（来自 postmarketOS 的 `device-lenovo-q706f`，作者 chalkin）**在 alsa-lib 1.2.16.1 上跑不通**：

```
ALSA lib main.c:843:(execute_sequence) [error.ucm] unable to execute cset
    'name='SPK1 DSP1 Preload' on'
alsaucm: error failed to set _verb=HiFi: No such file or directory
```

**同一个控件用 `amixer sset` 手动设置完全正常**，但 UCM 的 `cset` 执行失败。我试过 `'1'`、`'on'`、`'off'` 三种写法，全部失败；而 `'PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1' 1` 这种控件能过——**区别在于它是不是 pswitch 类型**。

**所以本仓库的 UCM 只保留最小内容**（verb + pointer 路由），所有功放参数交给 `q706f-audio-setup` 脚本。这样 wireplumber 能正常建 sink，功放状态由 systemd 服务保证。

**副作用**：pipewire 的音量条控制的是**软件音量**，不是硬件增益。这其实是好事——硬件增益锁死在安全值，软件音量随便调。

---

## 为什么不用 alsactl

```
alsactl: get_control:282: Cannot read control
    '2,0,0,SPK1 DSP1 Protection 4fa00 HALO_STATE,0': Operation not permitted
```

`SPK1 DSP1 Protection 4fa00 HALO_STATE` 是 DSP 固件加载后动态创建的**只写**控件，`alsactl store` 用 numid 枚举时碰到它就直接失败（整个 store 中止，不生成 state 文件）。

所以用自写的 `q706f-audio-setup` 脚本，**只碰我们关心的控件**，不会踩到它。

---

## pipewire 在 root 下不启动

Arch 的 `/usr/lib/systemd/user/pipewire.service` 有：

```ini
ConditionUser=!root
```

**root 身份下会被直接跳过**，`systemctl --user start` 无效。修复：

```ini
# /root/.config/systemd/user/pipewire.service.d/override.conf
[Unit]
ConditionUser=
```

`pipewire.socket`、`pipewire-pulse`、`wireplumber` 同样需要。

---

## qsidebar 扩展补丁

`qsidebar/q706f-features.patch` 给 [seb3773/qsidebar](https://github.com/seb3773/qsidebar) 加了 **17 处改动**：

### 动态按钮文字（8 处）

新增两个配置键：

```ini
button_11_label_cmd=slot_label.sh        # 相对 SCRIPT_PATH，或写绝对路径
button_11_label_interval=10              # 刷新间隔（秒，1–3600）
```

命令的输出会贴到按钮文字上，定时刷新。脚本输出一行文字即可，支持中文和 emoji。

**限制**：每个按钮的标签宽度上限 11 字符，**能放一行就一行，放不下折两行，两行还放不下加省略号**。

### 网格对齐（3 处）

按钮和 spacer 的 `gtk_box_pack_start` 从 `FALSE, FALSE` 改成 `TRUE, TRUE`。

**原因**：`fill=FALSE` 会让按钮用内容宽度，不同长度的标签把每行撑成不同宽度，行与行之间就不对齐了。

### 两行文本（4 处）

```c
gtk_label_set_line_wrap(label, TRUE);
gtk_label_set_lines(label, 2);
gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END);
gtk_label_set_max_width_chars(label, 11);
gtk_label_set_line_wrap_mode(label, PANGO_WRAP_WORD_CHAR);   // 中文按字断行
```

`PANGO_WRAP_WORD_CHAR` 是关键——中文没有空格，`PANGO_WRAP_WORD` 找不到断点就不换行。

按钮高度从 `button_width * 5 / 6` 改成 `4 / 5`，给两行文字留空间。

### 音量滑动条（3 处）

`MAX_VOLUME_PCT = 70.0`，拖动超过自动弹回。放在背光条下面，走 `pactl set-sink-volume`。

### 编译

```bash
cd qsidebar
gcc -DWITHOUT_DCOP -O2 -DNDEBUG \
    -o qsidebar qsidebar.c \
    $(pkg-config --cflags --libs libnm gtk+-3.0 libcanberra-gtk3 gio-2.0 glib-2.0 x11 xrandr) \
    -lnotify -ldbus-1 -lm -pthread
sudo install -m755 qsidebar /usr/local/bin/
```

**必须先 `pkill qsidebar` 再 `rm` 再 `cp`**，否则会报"文本文件忙"。

---

## qsidebar 其它已知问题

| 问题 | 症状 | 修复 |
|---|---|---|
| `option_dark_mode=1` | SIGSEGV（`gdk_pixbuf_get_width` 收 NULL，源头 `invert_pixbuf_colors` 对无 alpha 图标返回 NULL） | 别用，改 `option_tint` |
| 配置路径写死 | 源码里是 `/home/%s/.qsidebar/`，`$HOME` 不生效 | `ln -sfn /root/.qsidebar /home/root/.qsidebar` |
| 与 xfce4-notifyd 冲突 | `Not primary owner of org.freedesktop.Notifications` 直接退出 | `pkill xfce4-notifyd` + autostart 加 `Hidden=true` |

---

## 硬件参数速查

```
声卡        card 0 "Xiaoxin Pad Pro" (sm8250-sndcard)
PCM         MultiMedia1-4 (hw:0,0 到 hw:0,3)，playback + capture
路由        PRIMARY_TDM_RX_0 Audio Mixer MultiMediaN
功放        SPK1-4，各 4 个 ASP_TX + 8 个 DSP_RX 源
DSP 固件    Protection（4fa00 v0.37.0，联想 P12 PRO 原厂）
```

**ASP 通道分配**（来自上游 UCM，勿改）

| 功放 | DACPCM Source | ASPRX1 Slot | ASPRX2 Slot |
|---|---|---|---|
| SPK1 | ASP_RX1 | 0 | 1 |
| SPK2 | ASP_RX1 | 0 | 1 |
| SPK3 | ASP_RX2 | 0 | 2 |
| SPK4 | ASP_RX2 | 0 | 2 |

---

## 麦克风 / 耳机

**未验证。** WCD938x 已 bound（`sdw:2:0` / `sdw:3:0`），但：

- DT 里 `wcd-playback-dai-link` / `wcd-capture-dai-link` 在 silime 的 DTS 里被注释掉了
- 我们刷的 DTB 里存在 `wcd-capture-dai-link`，但 `/dev/snd` 里没有对应 PCM
- `wcd938x_codec audio-codec: missing qcom,mbhc-buttons-vthreshold-microvolt entry` —— DT 缺这个属性

要支持耳机/麦克风，需要改 DTB 补全 `wcd938x` 节点和对应的 dai-link。

---

## 许可

配置文件和脚本：MIT

`qsidebar/q706f-features.patch`：随上游 qsidebar（MIT）

固件（`partition_boot2flash.img`、`cs35l45-dsp1-spk-*`）**不在本仓库**，版权属联想/Cirrus Logic，需从你自己的设备分区提取。
