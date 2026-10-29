#!/usr/bin/env python3
"""
touchd — 触屏手势守护进程 v8  (XTEST 后端)

延迟:  xdotool 124ms  →  XTEST 1.17ms   (实测 106 倍)

v8 改动:
  * 移除所有 xdotool 子进程调用，改用 python-xlib XTEST 直连
  * 双指轻点 → 右键
  * 滚动状态机重写（不再重置 sy）
  * 三指方向修正

手势:
  单指轻点 (<350ms)        → 左键
  单指轻点                  → 左键
  双指轻点                  → 右键  ★（唯一右键途径）
  双指轻点 (<350ms)        → 右键  ★
  单指拖动 (位移>30mm)     → 拖拽
  双指上下滑               → 自然滚动
  双指捏合/张开            → Ctrl+- / Ctrl++
  三指上滑                 → 显示桌面
  三指左右滑               → 切换工作区
"""

import os
import socket
import subprocess
import sys
import threading
import time

import evdev
from evdev import ecodes

try:
    from Xlib import display as xdisplay, X, XK
    from Xlib.ext import xtest
except ImportError:
    print("需要 python-xlib:  pacman -S python-xlib", file=sys.stderr)
    sys.exit(1)

DEVICE_HINT = "Goodix"
SCREEN_W, SCREEN_H = 2560, 1600

LONG_PRESS_MS = 350        # 已废弃，长按不再出右键
TAP_MOVE = 220
DRAG_MOVE = 300
MERGE_DIST = 120
SCROLL_STEP = 70
PINCH_MIN_PX = 95          # 指间距变化 ≥9.5mm 才算捏合
PINCH_STEP_PX = 85         # 每再变 8.5mm 发一次 Ctrl+/-，实现连续缩放
PINCH_DEBOUNCE = 2         # 连续满足帧数（防抖）
AXIS_LOCK_PX = 120         # 中点位移超过 12mm 就锁死轴，之后不再改判
SWIPE3_PX = 280
MULTI_TAP_MS = 350
MULTI_TAP_MOVE = 130
DRAG_THROTTLE_MS = 8.0     # 拖动时移动事件最小间隔
QS_TOP_ZONE = 90           # 顶部下拉触发区高度 (px)
QS_PULL = 260              # 上/下滑触发距离
QS_PROC = "qsidebar"          # 进程名
QS_SIG = 10                  # SIGUSR1

DEBUG = "-v" in sys.argv


def log(*a):
    if DEBUG:
        print("[touchd]", *a, flush=True)


_QS_STATE = {"pid": None, "shown": False, "w": 0, "h": 0, "x": 0, "y": 0}


def _qs_pid():
    """找 qsidebar 的 pid"""
    try:
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open(f"/proc/{d}/comm") as f:
                    if f.read().strip() == QS_PROC:
                        return int(d)
            except Exception:
                continue
    except Exception:
        pass
    return None


def qs_send(cmd="toggle"):
    """向 qsidebar 发 SIGUSR1 切换面板"""
    pid = _QS_STATE["pid"] or _qs_pid()
    if not pid:
        log("qsidebar 未运行")
        return False
    try:
        os.kill(pid, QS_SIG)
        _QS_STATE["pid"] = pid
        log(f"→ qsidebar SIGUSR1 (pid {pid})")
        # 等动画走完再探测几何
        threading.Timer(0.45, _qs_probe).start()
        return True
    except Exception as e:
        log("qsidebar 信号失败:", e)
        _QS_STATE["pid"] = None
        return False


def _qs_probe():
    """用 xdotool 探测面板是否在屏内"""
    try:
        out = subprocess.run(
            ["xdotool", "search", "--class", "qsidebar"],
            capture_output=True, text=True, timeout=2).stdout.split()
        shown = False
        best = None
        for w in out:
            g = subprocess.run(
                ["xdotool", "getwindowgeometry", "--shell", w],
                capture_output=True, text=True, timeout=2).stdout
            env = dict(l.split("=", 1) for l in g.strip().split("\n")
                       if "=" in l)
            try:
                W = int(env.get("WIDTH", 0))
                H = int(env.get("HEIGHT", 0))
                X = int(env.get("X", 0))
                Y = int(env.get("Y", 0))
            except Exception:
                continue
            # qsidebar 会建两类窗口：
            #   真面板   710x1518
            #   透明点击层 1850x1518（占屏幕剩余宽度）
            # 必须按宽度范围锁定真面板，不能靠“取最小宽”
            if not (500 <= W <= 1200):
                continue
            if best is None or W < best[0]:
                best = (W, H, X, Y, w)

        # 宽度对了才看 X：屏内就是展开，x>=SCREEN_W 就是收起
        if best is not None:
            _W, _H, _X, _Y, _w = best
            shown = (-5 <= _X <= SCREEN_W - _W + 5)
        _QS_STATE["shown"] = shown
        if best:
            _QS_STATE["w"], _QS_STATE["h"], _QS_STATE["x"], _QS_STATE["y"] = best[:4]
        log(f"面板状态: shown={shown} geom={best[:4] if best else None}")
    except Exception as e:
        log("探测失败:", e)


def qs_visible():
    return (_QS_STATE["shown"], _QS_STATE["x"] + _QS_STATE["w"])


def qs_hide():
    """让 qsidebar 收起"""
    if _QS_STATE["shown"]:
        qs_send("toggle")
        _QS_STATE["shown"] = False
    return True


# ============================================================
#  XTEST 后端 —— 直接写 X socket，无 fork
# ============================================================
class XInjector:
    def __init__(self):
        self.d = xdisplay.Display()
        self.root = self.d.screen().root
        self._kc_cache = {}

    def keycode(self, name):
        kc = self._kc_cache.get(name)
        if kc is None:
            ks = XK.string_to_keysym(name)
            kc = self.d.keysym_to_keycode(ks)
            self._kc_cache[name] = kc
        return kc

    def move(self, x, y, sync=False):
        xtest.fake_input(self.d, X.MotionNotify, x=int(x), y=int(y))
        if sync:
            self.d.sync()

    def click(self, x, y, btn):
        xtest.fake_input(self.d, X.MotionNotify, x=int(x), y=int(y))
        xtest.fake_input(self.d, X.ButtonPress, btn)
        xtest.fake_input(self.d, X.ButtonRelease, btn)
        self.d.sync()

    def down(self, x, y, btn=1):
        xtest.fake_input(self.d, X.MotionNotify, x=int(x), y=int(y))
        xtest.fake_input(self.d, X.ButtonPress, btn)
        self.d.sync()

    def up(self, btn=1):
        xtest.fake_input(self.d, X.ButtonRelease, btn)
        self.d.sync()

    def wheel_raw(self, btn, count):
        """指定按钮的滚轮：4/5=上下，6/7=左右"""
        for _ in range(count):
            xtest.fake_input(self.d, X.ButtonPress, btn)
            xtest.fake_input(self.d, X.ButtonRelease, btn)
        self.d.sync()

    def wheel(self, up_direction, count):
        """滚动：4=上 5=下。click 序列 4 或者 5（press+release 各一次）"""
        btn = 4 if up_direction else 5
        for _ in range(count):
            xtest.fake_input(self.d, X.ButtonPress, btn)
            xtest.fake_input(self.d, X.ButtonRelease, btn)
        self.d.sync()

    def key(self, *names):
        """按下并释放组合键，如 key('Control_L','plus')"""
        kcs = [self.keycode(n) for n in names]
        for kc in kcs:
            xtest.fake_input(self.d, X.KeyPress, kc)
        for kc in reversed(kcs):
            xtest.fake_input(self.d, X.KeyRelease, kc)
        self.d.sync()


# ============================================================
#  设备 / 手指模型
# ============================================================
def find_device():
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except Exception:
            continue
        if DEVICE_HINT in d.name:
            return d
    return None


class Finger:
    __slots__ = ("x", "y", "sx", "sy", "t", "locked")

    def __init__(self, t):
        self.x = self.y = None
        self.sx = self.sy = None
        self.t = t
        self.locked = False

    def lock(self):
        if not self.locked and self.x is not None and self.y is not None:
            self.sx, self.sy = self.x, self.y
            self.locked = True

    def dist(self):
        if self.sx is None or self.x is None:
            return 0
        return max(abs(self.x - self.sx), abs(self.y - self.sy))


def merge_fingers(flist):
    if len(flist) <= 1:
        return flist
    groups, used = [], [False] * len(flist)
    for i, f in enumerate(flist):
        if used[i]:
            continue
        g = [f]
        used[i] = True
        for j in range(i + 1, len(flist)):
            if used[j] or f.x is None or flist[j].x is None:
                continue
            if max(abs(f.x - flist[j].x),
                   abs(f.y - flist[j].y)) < MERGE_DIST:
                g.append(flist[j])
                used[j] = True
        groups.append(g)
    if len(groups) == len(flist):
        return flist
    out = [g[0] for g in groups]
    log(f"合并 {len(flist)}→{len(out)} 点")
    return out


# ============================================================
#  主循环
# ============================================================
def main():
    dev = find_device()
    if not dev:
        print("找不到触屏", file=sys.stderr)
        return 1

    ax = dev.absinfo(ecodes.ABS_MT_POSITION_X)
    ay = dev.absinfo(ecodes.ABS_MT_POSITION_Y)
    rw, rh = max(1, ax.max - ax.min), max(1, ay.max - ay.min)

    def to_scr(x, y):
        if x is None or y is None:
            return (SCREEN_W // 2, SCREEN_H // 2)
        return (max(0, min(SCREEN_W - 1, int((x - ax.min) * SCREEN_W / rw))),
                max(0, min(SCREEN_H - 1, int((y - ay.min) * SCREEN_H / rh))))

    xi = XInjector()

    print(f"touchd v8: {dev.name}  {rw}x{rh}", flush=True)
    dev.grab()
    print("touchd v8: 已独占设备  (XTEST 后端)", flush=True)
    print(f"touchd v8: 双指轻点 {MULTI_TAP_MS}ms → 右键（长按已禁用）",
          flush=True)

    # 探测一下 qsidebar 是否已经开着
    _qs_probe()
    print(f"touchd v8: qsidebar shown={_QS_STATE['shown']} "
          f"geom=({_QS_STATE['x']},{_QS_STATE['y']}) "
          f"{_QS_STATE['w']}x{_QS_STATE['h']}", flush=True)

    fingers = {}
    cur_slot = 0
    st = {
        "mode": None,          # None | tap | drag | multi | swipe3
        "pinch_ref": 0.0,
        "dist0": 0.0,
        "multi_axis": None,
        "pinch_cnt": 0,
        "scroll_ref": 0.0,
        "swipe_ref": None,
        "was_multi": False,
        "multi_t": None,
        "multi_acted": False,
        "multi_moved": False,
        "multi_pos": None,
        "drag_btn_down": False,
        "last_move_ms": 0.0,
        "pull_start": None,
        "qs_start_y": None,
    }
    last = [None]

    def reset(keep_multi=False):
        st["mode"] = None
        st["pinch_ref"] = 0.0
        st["dist0"] = 0.0
        st["multi_axis"] = None
        st["pinch_cnt"] = 0
        st["scroll_ref"] = 0.0
        st["swipe_ref"] = None
        st["multi_t"] = None
        st["multi_acted"] = False
        st["multi_moved"] = False
        st["multi_pos"] = None
        st["pull_start"] = None
        st["qs_start_y"] = None
        if not keep_multi:
            st["was_multi"] = False

    try:
        for ev in dev.read_loop():
            if ev.type == ecodes.EV_ABS:
                c = ev.code
                if c == ecodes.ABS_MT_SLOT:
                    cur_slot = ev.value
                elif c == ecodes.ABS_MT_TRACKING_ID:
                    if ev.value == -1:
                        fingers.pop(cur_slot, None)
                    else:
                        fingers[cur_slot] = Finger(time.monotonic())
                elif c == ecodes.ABS_MT_POSITION_X:
                    if cur_slot in fingers:
                        fingers[cur_slot].x = ev.value
                elif c == ecodes.ABS_MT_POSITION_Y:
                    if cur_slot in fingers:
                        fingers[cur_slot].y = ev.value
                continue

            if ev.type != ecodes.EV_SYN:
                continue

            for f in fingers.values():
                f.lock()

            flist = [f for f in fingers.values() if f.locked]
            raw_n = len(flist)
            if raw_n > 1:
                flist = merge_fingers(flist)
            n = len(flist)
            now = time.monotonic()
            now_ms = now * 1000.0

            # ================= 全部抬起 =================
            if raw_n == 0:
                if st["mode"] == "qs":
                    _v, _qx2 = qs_visible()
                    if st["drag_btn_down"]:
                        xi.up(1)
                        st["drag_btn_down"] = False
                        log("面板内抬起")
                    elif not st["drag_btn_down"] and st["qs_start_y"] is not None:
                        qs_hide()
                        log("点面板外 → 收起")
                elif st["mode"] == "drag":
                    if st["drag_btn_down"]:
                        xi.up(1)
                        st["drag_btn_down"] = False
                    log("拖动结束")

                elif st["mode"] == "multi":
                    if (not st["multi_acted"] and not st["multi_moved"]
                            and st["multi_t"] is not None
                            and st["multi_pos"] is not None):
                        dur = (now - st["multi_t"]) * 1000
                        if dur < MULTI_TAP_MS:
                            cx, cy = st["multi_pos"]
                            xi.click(cx, cy, 3)
                            log(f"★★ 双指轻点 {dur:.0f}ms → 右键 @{cx},{cy}")
                        else:
                            log(f"双指 {dur:.0f}ms 太长，无动作")
                    else:
                        log(f"双指结束 (有动作={st['multi_acted']} "
                            f"有位移={st['multi_moved']})")

                elif st["mode"] == "tap" and not st["was_multi"]:
                    f = last[0]
                    if f is not None:
                        dur = (now - f.t) * 1000
                        m = f.dist()
                        sx, sy = to_scr(f.sx, f.sy)
                        if m >= TAP_MOVE:
                            log(f"无动作 (时长{dur:.0f}ms 位移{m})")
                        else:
                            # 长按不再出右键，统一当左键（右键走双指轻点）
                            xi.click(sx, sy, 1)
                            log(f"轻点 {dur:.0f}ms → 左键 @{sx},{sy} "
                                f"(位移{m})")

                last[0] = None
                reset()
                continue

            # ================= 单指 =================
            if n == 1:
                f = flist[0]
                last[0] = f
                if f.sx is None:
                    continue
                m = f.dist()
                sx0, sy0 = to_scr(f.sx, f.sy)

                # ---------- A. 面板已展开：全屏转发触摸 ----------
                _qvis, _qx = qs_visible()
                if _qvis:
                    cur_x, cur_y = to_scr(f.x, f.y)
                    if st["mode"] != "qs":
                        st["mode"] = "qs"
                        st["qs_start_y"] = cur_y
                        # 点在面板左边（面板外）→ 不转发，抬手时收起
                        if cur_x < _qx:
                            log(f"面板外按下 x={cur_x} < {_qx}，抬手收起")
                        else:
                            xi.down(cur_x, cur_y, 1)
                            st["drag_btn_down"] = True
                            log(f"面板内按下 @{cur_x},{cur_y}")
                    elif st["drag_btn_down"]:
                        if now_ms - st["last_move_ms"] >= DRAG_THROTTLE_MS:
                            xi.move(cur_x, cur_y, sync=True)
                            st["last_move_ms"] = now_ms
                    continue

                # ---------- B. 顶部下拉 → 打开面板 ----------
                if st["pull_start"] is None and sy0 <= QS_TOP_ZONE:
                    st["pull_start"] = (sx0, sy0)

                if st["pull_start"] is not None and st["mode"] == "tap":
                    if f.y - f.sy > QS_PULL:
                        if qs_send("toggle"):
                            log(f"★★ 顶部下拉 → 控制中心")
                        st["mode"] = "pulled"
                        last[0] = None
                        reset()
                        continue

                if st["mode"] is None:
                    st["mode"] = "tap"

                if st["mode"] == "tap" and m > DRAG_MOVE:
                    st["mode"] = "drag"
                    sx, sy = to_scr(f.sx, f.sy)
                    xi.down(sx, sy, 1)
                    st["drag_btn_down"] = True
                    st["last_move_ms"] = now_ms
                    log(f"拖动开始 (位移 {m})")

                elif st["mode"] == "drag":
                    if now_ms - st["last_move_ms"] >= DRAG_THROTTLE_MS:
                        sx, sy = to_scr(f.x, f.y)
                        xi.move(sx, sy, sync=True)
                        st["last_move_ms"] = now_ms
                continue

            # ================= 多指介入 =================
            if st["mode"] in ("tap", "drag"):
                if st["mode"] == "drag" and st["drag_btn_down"]:
                    xi.up(1)
                    st["drag_btn_down"] = False
                st["was_multi"] = True
                reset(keep_multi=True)
                last[0] = None

            # -------- 双指 --------
            if n == 2:
                a, b = flist
                if a.x is None or b.x is None or a.sx is None:
                    continue

                # 双指在顶部大幅下滑 → 同样开面板
                _qvis2, _qx2 = qs_visible()
                if (not _qvis2 and a.sy is not None
                        and a.sy < QS_TOP_ZONE and b.sy < QS_TOP_ZONE):
                    avg_dy = ((a.y - a.sy) + (b.y - b.sy)) / 2
                    if avg_dy > QS_PULL:
                        if qs_send("toggle"):
                            log("★★ 双指下拉 → 控制中心")
                        last[0] = None
                        reset()
                        continue
                dist = ((a.x - b.x) ** 2 + (a.y - b.y) ** 2) ** 0.5
                ady = ((a.y - a.sy) + (b.y - b.sy)) / 2      # 中点竖直位移
                adx = ((a.x - a.sx) + (b.x - b.sx)) / 2      # 中点水平位移
                mid_move = (adx * adx + ady * ady) ** 0.5

                if st["mode"] != "multi":
                    st["mode"] = "multi"
                    st["dist0"] = dist
                    st["pinch_ref"] = dist
                    st["scroll_ref"] = ady
                    st["multi_axis"] = None      # None | pinch | v | h
                    st["pinch_cnt"] = 0
                    st["multi_t"] = min(a.t, b.t)
                    st["multi_acted"] = False
                    st["multi_moved"] = False
                    st["multi_pos"] = to_scr((a.x + b.x) // 2,
                                             (a.y + b.y) // 2)
                    log(f"双指按下 @{st['multi_pos']} 间距{dist:.0f}")
                    continue

                if mid_move > MULTI_TAP_MOVE:
                    st["multi_moved"] = True

                # ===== 阶段一：尚未判定手势类型 =====
                if st["multi_axis"] is None:
                    ddist = dist - st["dist0"]
                    # 真捏合的特征：指间距显著变化，而中点几乎不动
                    if (abs(ddist) >= PINCH_MIN_PX
                            and mid_move < abs(ddist) * 0.7):
                        st["pinch_cnt"] += 1
                        if st["pinch_cnt"] >= PINCH_DEBOUNCE:
                            st["multi_axis"] = "pinch"
                            st["pinch_ref"] = dist
                            log(f"→ 捏合模式 ddist={ddist:.0f} "
                                f"mid_move={mid_move:.0f}")
                    else:
                        st["pinch_cnt"] = 0

                    # 中点走够远 → 判为滑动，永久锁死
                    if st["multi_axis"] is None and mid_move > AXIS_LOCK_PX:
                        st["multi_axis"] = ("v" if abs(ady) >= abs(adx)
                                            else "h")
                        st["scroll_ref"] = ady
                        log(f"→ 滑动模式({st['multi_axis']}) "
                            f"mid={mid_move:.0f} ddist={dist - st['dist0']:.0f}")
                    continue

                # ===== 阶段二：已锁定类型 =====
                if st["multi_axis"] == "pinch":
                    # 每变化 PINCH_STEP_PX 发一次，可连续缩放
                    n_key = 0
                    while abs(dist - st["pinch_ref"]) >= PINCH_STEP_PX and n_key < 6:
                        if dist > st["pinch_ref"]:
                            xi.key("Control_L", "plus")
                            st["pinch_ref"] += PINCH_STEP_PX
                        else:
                            xi.key("Control_L", "minus")
                            st["pinch_ref"] -= PINCH_STEP_PX
                        n_key += 1
                    if n_key:
                        st["multi_acted"] = True
                        log(f"缩放 x{n_key} dist={dist:.0f}")
                    continue

                if st["multi_axis"] == "v":
                    d = ady - st["scroll_ref"]
                    steps = int(abs(d) / SCROLL_STEP)
                    if steps:
                        up = (d > 0)   # 手指下滑 → 内容上移 → 滚轮「上」
                        xi.wheel(up, steps)
                        st["multi_acted"] = True
                        st["scroll_ref"] += steps * SCROLL_STEP * (1 if d > 0 else -1)
                        log(f"滚动({'上' if up else '下'}) x{steps} "
                            f"ady={ady:.0f}")
                    continue

                if st["multi_axis"] == "h":
                    d = adx - st["scroll_ref"]
                    steps = int(abs(d) / SCROLL_STEP)
                    if steps:
                        btn = 6 if d > 0 else 7   # 6=左 7=右
                        xi.wheel_raw(btn, steps)
                        st["multi_acted"] = True
                        st["scroll_ref"] += steps * SCROLL_STEP * (1 if d > 0 else -1)
                        log(f"横滚 x{steps} adx={adx:.0f}")
                    continue

            # -------- 三指 --------
            if n == 3:
                if any(x.x is None for x in flist):
                    continue
                cx = sum(x.x for x in flist) / 3
                cy = sum(x.y for x in flist) / 3

                if st["mode"] != "swipe3":
                    st["mode"] = "swipe3"
                    st["swipe_ref"] = (cx, cy)
                    log("三指按下")
                    continue

                dx = cx - st["swipe_ref"][0]
                dy = cy - st["swipe_ref"][1]

                if abs(dx) > SWIPE3_PX and abs(dx) > abs(dy):
                    # 手指右滑 → 露出左边工作区
                    if dx > 0:
                        xi.key("Control_L", "Alt_L", "Left")
                    else:
                        xi.key("Control_L", "Alt_L", "Right")
                    log(f"三指横滑 dx={dx:.0f} → "
                        f"{'左' if dx > 0 else '右'}工作区")
                    last[0] = None
                    reset()

                elif dy < -SWIPE3_PX:
                    xi.key("Control_L", "Alt_L", "d")
                    log("三指上滑 → 桌面")
                    last[0] = None
                    reset()
                continue

    except KeyboardInterrupt:
        pass
    finally:
        try:
            if st["drag_btn_down"]:
                xi.up(1)
            dev.ungrab()
        except Exception:
            pass
        dev.close()
        print("touchd: 已释放", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
