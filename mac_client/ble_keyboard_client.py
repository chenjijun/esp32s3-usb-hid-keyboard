#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
控制端程序 —— ESP32-S3 无线键盘桥（Python 版，macOS / Windows 通用）

功能与 mac_swift/ 里的 Swift 版对齐：

  · 双链路：蓝牙 BLE 与 Wi-Fi TCP 二选一，和固件的 BOOT 键切换对应
  · 连接阶段可见：扫描 / 连接 / 超时倒计时，随时可以「停止」
  · 屏幕键盘：粘滞修饰键，点击走 DOWN → 30ms → UP（和本机转发同一条路径）
  · 鼠标：拖拽区移动指针 + 左中右三键 + 滚轮 + 「按住左键」+ 速度倍率
  · BIOS 引导键：写进固件（NVS 掉电保持）、立即连发、查询当前值
  · 本机键盘转发：整块键盘接管，修饰键镜像（Windows 上能切输入法），
    Ctrl+Alt+Esc 紧急停止
  · 日志面板：显示固件回执（PONG / BOOTKEY:…）与错误

两个平台的差异只在本机键盘转发这一层：
    macOS   CGEventTap（需要 pyobjc + 辅助功能授权）
    Windows SetWindowsHookEx(WH_KEYBOARD_LL)（ctypes 直接调，无需额外依赖/授权）

用法：
    python3 ble_keyboard_client.py                     # 图形界面
    python3 ble_keyboard_client.py --cli               # 命令行，逐行输入协议命令
    python3 ble_keyboard_client.py --cli --mode wifi   # 走 Wi-Fi
    python3 ble_keyboard_client.py --name XXX          # 指定 BLE 设备名

依赖：
    pip3 install -r requirements.txt
    bleak                    必需（蓝牙链路）
    pyobjc-framework-Quartz  仅 macOS，只用于「本机键盘转发」
"""

import argparse
import asyncio
import ctypes
import math
import os
import queue
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import tkinter as tk
    from tkinter import font as tkfont
    from tkinter import messagebox, ttk
except ImportError:      # 允许在无 tkinter 的环境下使用 --cli
    tk = None
    tkfont = None

IS_WIN = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"

# 紧急停止组合键：两个平台上分别是 ⌃⌥Esc 和 Ctrl+Alt+Esc
STOP_COMBO = "Ctrl+Alt+Esc" if IS_WIN else "⌃⌥Esc"

# 界面字体：macOS 用 Helvetica/Menlo（和预览图一致），Windows 用系统自带的
# 中文字体，否则中文标签会落到没有中文字形的西文字体上。
UI_FAMILY = "Helvetica"
MONO_FAMILY = "Menlo"

try:
    import Quartz
except Exception:        # noqa: BLE001  pyobjc 未安装时只影响「本机键盘转发」
    Quartz = None

# AXIsProcessTrusted 在 HIServices 里，属于 ApplicationServices 框架；
# 少数老的 pyobjc 把它挂在 Quartz 下，两个都试一下。
try:
    import ApplicationServices as AXKit
except Exception:        # noqa: BLE001
    AXKit = None


# ---------------------------------------------------------------------------
# 一、协议层：与固件 esp32s3_ble_keyboard.ino 保持一致的命令格式与键名
# ---------------------------------------------------------------------------
SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
RX_UUID = "12345678-1234-5678-1234-56789abcdef1"   # 写入命令
TX_UUID = "12345678-1234-5678-1234-56789abcdef2"   # 通知回执（PONG / BOOTKEY）

DEFAULT_NAME = "ESP32-Keyboard"
DEFAULT_HOST = "192.168.4.1"      # 固件开的热点网关地址
DEFAULT_PORT = 8266
HOTSPOT_NAME = "ESP32-Keyboard"

WRITE_CHUNK = 20                  # 按最小 MTU(23) 保守分片
KEY_HOLD = 0.030                 # 屏幕键盘：按下到松开的间隔（秒）

# 连接阶段的超时与重试（与 Swift 版 Timing 一致）
SCAN_TIMEOUT = 12.0
CONNECT_TIMEOUT = 20.0
WIFI_TIMEOUT = 12.0
MAX_RETRIES = 2
RETRY_GAP = 2.0

TCC_HINT = (
    "macOS 拦住了蓝牙访问：当前进程所属的 App 没有蓝牙用途声明，"
    "系统会直接杀掉进程，所以窗口一闪就没了（这不是代码 bug）。\n\n"
    "请双击项目里的 ESP32Keyboard.app 启动；\n"
    "若还没有它，先运行 mac_client/build_app.sh 生成。"
)

# 被系统强杀的退出码（Windows 上没有 SIGKILL 这个常量，用 getattr 兜一下）
_KILLED_CODES = tuple(getattr(signal, name) for name in ("SIGKILL", "SIGABRT")
                      if hasattr(signal, name))


class Cmd:
    """协议命令的拼装。固件按 ASCII 行解析，行尾用 \\n 分帧。"""

    @staticmethod
    def tap(token):
        return f"TAP:{token}"

    @staticmethod
    def down(token):
        return f"DOWN:{token}"

    @staticmethod
    def up(token):
        return f"UP:{token}"

    @staticmethod
    def type_text(text):
        return f"TYPE:{text}"

    @staticmethod
    def combo(tokens):
        return "COMBO:" + "+".join(tokens)

    RELEASE_ALL = "RELEASEALL"
    PING = "PING"

    # 开机引导键（写固件 NVS）
    @staticmethod
    def boot_key(token):
        return f"BOOTKEY:{token}"

    BOOT_KEY_QUERY = "BOOTKEY:?"
    BOOT_KEY_NOW = "BOOTKEY:now"

    # 鼠标：同一个 HID 接口下的第二个 report（ID 2），dx/dy 是 int8，单条 ±127
    @staticmethod
    def mouse_move(dx, dy):
        return f"MOUSE:move {dx} {dy}"

    @staticmethod
    def mouse_wheel(n):
        return f"MOUSE:wheel {n}"

    @staticmethod
    def mouse_down(button):
        return f"MOUSE:down {button}"

    @staticmethod
    def mouse_up(button):
        return f"MOUSE:up {button}"

    @staticmethod
    def mouse_click(button):
        return f"MOUSE:click {button}"

    MOUSE_RELEASE = "MOUSE:release"


# Mac 虚拟键码（kVK_*）→ 协议键名。
# 刻意用固定 US 布局表（而不是读本机布局）：被控主机也按 US 布局解释，
# 两边一致才不会串字符。
KEY_TOKENS = {
    # 字母
    0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
    34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
    12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
    16: "y", 6: "z",
    # 数字与符号
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
    26: "7", 28: "8", 25: "9",
    27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
    43: ",", 47: ".", 44: "/", 50: "`",
    # 编辑与导航
    36: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
    53: "esc", 114: "insert", 115: "home", 119: "end",
    116: "pageup", 121: "pagedown", 57: "capslock",
    123: "left", 124: "right", 125: "down", 126: "up",
    110: "menu",
    # 功能键
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
    98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    105: "f13", 107: "f14", 113: "f15", 106: "f16",
    64: "f17", 79: "f18", 80: "f19", 90: "f20",
    # 小键盘
    82: "kp0", 83: "kp1", 84: "kp2", 85: "kp3", 86: "kp4",
    87: "kp5", 88: "kp6", 89: "kp7", 91: "kp8", 92: "kp9",
    65: "kpdot", 67: "kpasterisk", 69: "kpplus", 78: "kpminus",
    75: "kpslash", 76: "kpenter", 81: "kpequals",
}

MODIFIER_CLASSES = ("shift", "ctrl", "alt", "cmd")

# 语义类 → 默认用哪一侧（真实键盘左右各一个，Windows 只关心有没有按下）
DEFAULT_MOD_TOKEN = {
    "shift": "lshift", "ctrl": "lctrl", "alt": "lalt", "cmd": "lcmd",
}

# flagsChanged 的 keyCode 就是修饰键本身，用它区分左右
SIDE_KEY_TOKENS = {
    56: "lshift", 60: "rshift",
    59: "lctrl", 62: "rctrl",
    58: "lalt", 61: "ralt",
    55: "lcmd", 54: "rcmd",
}

CLASS_OF_TOKEN = {
    "lshift": "shift", "rshift": "shift",
    "lctrl": "ctrl", "rctrl": "ctrl",
    "lalt": "alt", "ralt": "alt",
    "lcmd": "cmd", "rcmd": "cmd",
}


def _build_vk_table():
    """Windows 虚拟键码（VK_*）→ 协议键名。

    和上面的 Mac 表一样是固定 US 布局：被控主机按 US 布局解释键码，
    两边一致才不会串字符。固件只认 f1..f12，所以 F13 以上故意不映射
    （按了会放行给本机，不会被吞掉也没反应）。
    """
    table = {
        0x08: "backspace", 0x09: "tab", 0x0D: "enter", 0x13: "pause",
        0x14: "capslock", 0x1B: "esc", 0x20: "space",
        0x21: "pageup", 0x22: "pagedown", 0x23: "end", 0x24: "home",
        0x25: "left", 0x26: "up", 0x27: "right", 0x28: "down",
        0x2C: "printscreen", 0x2D: "insert", 0x2E: "delete",
        0x5D: "menu", 0x90: "numlock", 0x91: "scrolllock",
        # 符号键（US 布局）
        0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/",
        0xC0: "`", 0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
        # 小键盘符号
        0x6A: "kpasterisk", 0x6B: "kpplus", 0x6D: "kpminus",
        0x6E: "kpdot", 0x6F: "kpslash",
    }
    for i in range(10):
        table[0x30 + i] = str(i)               # 主键盘 0-9
        table[0x60 + i] = f"kp{i}"             # 小键盘 0-9
    for i in range(26):
        table[0x41 + i] = chr(ord("a") + i)    # A-Z
    for i in range(12):
        table[0x70 + i] = f"f{i + 1}"          # F1-F12
    return table


VK_TO_TOKEN = _build_vk_table()


def _win_modifier_token(vk, scan, flags):
    """Windows 修饰键 → 侧别 token（lshift/rshift/…），不是修饰键返回 None。

    LL 钩子一般直接给 VK_LSHIFT / VK_RCONTROL 这类分左右的码；
    偶尔只给通用的 VK_SHIFT / VK_CONTROL，这时靠扫描码和扩展位判左右。
    """
    simple = {
        0xA0: "lshift", 0xA1: "rshift",
        0xA2: "lctrl", 0xA3: "rctrl",
        0xA4: "lalt", 0xA5: "ralt",
        0x5B: "lcmd", 0x5C: "rcmd",
    }
    if vk in simple:
        return simple[vk]
    extended = bool(flags & 0x01)              # LLKHF_EXTENDED
    if vk == 0x10:                             # VK_SHIFT
        return "rshift" if scan == 0x36 else "lshift"
    if vk == 0x11:                             # VK_CONTROL
        return "rctrl" if extended else "lctrl"
    if vk == 0x12:                             # VK_MENU
        return "ralt" if extended else "lalt"
    return None

# CGEventFlags 的四个修饰位（与 Quartz 常量等值，避免依赖常量是否存在）
FLAG_SHIFT = 0x00020000
FLAG_CONTROL = 0x00040000
FLAG_ALTERNATE = 0x00080000
FLAG_COMMAND = 0x00100000


class ModifierMirror:
    """把「系统当前的修饰键状态」翻译成需要发出去的 DOWN/UP。

    每次都按 flags 做全量对齐，而不是只处理变化的那一个键：
    这样即使某个 keyUp 丢了，下一个事件也会自动纠正，不会留下卡住的 Ctrl。
    这一段是「Windows 上能不能切输入法」的全部逻辑，且不碰事件 tap，
    可以脱离键盘权限单独测试。
    """

    def __init__(self):
        self.tokens = {}

    def reset(self):
        self.tokens.clear()

    def sync(self, shift, control, alt, cmd, side_token=None):
        """返回 (要松开的 token 列表, 要按下的 token 列表)。先松后按。

        side_token 是「刚刚变化的修饰键」的侧别 token（lshift/rctrl/…），
        用它决定按下哪一侧；两个平台传进来的是同一种 token。
        """
        want = set()
        if shift:
            want.add("shift")
        if control:
            want.add("ctrl")
        if alt:
            want.add("alt")
        if cmd:
            want.add("cmd")

        release = []
        press = []

        for cls in MODIFIER_CLASSES:
            if cls in self.tokens and cls not in want:
                release.append(self.tokens.pop(cls))

        for cls in MODIFIER_CLASSES:
            if cls in want and cls not in self.tokens:
                token = DEFAULT_MOD_TOKEN[cls]
                if side_token and CLASS_OF_TOKEN.get(side_token) == cls:
                    token = side_token
                press.append(token)
                self.tokens[cls] = token

        return release, press


# 屏幕键盘布局：(显示文字, 发送的键名)
KB_ROWS = [
    [("esc", "esc"), ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"), ("5", "5"),
     ("6", "6"), ("7", "7"), ("8", "8"), ("9", "9"), ("0", "0"), ("-", "-"),
     ("=", "="), ("⌫", "backspace")],
    [("tab", "tab"), ("q", "q"), ("w", "w"), ("e", "e"), ("r", "r"), ("t", "t"),
     ("y", "y"), ("u", "u"), ("i", "i"), ("o", "o"), ("p", "p"), ("[", "["),
     ("]", "]"), ("\\", "\\")],
    [("caps", "capslock"), ("a", "a"), ("s", "s"), ("d", "d"), ("f", "f"),
     ("g", "g"), ("h", "h"), ("j", "j"), ("k", "k"), ("l", "l"), (";", ";"),
     ("'", "'"), ("⏎", "enter")],
    [("⇧", "shift"), ("z", "z"), ("x", "x"), ("c", "c"), ("v", "v"), ("b", "b"),
     ("n", "n"), ("m", "m"), (",", ","), (".", "."), ("/", "/"), ("⇧", "shift")],
    [("ctrl", "ctrl"), ("⌥", "alt"), ("⌘", "cmd"), ("space", "space"),
     ("⌘", "cmd"), ("⌥", "alt"), ("←", "left"), ("↓", "down"), ("↑", "up"),
     ("→", "right")],
]

MODIFIER_TOKENS = {"shift", "ctrl", "alt", "cmd"}

# 本机（macOS）常用快捷键
PRESETS_MAC = [
    ("复制", ["cmd", "c"]), ("粘贴", ["cmd", "v"]), ("剪切", ["cmd", "x"]),
    ("撤销", ["cmd", "z"]), ("全选", ["cmd", "a"]), ("保存", ["cmd", "s"]),
    ("查找", ["cmd", "f"]), ("新建", ["cmd", "n"]), ("关闭窗口", ["cmd", "w"]),
    ("切换窗口", ["cmd", "tab"]), ("聚焦搜索", ["cmd", "space"]),
    ("区域截图", ["cmd", "shift", "4"]), ("全屏截图", ["cmd", "shift", "3"]),
    ("锁屏", ["ctrl", "cmd", "q"]),
]

# Windows 上的常用键：cmd(⌘) 在主机侧就是 Win 键，⌘Space 发过去是 Win+Space，
# 正是 Windows 11 切换输入法的默认热键。
PRESETS_WIN = [
    ("切换输入法", ["win", "space"]),
    ("中英切换", ["ctrl", "space"]),
    ("Shift 中英", ["shift"]),
    ("布局切换", ["ctrl", "shift"]),
    ("复制", ["ctrl", "c"]), ("粘贴", ["ctrl", "v"]), ("剪切", ["ctrl", "x"]),
    ("撤销", ["ctrl", "z"]), ("全选", ["ctrl", "a"]), ("保存", ["ctrl", "s"]),
    ("切换窗口", ["alt", "tab"]), ("关闭窗口", ["alt", "f4"]),
    ("任务管理器", ["ctrl", "shift", "esc"]),
    ("显示桌面", ["win", "d"]), ("资源管理器", ["win", "e"]), ("运行", ["win", "r"]),
    ("设置", ["win", "i"]), ("锁定", ["win", "l"]), ("搜索", ["win", "s"]),
    ("截图", ["win", "shift", "s"]), ("表情符号", ["win", "."]),
]

# BIOS / UEFI 启动键：客户端可以写进固件，让板子上电后自己连发
BIOS_KEYS = [
    ("Del", "delete"), ("F2", "f2"), ("F10", "f10"), ("F12", "f12"),
    ("F1", "f1"), ("F8", "f8"), ("Esc", "esc"), ("关闭", "off"),
]


# ---------------------------------------------------------------------------
# 二、链路层：BLE 与 Wi-Fi TCP 对上层是同一套接口
# ---------------------------------------------------------------------------
class Link:
    """两种链路二选一，接口一致：connect / cancel / disconnect / send。

    回调通过 emit 投递事件，worker 线程不直接碰界面：
        ("log", 文本, 是否错误)
        ("state", 状态名, 文案)
    状态名：idle / scanning / connecting / connected / failed
    倒计时由界面按 phase_start / phase_total 自己算，这里只负责记录。
    """

    def __init__(self, emit):
        self.emit = emit
        self.kind = "ble"
        self.state = "idle"
        self.state_text = "未连接"
        self.connected = False
        self.phase_start = 0.0
        self.phase_total = 0.0
        self.fail_reason = ""

        self._want = False
        self._stop = threading.Event()
        self._gen = 0
        self._sock = None
        self._sock_lock = threading.Lock()
        self._client = None
        self._loop = None
        self._ble_lock = None          # asyncio.Lock，只能在使用它的 loop 里建
        self._drop_at = 0.0
        self._attempt_thread = None
        self._probe_done = None        # None 未探测 / True 被拦 / False 可用

    # -- 对外接口 ---------------------------------------------------------
    def connect(self, kind="ble", name=DEFAULT_NAME, host=DEFAULT_HOST, port=DEFAULT_PORT):
        self.cancel(quiet=True)
        self.kind = kind
        self._want = True
        self._stop.clear()
        self._gen += 1
        gen = self._gen
        self._attempt_thread = threading.Thread(
            target=self._run_attempts, args=(gen, kind, name, host, int(port)), daemon=True)
        self._attempt_thread.start()

    def cancel(self, quiet=False):
        self._want = False
        self._stop.set()
        self._gen += 1                      # 让还在跑的 worker 立刻失效
        self._close_socket()
        self._abort_ble()
        self.connected = False
        self.phase_total = 0.0
        self.state = "idle"
        self.state_text = "未连接"
        if not quiet:
            self.emit(("log", "已取消", False))
            self.emit(("state", "idle", "未连接"))

    def disconnect(self):
        self._want = False
        self._stop.set()
        self._gen += 1
        self._close_socket()
        self._abort_ble()
        self.connected = False
        self.phase_total = 0.0
        self.state = "idle"
        self.state_text = "未连接"
        self.emit(("log", "已断开", False))
        self.emit(("state", "idle", "未连接"))

    def send(self, line):
        if not self.connected:
            self._note_dropped()
            return
        if self.kind == "wifi":
            sock = self._sock
            if sock is None:
                self._note_dropped()
                return
            payload = (line + "\n").encode("utf-8")
            with self._sock_lock:
                try:
                    sock.sendall(payload)
                except OSError as exc:
                    self.emit(("log", f"发送失败: {exc}", True))
            return

        loop = self._loop
        client = self._client
        if loop is None or client is None:
            self._note_dropped()
            return
        try:
            asyncio.run_coroutine_threadsafe(self._ble_send(client, line), loop)
        except RuntimeError:
            self._note_dropped()

    def remaining(self):
        """当前阶段还剩几秒；0 表示没有在倒计时。"""
        if self.phase_total <= 0:
            return 0.0
        left = self.phase_start + self.phase_total - time.monotonic()
        return max(0.0, left)

    # -- 内部：状态与日志 --------------------------------------------------
    def _alive(self, gen):
        return gen == self._gen

    def _set_state(self, gen, state, text, total=0.0):
        if not self._alive(gen):
            return
        self.state = state
        self.state_text = text
        self.phase_start = time.monotonic()
        self.phase_total = total
        self.emit(("state", state, text))

    def _log(self, gen, text, is_error=False):
        if not self._alive(gen):
            return
        self.emit(("log", text, is_error))

    def _note_dropped(self):
        now = time.monotonic()
        if now - self._drop_at < 2.0:
            return
        self._drop_at = now
        self.emit(("log", "未连接，刚才的按键没有发出去（先点「连接」）", True))

    # -- 内部：重试循环 ----------------------------------------------------
    def _run_attempts(self, gen, kind, name, host, port):
        attempt = 0
        while self._want and self._alive(gen):
            if kind == "ble":
                ok, cancelled = self._attempt_ble(gen, name, attempt)
            else:
                ok, cancelled = self._attempt_wifi(gen, host, port, attempt)

            if not self._alive(gen) or cancelled:
                return
            if ok:
                # 连上过又断了：不计入重试次数的上限，歇一下直接重连
                self._set_idle_after_drop(gen)
                attempt = 0
                if not self._want:
                    return
                self._log(gen, f"{int(RETRY_GAP)} 秒后重连…", True)
                if self._sleep(RETRY_GAP, gen):
                    return
                continue

            attempt += 1
            if attempt > MAX_RETRIES:
                if self._alive(gen):
                    self.state = "failed"
                    self.state_text = self.fail_reason or "连接失败"
                    self.phase_total = 0.0
                    self.emit(("state", "failed", self.state_text))
                    self._log(gen, f"{self.fail_reason}，已重试 {MAX_RETRIES} 次仍未成功", True)
                return
            if self._alive(gen):
                self.state_text = f"{self.fail_reason}（重试 {attempt}/{MAX_RETRIES}）"
                self.emit(("state", "failed", self.state_text))
                self._log(gen, f"{self.fail_reason}，{int(RETRY_GAP)} 秒后自动重试", True)
            if self._sleep(RETRY_GAP, gen):
                return

    def _set_idle_after_drop(self, gen):
        if not self._alive(gen):
            return
        self.connected = False
        self.state = "idle"
        self.state_text = "未连接"
        self.phase_total = 0.0
        self.emit(("state", "idle", "未连接"))

    def _sleep(self, seconds, gen):
        """可中断的等待；返回 True 表示应该收工。"""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if not self._want or not self._alive(gen):
                return True
            time.sleep(0.05)
        return not self._want or not self._alive(gen)

    # -- 内部：BLE --------------------------------------------------------
    def _attempt_ble(self, gen, name, attempt):
        try:
            import bleak  # noqa: F401
        except ImportError:
            self.fail_reason = "缺少 bleak 库，请先 pip3 install bleak"
            self._log(gen, self.fail_reason, True)
            return False, True

        try:
            return asyncio.run(self._ble_session(gen, name, attempt))
        except Exception as exc:                       # noqa: BLE001
            self.fail_reason = f"蓝牙链路异常: {exc}"
            self._log(gen, self.fail_reason, True)
            return False, False

    async def _ble_session(self, gen, name, attempt):
        from bleak import BleakClient, BleakScanner

        # macOS 的 TCC：没有蓝牙用途声明的进程会被直接 SIGKILL，
        # 所以先派一个牺牲子进程试探，别让主进程踩地雷。
        if sys.platform == "darwin" and self._probe_done is None:
            await asyncio.to_thread(self._probe_bluetooth)
        if self._probe_done:
            self.emit(("log", "TCC:" + TCC_HINT, True))
            self.fail_reason = "蓝牙权限被 macOS 拦截"
            return False, True

        label = "扫描中…" if attempt == 0 else f"重新扫描（第 {attempt} 次重试）"
        self._set_state(gen, "scanning", f"扫描 “{name}”…", SCAN_TIMEOUT)
        self._log(gen, f"{label} 最长 {int(SCAN_TIMEOUT)} 秒")

        device = await self._ble_find(BleakScanner, gen, name)
        if device is None:
            if self._stop.is_set():
                return False, True
            self.fail_reason = f"没找到 “{name}”"
            self._log(gen, "扫描超时：确认板子已上电、在范围内，且设备名一致", True)
            return False, False

        if not self._alive(gen):
            return False, True

        self._set_state(gen, "connecting", f"正在连接 {device.address}…", CONNECT_TIMEOUT)
        client = BleakClient(device, disconnected_callback=lambda _c: self._on_ble_drop(gen))
        try:
            await asyncio.wait_for(client.connect(), CONNECT_TIMEOUT)
        except asyncio.TimeoutError:
            self.fail_reason = f"连接超时（超过 {int(CONNECT_TIMEOUT)} 秒）"
            self._log(gen, self.fail_reason + "，确认 ESP32 已上电且未被其它设备占用", True)
            await self._safe_disconnect(client)
            return False, False
        except Exception as exc:                       # noqa: BLE001
            self.fail_reason = f"连接失败: {exc}"
            self._log(gen, self.fail_reason, True)
            await self._safe_disconnect(client)
            return False, False

        if not self._alive(gen) or self._stop.is_set():
            await self._safe_disconnect(client)
            return False, True

        if self._find_char(client, RX_UUID) is None:
            await self._safe_disconnect(client)
            self.fail_reason = "已连接但找不到服务，检查两端 UUID 是否一致"
            self._log(gen, self.fail_reason, True)
            return False, False

        self._loop = asyncio.get_running_loop()
        self._ble_lock = asyncio.Lock()
        self._client = client
        self.connected = True
        self.phase_total = 0.0
        self.state = "connected"
        self.state_text = f"已连接（{device.name or device.address}）"
        self.emit(("state", "connected", self.state_text))
        self._log(gen, f"蓝牙链路就绪（{device.name or device.address}）")

        try:
            await client.start_notify(TX_UUID, self._make_notify_handler(gen))
        except Exception:                              # noqa: BLE001
            self._log(gen, "订阅回执失败，PONG / BOOTKEY 回复可能收不到", True)

        self.send(Cmd.PING)

        # 保活：等用户断开、掉线或取消
        while not self._stop.is_set() and self._alive(gen) and client.is_connected:
            await asyncio.sleep(0.2)

        dropped = not client.is_connected and not self._stop.is_set()
        self.connected = False
        self._client = None
        self._loop = None
        self._ble_lock = None
        await self._safe_disconnect(client)
        if dropped:
            self._log(gen, "蓝牙连接已断开，准备重连", True)
        return (dropped, False)

    def _make_notify_handler(self, gen):
        def handler(_char, data):
            text = data.decode("utf-8", "replace").strip()
            if text and self._alive(gen):
                self.emit(("log", "← " + text, False))
        return handler

    async def _ble_find(self, BleakScanner, gen, name):
        """扫到目标设备就返回。

        不只看设备名：Windows 上未配对的设备经常报不出 name，
        这时靠广告里的自定义服务 UUID 也能认出来（固件一定会广播它）。
        """
        deadline = time.monotonic() + SCAN_TIMEOUT
        while time.monotonic() < deadline:
            if self._stop.is_set() or not self._alive(gen):
                return None
            step = max(0.6, min(2.0, deadline - time.monotonic()))
            try:
                found = await BleakScanner.discover(timeout=step, return_adv=True)
                pairs = list(found.values())
            except TypeError:                          # 老 bleak 没有 return_adv
                try:
                    pairs = [(dev, None) for dev in await BleakScanner.discover(timeout=step)]
                except Exception as exc:               # noqa: BLE001
                    self.fail_reason = f"扫描出错: {exc}"
                    self._log(gen, self.fail_reason, True)
                    return None
            except Exception as exc:                   # noqa: BLE001
                self.fail_reason = f"扫描出错: {exc}"
                self._log(gen, self.fail_reason, True)
                return None

            for dev, adv in pairs:
                if self._is_target(dev, adv, name):
                    return dev
            if not self._alive(gen):
                return None
        return None

    @staticmethod
    def _is_target(dev, adv, name):
        candidates = [dev.name or ""]
        local_name = getattr(adv, "local_name", None)
        if local_name:
            candidates.append(local_name)
        wanted = (name or "").lower()
        for candidate in candidates:
            if wanted and (candidate.lower() == wanted or wanted in candidate.lower()):
                return True
        for uuid in getattr(adv, "service_uuids", None) or ():
            if str(uuid).lower() == SERVICE_UUID.lower():
                return True
        return False

    async def _ble_send(self, client, line):
        payload = (line + "\n").encode("utf-8")
        lock = self._ble_lock or asyncio.Lock()
        async with lock:
            for i in range(0, len(payload), WRITE_CHUNK):
                chunk = payload[i:i + WRITE_CHUNK]
                try:
                    await client.write_gatt_char(RX_UUID, chunk, response=False)
                except Exception:                      # noqa: BLE001
                    try:
                        await client.write_gatt_char(RX_UUID, chunk, response=True)
                    except Exception as exc:           # noqa: BLE001
                        self.emit(("log", f"发送失败: {exc}", True))
                        return

    @staticmethod
    async def _safe_disconnect(client):
        try:
            await client.disconnect()
        except Exception:                              # noqa: BLE001
            pass

    @staticmethod
    def _find_char(client, uuid):
        uuid = uuid.lower()
        try:
            char = client.services.get_characteristic(uuid)
            if char is not None:
                return char
        except Exception:                              # noqa: BLE001
            pass
        try:
            for service in client.services:
                for char in service.characteristics:
                    if char.uuid.lower() == uuid:
                        return char
        except Exception:                              # noqa: BLE001
            pass
        return None

    def _on_ble_drop(self, gen):
        if self._alive(gen):
            self.connected = False
            self.emit(("log", "连接已断开", True))

    def _abort_ble(self):
        client = self._client
        loop = self._loop
        if client is not None and loop is not None:
            try:
                asyncio.run_coroutine_threadsafe(self._safe_disconnect(client), loop)
            except RuntimeError:
                pass

    # -- 内部：Wi-Fi（TCP） -------------------------------------------------
    def _attempt_wifi(self, gen, host, port, attempt):
        target = f"{host}:{port}"
        label = "连接" if attempt == 0 else f"重新连接（第 {attempt} 次重试）"
        self._set_state(gen, "connecting", f"{label} {target}…", WIFI_TIMEOUT)
        self._log(gen, f"{label} Wi-Fi 桥 {target}，最长 {int(WIFI_TIMEOUT)} 秒")

        try:
            sock = socket.create_connection((host, port), timeout=WIFI_TIMEOUT)
        except OSError as exc:
            if self._stop.is_set():
                return False, True
            self.fail_reason = f"连不上 {target}（{exc.strerror or exc}）"
            self._log(gen, self.fail_reason + f"，确认笔记本已连上热点 {HOTSPOT_NAME}", True)
            return False, False

        sock.settimeout(0.5)
        with self._sock_lock:
            self._sock = sock
        self.connected = True
        self.phase_total = 0.0
        self.state = "connected"
        self.state_text = f"Wi-Fi 已连接（{target}）"
        self.emit(("state", "connected", self.state_text))
        self._log(gen, f"Wi-Fi 链路就绪（{target}）")
        self.send(Cmd.PING)

        buffer = ""
        dropped = False
        while not self._stop.is_set() and self._alive(gen):
            try:
                data = sock.recv(4096)
            except socket.timeout:
                continue
            except OSError as exc:
                if not self._stop.is_set():
                    self._log(gen, f"Wi-Fi 链路错误：{exc}", True)
                    dropped = True
                break
            if not data:
                if not self._stop.is_set():
                    self._log(gen, "Wi-Fi 对端关闭了连接", True)
                    dropped = True
                break
            buffer += data.decode("utf-8", "replace")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if line:
                    self.emit(("log", "← " + line, False))
            if len(buffer) > 8192:
                buffer = ""

        self.connected = False
        self._close_socket()
        if dropped:
            self._log(gen, "Wi-Fi 连接已断开，准备重连", True)
        return (dropped, False)

    def _close_socket(self):
        with self._sock_lock:
            sock = self._sock
            self._sock = None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    # -- 内部：蓝牙权限试探 -------------------------------------------------
    def _probe_bluetooth(self):
        """派子进程试一次扫描：主进程一旦被 TCC 杀就救不回来了。"""
        code = (
            "import asyncio\n"
            "from bleak import BleakScanner\n"
            "asyncio.run(BleakScanner.discover(timeout=0.5))\n"
        )
        try:
            proc = subprocess.run([sys.executable, "-c", code],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=25)
        except subprocess.TimeoutExpired:
            self._probe_done = True
            return
        except Exception:                              # noqa: BLE001
            self._probe_done = False
            return
        if proc.returncode == 0:
            self._probe_done = False
        elif proc.returncode < 0 and -proc.returncode in _KILLED_CODES:
            self._probe_done = True
        else:
            self._probe_done = False


# ---------------------------------------------------------------------------
# 三、本机键盘转发（CGEventTap）
# ---------------------------------------------------------------------------
class KeyForwarder:
    """接管本机键盘，把每一次按键原样转给被控主机。

    要点（与 Swift 版 KeyForwarder 一致）：
      · 修饰键按 flags 全量镜像，纯修饰键操作（Shift、Ctrl+Space）也能发出去
      · 过滤自动重复（主机自己有重复，重复发会翻倍）
      · ⌃⌥Esc 永远优先：立刻停止捕获并发 RELEASEALL
      · 未映射的键放行给本机（不吞），避免「按了没反应也顾不上本机」
    """

    def __init__(self, on_command, on_log):
        self.on_command = on_command
        self.on_log = on_log
        self.on_stop = None            # ⌃⌥Esc 触发时通知界面
        self.capturing = False
        self._thread = None
        self._runloop = None
        self._tap = None
        self._mirror = ModifierMirror()
        self._held = set()
        self._warned = set()

    # -- 静态信息 ---------------------------------------------------------
    @staticmethod
    def available():
        return Quartz is not None

    @staticmethod
    def trusted():
        for mod in (AXKit, Quartz):
            if mod is None:
                continue
            check = getattr(mod, "AXIsProcessTrusted", None)
            if check is None:
                continue
            try:
                return bool(check())
            except Exception:                          # noqa: BLE001
                continue
        return False

    @staticmethod
    def prompt_trust():
        for mod in (AXKit, Quartz):
            if mod is None:
                continue
            check = getattr(mod, "AXIsProcessTrustedWithOptions", None)
            key = getattr(mod, "kAXTrustedCheckOptionPrompt", None)
            if check is None or key is None:
                continue
            try:
                check({key: True})
                return
            except Exception:                          # noqa: BLE001
                continue

    @staticmethod
    def open_settings():
        url = ("x-apple.systempreferences:com.apple.preference.security"
               "?Privacy_Accessibility")
        try:
            subprocess.Popen(["open", url])
        except OSError:
            pass

    # -- 启停 -------------------------------------------------------------
    def start(self):
        if self.capturing:
            return True
        if Quartz is None:
            self.on_log("本机键盘转发需要 pyobjc：pip3 install pyobjc-framework-Quartz", True)
            return False
        if not self.trusted():
            self.prompt_trust()
            self.on_log("还没有「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，"
                        "勾选本程序（重新编译过的 App 要重新勾）", True)
            return False

        self.capturing = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return True

    def stop(self):
        self.capturing = False
        rl = self._runloop
        if rl is not None:
            try:
                Quartz.CFRunLoopStop(rl)
            except Exception:                          # noqa: BLE001
                pass

    def _run(self):
        Q = Quartz
        try:
            mask = (Q.CGEventMaskBit(Q.kCGEventKeyDown)
                    | Q.CGEventMaskBit(Q.kCGEventKeyUp)
                    | Q.CGEventMaskBit(Q.kCGEventFlagsChanged))
            tap = Q.CGEventTapCreate(Q.kCGSessionEventTap, Q.kCGHeadInsertEventTap,
                                     Q.kCGEventTapOptionDefault, mask,
                                     _tap_callback, self)
        except Exception as exc:                       # noqa: BLE001
            self.capturing = False
            self.on_log(f"创建事件钩子失败: {exc}", True)
            return
        if not tap:
            self.capturing = False
            self.on_log("事件钩子创建失败：多半是「辅助功能」没有授权", True)
            return

        self._tap = tap
        source = Q.CFMachPortCreateRunLoopSource(None, tap, 0)
        runloop = Q.CFRunLoopGetCurrent()
        self._runloop = runloop
        Q.CFRunLoopAddSource(runloop, source, Q.kCFRunLoopCommonModes)
        Q.CGEventTapEnable(tap, True)
        self.on_log("捕获已开启：本机按键会转发给主机（⌃⌥Esc 停止）")

        Q.CFRunLoopRun()                               # 阻塞到 stop()

        try:
            Q.CGEventTapEnable(tap, False)
            Q.CFMachPortInvalidate(tap)
        except Exception:                              # noqa: BLE001
            pass
        self._tap = None
        self._runloop = None
        self.capturing = False
        self._release_all()
        self.on_log("捕获已停止")

    # -- 事件处理 ---------------------------------------------------------
    def _handle(self, event_type, event):
        Q = Quartz

        if event_type in (Q.kCGEventTapDisabledByTimeout, Q.kCGEventTapDisabledByUserInput):
            if self._tap is not None:
                Q.CGEventTapEnable(self._tap, True)
            return event

        keycode = int(Q.CGEventGetIntegerValueField(event, Q.kCGKeyboardEventKeycode))
        flags = int(Q.CGEventGetFlags(event))
        shift = bool(flags & FLAG_SHIFT)
        control = bool(flags & FLAG_CONTROL)
        alt = bool(flags & FLAG_ALTERNATE)
        cmd = bool(flags & FLAG_COMMAND)

        if event_type == Q.kCGEventFlagsChanged:
            if self._is_emergency(keycode, control, alt):
                self._request_stop()
                return None
            self._sync_modifiers(shift, control, alt, cmd, keycode)
            return None                                # 吞掉：本机不再自己处理

        if event_type == Q.kCGEventKeyDown:
            repeat = int(Q.CGEventGetIntegerValueField(event, Q.kCGKeyboardEventAutorepeat))
            if repeat:
                return None
            if self._is_emergency(keycode, control, alt):
                self._request_stop()
                return None
            self._sync_modifiers(shift, control, alt, cmd, None)
            token = KEY_TOKENS.get(keycode)
            if token is None:
                self._warn_unmapped(keycode)
                return event                           # 放行给本机
            self._held.add(keycode)
            self.on_command(Cmd.down(token))
            return None

        if event_type == Q.kCGEventKeyUp:
            token = KEY_TOKENS.get(keycode)
            if token is not None:
                self._held.discard(keycode)
                self.on_command(Cmd.up(token))
            self._sync_modifiers(shift, control, alt, cmd, None)
            return None if token is not None else event

        return event

    def _sync_modifiers(self, shift, control, alt, cmd, side):
        release, press = self._mirror.sync(
            shift, control, alt, cmd,
            SIDE_KEY_TOKENS.get(side) if side is not None else None)
        for token in release:
            self.on_command(Cmd.up(token))
        for token in press:
            self.on_command(Cmd.down(token))

    @staticmethod
    def _is_emergency(keycode, control, alt):
        return keycode == 53 and control and alt        # ⌃⌥Esc

    def _request_stop(self):
        def later():
            self.stop()
            self.on_log("⌃⌥Esc：已停止捕获并松开所有按键")
            if self.on_stop:
                self.on_stop()
        threading.Timer(0.05, later).start()

    def _release_all(self):
        self._mirror.reset()
        self._held.clear()
        self.on_command(Cmd.RELEASE_ALL)

    def _warn_unmapped(self, keycode):
        if keycode in self._warned:
            return
        self._warned.add(keycode)
        self.on_log(f"跳过未映射的键（keyCode {keycode}），它不在当前键表里", True)


def _tap_callback(proxy, event_type, event, refcon):
    try:
        return refcon._handle(event_type, event)
    except Exception:                                  # noqa: BLE001
        return event


# ---------------------------------------------------------------------------
# 三之二、Windows 版本机键盘转发（SetWindowsHookEx + WH_KEYBOARD_LL）
# ---------------------------------------------------------------------------
class WinKeyForwarder:
    """接管本机键盘，把每一次按键原样转给被控主机。

    和 macOS 版是同一套规则：修饰键按「当前按下的集合」全量镜像、过滤自动
    重复、Ctrl+Alt+Esc 永远优先、没映射的键放行给本机。区别只在钩子本身：
    Windows 用 ctypes 直接调 Win32 的低层键盘钩子，不需要装任何依赖，
    也不需要授权（只有「以管理员运行的窗口」的按键抓不到，这是系统限制）。
    """

    TARGET_THREAD_WM_QUIT = 0x0012
    LLKHF_EXTENDED = 0x01

    def __init__(self, on_command, on_log):
        self.on_command = on_command
        self.on_log = on_log
        self.on_stop = None            # Ctrl+Alt+Esc 触发时通知界面
        self.capturing = False
        self._thread = None
        self._thread_id = 0
        self._hook_proc = None         # 保住回调引用，否则会被 GC
        self._mirror = ModifierMirror()
        self._mods = {}                # 语义类 -> 侧别 token（lshift/rshift/…）
        self._held = set()             # 当前按下、可映射的 vk
        self._warned = set()

    # -- 静态信息 ---------------------------------------------------------
    @staticmethod
    def available():
        return IS_WIN

    @staticmethod
    def trusted():
        # Windows 抓键盘不需要授权；这里恒为 True，界面直接显示「可用」
        return IS_WIN

    @staticmethod
    def prompt_trust():
        pass                           # Windows 没有对应的授权流程

    @staticmethod
    def open_settings():
        pass                           # 同上：没有需要打开的设置页

    # -- 启停 -------------------------------------------------------------
    def start(self):
        if self.capturing:
            return True
        if not IS_WIN:
            self.on_log("本机键盘转发只在 macOS / Windows 上可用", True)
            return False
        self.capturing = True
        self._mods.clear()
        self._held.clear()
        self._mirror.reset()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return True

    def stop(self):
        self.capturing = False
        tid = self._thread_id
        if not tid:
            return
        try:
            ctypes.windll.user32.PostThreadMessageW(tid, self.TARGET_THREAD_WM_QUIT, 0, 0)
        except Exception:                              # noqa: BLE001
            pass

    # -- 钩子线程 ---------------------------------------------------------
    def _run(self):
        from ctypes import wintypes

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class KBDLLHOOKSTRUCT(ctypes.Structure):
            _fields_ = [("vkCode", wintypes.DWORD),
                        ("scanCode", wintypes.DWORD),
                        ("flags", wintypes.DWORD),
                        ("time", wintypes.DWORD),
                        ("dwExtraInfo", ctypes.c_void_p)]

        # LRESULT CALLBACK proc(int nCode, WPARAM wParam, LPARAM lParam)
        hookproc_type = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int,
                                           ctypes.c_size_t, ctypes.c_ssize_t)

        def low_level_proc(n_code, w_param, l_param):
            try:
                if n_code == 0:                        # HC_ACTION
                    info = ctypes.cast(l_param, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
                    if self._handle(int(w_param), int(info.vkCode),
                                    int(info.scanCode), int(info.flags)):
                        return 1                       # 吞掉：本机看不到这次按键
            except Exception:                          # noqa: BLE001
                pass
            return int(user32.CallNextHookEx(None, n_code, w_param, l_param))

        user32.SetWindowsHookExW.restype = ctypes.c_void_p
        user32.SetWindowsHookExW.argtypes = [ctypes.c_int, hookproc_type,
                                             ctypes.c_void_p, wintypes.DWORD]
        user32.CallNextHookEx.restype = ctypes.c_ssize_t
        user32.CallNextHookEx.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                          ctypes.c_size_t, ctypes.c_ssize_t]
        user32.UnhookWindowsHookEx.argtypes = [ctypes.c_void_p]

        self._thread_id = int(kernel32.GetCurrentThreadId())
        proc = hookproc_type(low_level_proc)
        self._hook_proc = proc

        WH_KEYBOARD_LL = 13
        hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, proc, None, 0)
        if not hook:
            self.capturing = False
            self._thread_id = 0
            self.on_log(f"安装键盘钩子失败（错误码 {ctypes.get_last_error()}）", True)
            return

        self.on_log(f"捕获已开启：本机按键会转发给主机（{STOP_COMBO} 停止）")

        msg = wintypes.MSG()
        try:
            while self.capturing:
                got = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
                if got in (0, -1):                     # WM_QUIT 或出错
                    break
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))
        except Exception as exc:                       # noqa: BLE001
            self.on_log(f"键盘钩子异常: {exc}", True)
        finally:
            try:
                user32.UnhookWindowsHookEx(hook)
            except Exception:                          # noqa: BLE001
                pass
            self._thread_id = 0
            self._hook_proc = None
            self.capturing = False
            self._release_all()
            self.on_log("捕获已停止")

    # -- 事件处理 ---------------------------------------------------------
    def _handle(self, wparam, vk, scan, flags):
        """返回 True 表示吞掉这次按键（本机不再处理）。"""
        down = wparam in (0x0100, 0x0104)      # WM_KEYDOWN / WM_SYSKEYDOWN
        up = wparam in (0x0101, 0x0105)        # WM_KEYUP / WM_SYSKEYUP
        if not down and not up:
            return False

        side = _win_modifier_token(vk, scan, flags)
        if side is not None:
            cls = CLASS_OF_TOKEN[side]
            if down:
                self._mods[cls] = side
            else:
                self._mods.pop(cls, None)
            self._sync_modifiers(side)
            return True                        # 修饰键不留给本机

        if down and vk == 0x1B and "ctrl" in self._mods and "alt" in self._mods:
            self._request_stop()
            return True

        token = VK_TO_TOKEN.get(vk)
        if token is None:
            if down:
                self._warn_unmapped(vk)
            return False                       # 放行给本机
        if down:
            if vk in self._held:
                return True                    # 自动重复：主机自己会重复
            self._held.add(vk)
            self.on_command(Cmd.down(token))
            return True
        self._held.discard(vk)
        self.on_command(Cmd.up(token))
        return True

    def _sync_modifiers(self, side_token):
        release, press = self._mirror.sync(
            "shift" in self._mods, "ctrl" in self._mods,
            "alt" in self._mods, "cmd" in self._mods, side_token)
        for token in release:
            self.on_command(Cmd.up(token))
        for token in press:
            self.on_command(Cmd.down(token))

    def _request_stop(self):
        def later():
            self.stop()
            self.on_log(f"{STOP_COMBO}：已停止捕获并松开所有按键")
            if self.on_stop:
                self.on_stop()
        threading.Timer(0.05, later).start()

    def _release_all(self):
        self._mirror.reset()
        self._mods.clear()
        self._held.clear()
        self.on_command(Cmd.RELEASE_ALL)

    def _warn_unmapped(self, vk):
        if vk in self._warned:
            return
        self._warned.add(vk)
        self.on_log(f"跳过未映射的键（vkCode 0x{vk:02X}），它不在当前键表里")


# 两个平台的实现，界面只用 FORWARDER_CLASS 这一个名字
FORWARDER_CLASS = WinKeyForwarder if IS_WIN else KeyForwarder


def make_forwarder(on_command, on_log):
    return FORWARDER_CLASS(on_command, on_log)


# ---------------------------------------------------------------------------
# 四、图形界面
# ---------------------------------------------------------------------------
CARD_BG = "#ffffff"
PAGE_BG = "#f2f2f4"
INK = "#1d1d1f"
INK_SOFT = "#6e6e73"
ACCENT = "#0a84ff"
DANGER = "#ff3b30"
OK = "#34c759"


def _mk_card(parent, title):
    frame = tk.LabelFrame(parent, text=" " + title + " ", padx=10, pady=8,
                          fg=INK_SOFT, bg=CARD_BG, bd=1, relief="solid",
                          font=(UI_FAMILY, 11, "bold"))
    return frame


class App:
    def __init__(self, root, device_name=DEFAULT_NAME, host=DEFAULT_HOST, port=DEFAULT_PORT):
        self.root = root
        self.events = queue.Queue()
        self.link = Link(self.events.put)
        self.fwd = make_forwarder(self._fwd_command, self._fwd_log)
        self.fwd.on_stop = self._fwd_stopped

        self.sticky = set()
        self.key_buttons = {}
        self.mod_buttons = {}
        self.mouse_held = set()
        self.drag_lock = False
        self.bios_current = "delete"

        # 鼠标位移攒批
        self._pad_pending = [0.0, 0.0]
        self._pad_timer = None
        self._pad_last = None
        self.mouse_speed = 1.6

        # 屏幕键盘点击串行化
        self._tap_busy_until = 0.0

        root.title("ESP32-S3 无线键盘（Python 版）")
        root.minsize(1200, 760)
        root.configure(bg=PAGE_BG)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)

        self._build_top(device_name, host, port)
        self._build_cards()
        self._build_bottom()
        self._build_log()

        root.protocol("WM_DELETE_WINDOW", self.on_close)
        root.after(100, self._poll)
        self._refresh_trust()

    # -- 顶部：模式 / 地址 / 连接 -----------------------------------------
    def _build_top(self, device_name, host, port):
        outer = tk.Frame(self.root, bg=PAGE_BG, padx=12, pady=8)
        outer.grid(row=0, column=0, sticky="ew")
        outer.columnconfigure(0, weight=1)

        row = tk.Frame(outer, bg=PAGE_BG)
        row.grid(row=0, column=0, sticky="ew")

        tk.Label(row, text="链路", bg=PAGE_BG, fg=INK).pack(side="left")

        self.mode_var = tk.StringVar(value="ble")
        self.mode_buttons = {}
        for value, text in (("ble", "蓝牙"), ("wifi", "Wi-Fi")):
            btn = tk.Radiobutton(row, text=text, value=value, variable=self.mode_var,
                                 indicatoron=0, width=7, command=self._on_mode_change,
                                 fg=INK, bg="#e6e6e9", selectcolor="#cfe6ff",
                                 activebackground="#dcdce0", relief="flat", bd=0,
                                 padx=6, pady=3)
            btn.pack(side="left", padx=(4, 0))
            self.mode_buttons[value] = btn

        tk.Label(row, text="设备名", bg=PAGE_BG, fg=INK).pack(side="left", padx=(14, 4))
        self.name_var = tk.StringVar(value=device_name)
        self.name_entry = tk.Entry(row, textvariable=self.name_var, width=14)
        self.name_entry.pack(side="left")

        tk.Label(row, text="主机", bg=PAGE_BG, fg=INK).pack(side="left", padx=(12, 4))
        self.host_var = tk.StringVar(value=host)
        self.host_entry = tk.Entry(row, textvariable=self.host_var, width=12)
        self.host_entry.pack(side="left")

        tk.Label(row, text="端口", bg=PAGE_BG, fg=INK).pack(side="left", padx=(8, 4))
        self.port_var = tk.StringVar(value=str(port))
        self.port_entry = tk.Entry(row, textvariable=self.port_var, width=6)
        self.port_entry.pack(side="left")

        # 第二行：连接按钮 + 状态点 + 文案 + 倒计时进度条（右端是模式提示）
        status_row = tk.Frame(outer, bg=PAGE_BG, pady=4)
        status_row.grid(row=1, column=0, sticky="ew")

        self.connect_btn = tk.Button(status_row, text="连接", width=7,
                                     command=self.on_connect,
                                     fg="#ffffff", bg=ACCENT, activebackground="#0b74dd",
                                     activeforeground="#ffffff", relief="flat", bd=0,
                                     padx=6, pady=4)
        self.connect_btn.pack(side="left")

        self.stop_btn = tk.Button(status_row, text="停止", width=6, command=self.on_stop,
                                  fg="#ffffff", bg=DANGER, activebackground="#d92b20",
                                  activeforeground="#ffffff", relief="flat", bd=0,
                                  padx=6, pady=4, state="disabled")
        self.stop_btn.pack(side="left", padx=(6, 0))

        self.disconnect_btn = tk.Button(status_row, text="断开", width=6,
                                        command=self.on_disconnect, relief="flat", bd=0,
                                        padx=6, pady=4, bg="#e6e6e9")
        self.disconnect_btn.pack(side="left", padx=(6, 0))

        self.release_btn = tk.Button(status_row, text="释放全部按键",
                                     command=self.on_release_all, relief="flat", bd=0,
                                     padx=8, pady=4, bg="#e6e6e9")
        self.release_btn.pack(side="left", padx=(6, 14))

        self.dot = tk.Canvas(status_row, width=12, height=12, bg=PAGE_BG,
                             highlightthickness=0)
        self.dot.pack(side="left")
        self._dot_item = self.dot.create_oval(2, 2, 11, 11, fill="#b0b0b5", outline="")

        self.status_var = tk.StringVar(value="未连接")
        tk.Label(status_row, textvariable=self.status_var, bg=PAGE_BG, fg=INK,
                 anchor="w").pack(side="left", padx=(6, 10))

        self.progress = ttk.Progressbar(status_row, mode="determinate", maximum=1.0,
                                        length=180)
        self.progress.pack(side="left")
        self.progress.pack_forget()

        self.hint_var = tk.StringVar(value="")
        tk.Label(status_row, textvariable=self.hint_var, bg=PAGE_BG, fg=INK_SOFT,
                 anchor="e").pack(side="right")

        self._on_mode_change()

    def _on_mode_change(self):
        wifi = self.mode_var.get() == "wifi"
        self.name_entry.configure(state="normal" if not wifi else "disabled")
        self.host_entry.configure(state="normal" if wifi else "disabled")
        self.port_entry.configure(state="normal" if wifi else "disabled")
        self.hint_var.set(
            "先连上热点 " + HOTSPOT_NAME + "（密码 esp32keyboard）" if wifi
            else "板子上的 BOOT 键切到蓝牙模式（灯蓝色）")

    # -- 中部：本机转发 / BIOS / 文字+快捷键 --------------------------------
    def _build_cards(self):
        wrap = tk.Frame(self.root, bg=PAGE_BG, padx=12, pady=6)
        wrap.grid(row=1, column=0, sticky="ew")
        wrap.columnconfigure(0, weight=0)
        wrap.columnconfigure(1, weight=0)
        wrap.columnconfigure(2, weight=1)

        self._build_capture_card(wrap).grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self._build_bios_card(wrap).grid(row=0, column=1, sticky="nsew", padx=(0, 8))
        self._build_right_cards(wrap).grid(row=0, column=2, sticky="nsew")

    def _build_capture_card(self, parent):
        card = _mk_card(parent, "本机键盘转发")
        card.columnconfigure(0, weight=1)

        line = tk.Frame(card, bg=CARD_BG)
        line.grid(row=0, column=0, sticky="ew")
        self.trust_dot = tk.Canvas(line, width=12, height=12, bg=CARD_BG,
                                   highlightthickness=0)
        self.trust_dot.pack(side="left")
        self._trust_item = self.trust_dot.create_oval(2, 2, 11, 11, fill="#b0b0b5",
                                                     outline="")
        self.trust_var = tk.StringVar(value="检查权限…")
        tk.Label(line, textvariable=self.trust_var, bg=CARD_BG, fg=INK).pack(
            side="left", padx=(6, 0))

        btns = tk.Frame(card, bg=CARD_BG)
        btns.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        self.capture_btn = tk.Button(btns, text="开始捕获", width=9,
                                     command=self.on_capture, relief="flat", bd=0,
                                     padx=8, pady=4, bg="#e6e6e9")
        self.capture_btn.pack(side="left")
        self.capture_stop_btn = tk.Button(btns, text="停止", width=6,
                                          command=self.on_stop_capture, relief="flat",
                                          bd=0, padx=8, pady=4, bg="#e6e6e9",
                                          state="disabled")
        self.capture_stop_btn.pack(side="left", padx=6)
        if IS_MAC:      # Windows 不需要授权，这个按钮没有意义
            tk.Button(btns, text="授权设置", command=FORWARDER_CLASS.open_settings,
                      relief="flat", bd=0, padx=8, pady=4, bg="#e6e6e9").pack(side="left")

        tk.Label(card, text=f"捕获期间本机按键被吞掉、只发给主机；{STOP_COMBO} 随时停止。",
                 bg=CARD_BG, fg=INK_SOFT, justify="left", wraplength=320).grid(
            row=2, column=0, sticky="w", pady=(8, 0))

        return card

    def _build_bios_card(self, parent):
        card = _mk_card(parent, "BIOS 启动键")
        for col in range(4):
            card.columnconfigure(col, weight=1, uniform="bios")

        self.bios_var = tk.StringVar(value=self.bios_current)
        for index, (label, token) in enumerate(BIOS_KEYS):
            btn = tk.Radiobutton(card, text=label, value=token, variable=self.bios_var,
                                 indicatoron=0, command=self.on_bios_key, relief="flat",
                                 bd=0, padx=4, pady=3, bg="#e6e6e9",
                                 selectcolor="#cfe6ff", fg=INK,
                                 activebackground="#dcdce0")
            btn.grid(row=index // 4, column=index % 4, sticky="ew", padx=2, pady=2)

        row = tk.Frame(card, bg=CARD_BG)
        row.grid(row=2, column=0, columnspan=4, sticky="ew", pady=(8, 0))
        tk.Button(row, text="立即连发", command=self.on_bios_now, relief="flat", bd=0,
                  padx=8, pady=4, bg="#e6e6e9").pack(side="left")
        tk.Button(row, text="查询", command=self.on_bios_query, relief="flat", bd=0,
                  padx=8, pady=4, bg="#e6e6e9").pack(side="left", padx=6)

        self.bios_note_var = tk.StringVar(value="固件当前：delete")
        tk.Label(card, textvariable=self.bios_note_var, bg=CARD_BG, fg=INK_SOFT,
                 wraplength=300, justify="left").grid(
            row=3, column=0, columnspan=4, sticky="w", pady=(6, 0))

        return card

    def _build_right_cards(self, parent):
        holder = tk.Frame(parent, bg=PAGE_BG)
        holder.columnconfigure(0, weight=1)

        text_card = _mk_card(holder, "文字")
        text_card.grid(row=0, column=0, sticky="ew")
        text_card.columnconfigure(1, weight=1)

        self.text_var = tk.StringVar()
        entry = tk.Entry(text_card, textvariable=self.text_var)
        entry.grid(row=0, column=0, columnspan=3, sticky="ew")
        entry.bind("<Return>", lambda _e: self.on_send_text(enter=True))

        tk.Button(text_card, text="输入", command=lambda: self.on_send_text(False),
                  relief="flat", bd=0, padx=10, pady=3, bg="#e6e6e9").grid(
            row=1, column=0, sticky="w", pady=(6, 0))
        tk.Button(text_card, text="输入 + 回车", command=lambda: self.on_send_text(True),
                  relief="flat", bd=0, padx=10, pady=3, bg="#e6e6e9").grid(
            row=1, column=1, sticky="w", padx=6, pady=(6, 0))

        presets_card = _mk_card(holder, "常用快捷键")
        presets_card.grid(row=1, column=0, sticky="nsew", pady=(8, 0))
        holder.rowconfigure(1, weight=1)

        notebook = ttk.Notebook(presets_card)
        notebook.pack(fill="both", expand=True)
        self._preset_tab(notebook, "macOS", PRESETS_MAC)
        self._preset_tab(notebook, "Windows", PRESETS_WIN)

        return holder

    def _preset_tab(self, notebook, title, presets):
        frame = tk.Frame(notebook, bg=CARD_BG, padx=4, pady=6)
        notebook.add(frame, text=title)
        columns = 5
        for col in range(columns):
            frame.columnconfigure(col, weight=1, uniform="pre" + title)
        for index, (label, combo) in enumerate(presets):
            btn = tk.Button(frame, text=label, relief="flat", bd=0, padx=3, pady=2,
                            bg="#f0f0f2", activebackground="#e2e2e6",
                            font=(UI_FAMILY, 10),
                            command=lambda c=combo: self.on_combo(c))
            btn.grid(row=index // columns, column=index % columns,
                     sticky="ew", padx=2, pady=2)

    # -- 下部：屏幕键盘（左）+ 鼠标（右） ----------------------------------
    def _build_bottom(self):
        wrap = tk.Frame(self.root, bg=PAGE_BG, padx=12, pady=4)
        wrap.grid(row=2, column=0, sticky="nsew")
        wrap.columnconfigure(0, weight=1)
        wrap.columnconfigure(1, weight=0)
        wrap.rowconfigure(0, weight=1)

        self._build_keyboard(wrap).grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self._build_mouse(wrap).grid(row=0, column=1, sticky="nsew")

    def _build_keyboard(self, parent):
        card = _mk_card(parent, "屏幕键盘（⇧ ⌥ ⌘ ctrl 为粘滞键）")
        for r, row in enumerate(KB_ROWS):
            row_frame = tk.Frame(card, bg=CARD_BG)
            row_frame.grid(row=r, column=0, sticky="ew", pady=1)
            card.columnconfigure(0, weight=1)
            for col in range(len(row)):
                row_frame.columnconfigure(col, weight=1, uniform=f"kb{r}")

            for col, (label, token) in enumerate(row):
                btn = tk.Button(row_frame, text=label, relief="flat", bd=0, pady=3,
                                bg="#f4f4f6", activebackground="#e2e2e6", fg=INK,
                                font=(UI_FAMILY, 10),
                                command=lambda t=token: self.on_key(t))
                btn.grid(row=0, column=col, sticky="ew", padx=1)
                self.key_buttons.setdefault(token, []).append(btn)
                if token in MODIFIER_TOKENS:
                    self.mod_buttons.setdefault(token, []).append(btn)
                    btn.configure(fg="#0a5bd0")
        return card

    def _build_mouse(self, parent):
        card = _mk_card(parent, "鼠标（拖动 = 移动指针）")
        card.configure(width=320)
        card.columnconfigure(0, weight=1)
        card.rowconfigure(0, weight=1)

        self.pad = tk.Canvas(card, width=290, height=104, bg="#fbfbfd",
                             highlightthickness=1, highlightbackground="#dcdce0",
                             cursor="hand2")
        self.pad.grid(row=0, column=0, sticky="nsew")
        self._pad_hint = self.pad.create_text(145, 52, text="按住拖动",
                                              fill="#8e8e93", font=(UI_FAMILY, 11))
        self.pad.bind("<Configure>", self._pad_resize)
        self.pad.bind("<ButtonPress-1>", self._pad_down)
        self.pad.bind("<B1-Motion>", self._pad_drag)
        self.pad.bind("<ButtonRelease-1>", self._pad_up)

        keys = tk.Frame(card, bg=CARD_BG)
        keys.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        for col in range(3):
            keys.columnconfigure(col, weight=1, uniform="mk")
        for col, (label, name) in enumerate((("左键", "left"), ("中键", "middle"),
                                             ("右键", "right"))):
            btn = tk.Button(keys, text=label, relief="flat", bd=0, pady=4, bg="#f0f0f2",
                            activebackground="#e2e2e6")
            btn.grid(row=0, column=col, sticky="ew", padx=2)
            btn.bind("<ButtonPress-1>", lambda _e, n=name: self._mouse_down(n))
            btn.bind("<ButtonRelease-1>", lambda _e, n=name: self._mouse_up(n))

        extra = tk.Frame(card, bg=CARD_BG)
        extra.grid(row=2, column=0, sticky="ew", pady=(6, 0))
        for col in range(3):
            extra.columnconfigure(col, weight=1, uniform="mk2")
        tk.Button(extra, text="滚轮 ↑", command=lambda: self.on_wheel(3), relief="flat",
                  bd=0, pady=4, bg="#f0f0f2").grid(row=0, column=0, sticky="ew", padx=2)
        tk.Button(extra, text="滚轮 ↓", command=lambda: self.on_wheel(-3), relief="flat",
                  bd=0, pady=4, bg="#f0f0f2").grid(row=0, column=1, sticky="ew", padx=2)
        self.lock_btn = tk.Button(extra, text="按住左键", command=self.on_drag_lock,
                                  relief="flat", bd=0, pady=4, bg="#f0f0f2")
        self.lock_btn.grid(row=0, column=2, sticky="ew", padx=2)

        speed = tk.Frame(card, bg=CARD_BG)
        speed.grid(row=3, column=0, sticky="ew", pady=(8, 0))
        speed.columnconfigure(1, weight=1)
        tk.Label(speed, text="速度", bg=CARD_BG, fg=INK_SOFT).grid(row=0, column=0,
                                                                  sticky="w")
        self.speed_scale = tk.Scale(speed, from_=0.5, to=4.0, resolution=0.1,
                                    orient="horizontal", showvalue=0,
                                    command=self._on_speed, bg=CARD_BG,
                                    highlightthickness=0, sliderlength=14,
                                    length=120, troughcolor="#e6e6e9")
        self.speed_scale.set(self.mouse_speed)
        self.speed_scale.grid(row=0, column=1, sticky="ew", padx=6)
        self.speed_var = tk.StringVar(value=f"{self.mouse_speed:.1f}×")
        tk.Label(speed, textvariable=self.speed_var, bg=CARD_BG, fg=INK_SOFT,
                 width=4, anchor="e").grid(row=0, column=2, sticky="e")

        return card

    # -- 日志 --------------------------------------------------------------
    def _build_log(self):
        card = tk.LabelFrame(self.root, text=" 日志 ", bg=PAGE_BG, fg=INK_SOFT,
                             bd=1, relief="solid")
        card.grid(row=3, column=0, sticky="ew", padx=12, pady=(0, 12))
        card.columnconfigure(0, weight=1)

        self.log_text = tk.Text(card, height=6, wrap="word", relief="flat", bd=0,
                                bg="#fbfbfd", fg=INK, font=(MONO_FAMILY, 10))
        self.log_text.grid(row=0, column=0, sticky="ew")
        scroll = ttk.Scrollbar(card, orient="vertical", command=self.log_text.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.log_text.configure(yscrollcommand=scroll.set, state="disabled")
        self.log_text.tag_configure("err", foreground="#c7251b")
        self.log_text.tag_configure("ok", foreground="#1f7a33")
        self.log_text.tag_configure("recv", foreground="#0a5bd0")

    # -- 事件轮询 ----------------------------------------------------------
    def _poll(self):
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break
            self._handle_event(event)

        self._paint_status()
        self.root.after(100, self._poll)

    def _handle_event(self, event):
        kind = event[0]
        if kind == "log":
            text, is_error = event[1], event[2]
            if text.startswith("TCC:"):
                self._append_log("蓝牙权限被拦截", True)
                messagebox.showerror("蓝牙权限被 macOS 拦截", text[4:])
                return
            if text.startswith("← "):
                self._append_log(text, False, "recv")
                self._note_reply(text[2:])
                return
            self._append_log(text, is_error)
            return
        if kind == "state":
            _state, text = event[1], event[2]
            self.status_var.set(text)
            self._update_buttons()

    def _append_log(self, text, is_error=False, tag=None):
        stamp = time.strftime("%H:%M:%S")
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"{stamp}  {text}\n", tag or ("err" if is_error else ""))
        lines = int(self.log_text.index("end-1c").split(".")[0])
        if lines > 400:
            self.log_text.delete("1.0", f"{lines - 400}.0")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _note_reply(self, line):
        if line.startswith("BOOTKEY:"):
            token = line.split(":", 1)[1].strip()
            self.bios_current = token
            self.bios_var.set(token)
            self.bios_note_var.set("固件当前：" + token)
        elif line.startswith("BOOTKEY-ERR:"):
            self.bios_note_var.set("固件不认这个键：" + line.split(":", 1)[1])
        elif line.startswith("PONG:"):
            self.hint_var.set("链路正常 · " + line)

    def _paint_status(self):
        state = self.link.state
        color = {"connected": OK, "scanning": ACCENT, "connecting": ACCENT,
                 "failed": DANGER}.get(state, "#b0b0b5")
        self.dot.itemconfigure(self._dot_item, fill=color)

        left = self.link.remaining()
        if left > 0 and self.link.phase_total > 0:
            if not self.progress.winfo_ismapped():
                self.progress.pack(side="left")
            self.progress.configure(value=1.0 - left / self.link.phase_total)
            self.hint_var.set(f"还剩 {math.ceil(left)} 秒")
        else:
            if self.progress.winfo_ismapped():
                self.progress.pack_forget()

        self._update_buttons()

    def _update_buttons(self):
        busy = self.link.state in ("scanning", "connecting")
        connected = self.link.state == "connected"
        self.connect_btn.configure(state="disabled" if busy or connected else "normal")
        self.stop_btn.configure(state="normal" if busy else "disabled")
        self.disconnect_btn.configure(state="normal" if connected or busy else "disabled")

    def _refresh_trust(self):
        if not FORWARDER_CLASS.available():
            self.trust_var.set("未安装 pyobjc（不能转发本机键盘）" if IS_MAC
                               else "当前平台不支持本机键盘转发")
            self.trust_dot.itemconfigure(self._trust_item, fill="#b0b0b5")
        elif FORWARDER_CLASS.trusted():
            self.trust_var.set("无需额外授权（可直接捕获）" if IS_WIN
                               else "已授权辅助功能")
            self.trust_dot.itemconfigure(self._trust_item, fill=OK)
        else:
            self.trust_var.set("未授权辅助功能")
            self.trust_dot.itemconfigure(self._trust_item, fill=DANGER)

        capturing = self.fwd.capturing
        can_capture = FORWARDER_CLASS.available()
        self.capture_btn.configure(state="normal" if can_capture and not capturing
                                   else "disabled")
        self.capture_stop_btn.configure(state="normal" if capturing else "disabled")
        self.root.after(1000, self._refresh_trust)

    # -- 连接动作 ----------------------------------------------------------
    def on_connect(self):
        kind = self.mode_var.get()
        try:
            port = int(self.port_var.get().strip() or DEFAULT_PORT)
        except ValueError:
            messagebox.showerror("端口不合法", "端口要填数字，例如 8266")
            return
        self._append_log(f"开始连接（{'Wi-Fi' if kind == 'wifi' else '蓝牙'}）")
        self.link.connect(kind=kind,
                          name=self.name_var.get().strip() or DEFAULT_NAME,
                          host=self.host_var.get().strip() or DEFAULT_HOST,
                          port=port)

    def on_stop(self):
        self.link.cancel()
        self._release_all_local()

    def on_disconnect(self):
        self._release_all_local()
        self.link.disconnect()

    def _release_all_local(self):
        self.link.send(Cmd.RELEASE_ALL)
        if self.mouse_held:
            self.link.send(Cmd.MOUSE_RELEASE)
            self.mouse_held.clear()
        for token in list(self.sticky):
            self.sticky.discard(token)
            self._paint_mod(token)

    def on_release_all(self):
        self._release_all_local()
        self._append_log("已请求松开所有按键")

    # -- 屏幕键盘 ----------------------------------------------------------
    def on_key(self, token):
        if token in MODIFIER_TOKENS:
            active = token not in self.sticky
            if active:
                self.sticky.add(token)
                self.send(Cmd.down(token))
            else:
                self.sticky.discard(token)
                self.send(Cmd.up(token))
            self._paint_mod(token)
            return

        # 粘滞键：这个字敲完（松手之后）再松开修饰键，
        # 否则主机会先看到 Shift 抬起、再看到字母，组合就失效了
        up_at = self._tap(token)
        if self.sticky:
            self.root.after(int((up_at + 0.01) * 1000), self._release_sticky)

    def _release_sticky(self):
        for mod in list(self.sticky):
            self.sticky.discard(mod)
            self.send(Cmd.up(mod))
            self._paint_mod(mod)

    def _tap(self, token):
        """按下 → 30ms → 松开；返回距离「松开」还有多少秒。

        和本机转发走同一条路径（DOWN/UP），不用固件的 TAP：这样主机收到的
        报告序列一模一样，不会出现「捕获能用、屏幕键盘不灵」。
        同时按「上一次还没松完」串行化，快速连点不会把两个 DOWN 挤成一次按住。
        """
        if self.link.state != "connected":
            self.send(Cmd.down(token))     # 只为触发「未连接」日志提示
            self._flash(token)
            return 0.0

        now = time.monotonic()
        start = max(now, self._tap_busy_until)
        down_delay = start - now
        self._tap_busy_until = start + KEY_HOLD + 0.005

        if down_delay <= 0.0005:
            self.send(Cmd.down(token))
        else:
            self.root.after(int(down_delay * 1000), lambda: self.send(Cmd.down(token)))
        up_at = down_delay + KEY_HOLD
        self.root.after(int(up_at * 1000), lambda: self.send(Cmd.up(token)))
        self._flash(token)
        return up_at

    def _flash(self, token):
        for btn in self.key_buttons.get(token, []):
            try:
                btn.configure(bg="#cfe6ff")
            except tk.TclError:
                return

        def restore():
            for btn in self.key_buttons.get(token, []):
                try:
                    btn.configure(bg="#f4f4f6")
                except tk.TclError:
                    return

        self.root.after(120, restore)

    def _paint_mod(self, token):
        active = token in self.sticky
        for btn in self.mod_buttons.get(token, []):
            try:
                btn.configure(bg="#cfe6ff" if active else "#f4f4f6",
                              fg="#c7251b" if active else "#0a5bd0")
            except tk.TclError:
                return

    def on_combo(self, combo):
        self.send(Cmd.combo(combo))
        self._append_log("发送 " + Cmd.combo(combo))

    def on_send_text(self, enter=False):
        text = self.text_var.get()
        if not text and not enter:
            return
        if text:
            self.send(Cmd.type_text(text))
        if enter:
            self._tap("enter")
        self.text_var.set("")

    # -- BIOS --------------------------------------------------------------
    def on_bios_key(self):
        token = self.bios_var.get()
        self.send(Cmd.boot_key(token))
        self._append_log(f"写入引导键：{token}（掉电保持）")

    def on_bios_now(self):
        self.send(Cmd.BOOT_KEY_NOW)
        self._append_log("让固件立即重来一轮连发")

    def on_bios_query(self):
        self.send(Cmd.BOOT_KEY_QUERY)

    # -- 鼠标 --------------------------------------------------------------
    def _pad_resize(self, event):
        self.pad.coords(self._pad_hint, event.width / 2, event.height / 2)

    def _pad_down(self, event):
        self._pad_last = (event.x, event.y)

    def _pad_drag(self, event):
        if self._pad_last is None:
            self._pad_last = (event.x, event.y)
            return
        last_x, last_y = self._pad_last
        self._pad_last = (event.x, event.y)
        self._pad_move(event.x - last_x, event.y - last_y)

    def _pad_up(self, _event):
        self._pad_last = None
        self._drain_pad()

    def _pad_move(self, dx, dy):
        self._pad_pending[0] += dx * self.mouse_speed
        self._pad_pending[1] += dy * self.mouse_speed
        if self._pad_timer is None:
            self._pad_timer = self.root.after(33, self._drain_pad)

    def _drain_pad(self):
        self._pad_timer = None
        x = int(self._pad_pending[0])
        y = int(self._pad_pending[1])
        self._pad_pending[0] -= x
        self._pad_pending[1] -= y

        # HID 相对报告的 dx/dy 是 int8，超过 ±127 要拆成多条，否则位移会被截断
        while x != 0 or y != 0:
            step_x = max(-127, min(127, x))
            step_y = max(-127, min(127, y))
            self.send(Cmd.mouse_move(step_x, step_y))
            x -= step_x
            y -= step_y

        if abs(self._pad_pending[0]) > 0.5 or abs(self._pad_pending[1]) > 0.5:
            self._pad_timer = self.root.after(33, self._drain_pad)

    def _mouse_down(self, name):
        if name in self.mouse_held:
            return
        self.mouse_held.add(name)
        self.send(Cmd.mouse_down(name))

    def _mouse_up(self, name):
        if name not in self.mouse_held:
            return
        self.mouse_held.discard(name)
        self.send(Cmd.mouse_up(name))

    def on_wheel(self, n):
        self.send(Cmd.mouse_wheel(n))

    def on_drag_lock(self):
        if self.drag_lock:
            self.drag_lock = False
            self._mouse_up("left")
            self.lock_btn.configure(text="按住左键", bg="#f0f0f2")
        else:
            self.drag_lock = True
            self._mouse_down("left")
            self.lock_btn.configure(text="松开左键", bg="#ffd9a0")

    def _on_speed(self, value):
        self.mouse_speed = float(value)
        self.speed_var.set(f"{self.mouse_speed:.1f}×")

    # -- 本机键盘转发 ------------------------------------------------------
    def on_capture(self):
        if self.fwd.start():
            self._append_log("开始捕获本机键盘")
        self._refresh_trust()

    def on_stop_capture(self):
        self.fwd.stop()
        self._refresh_trust()

    def _fwd_command(self, line):
        # 来自 tap 线程：Link.send 本身线程安全（BLE 走 loop 投递 / Wi-Fi 走 socket）
        self.link.send(line)

    def _fwd_log(self, text, is_error=False):
        self.events.put(("log", text, is_error))

    def _fwd_stopped(self):
        self.root.after(0, self._refresh_trust)

    # -- 发送 --------------------------------------------------------------
    def send(self, line):
        self.link.send(line)

    # -- 关闭 --------------------------------------------------------------
    def on_close(self):
        try:
            self.fwd.stop()
        except Exception:                              # noqa: BLE001
            pass
        self.send(Cmd.RELEASE_ALL)
        self.send(Cmd.MOUSE_RELEASE)
        self.link.disconnect()
        self.root.destroy()


# ---------------------------------------------------------------------------
# 五、命令行模式
# ---------------------------------------------------------------------------
def run_cli(mode, name, host, port):
    def emit(event):
        if event[0] == "log":
            text, is_error = event[1], event[2]
            if text.startswith("TCC:"):
                print(text[4:], file=sys.stderr, flush=True)
            else:
                print(("!! " if is_error else "[") + text, file=sys.stderr, flush=True)
        elif event[0] == "state":
            print(f"== {event[2]}", file=sys.stderr, flush=True)

    link = Link(emit)
    link.connect(kind=mode, name=name, host=host, port=port)

    deadline = time.monotonic() + SCAN_TIMEOUT + CONNECT_TIMEOUT + 6
    while time.monotonic() < deadline:
        if link.connected:
            break
        if link.state == "failed":
            link.disconnect()
            return 1
        time.sleep(0.2)

    if not link.connected:
        print("连接超时", file=sys.stderr)
        link.disconnect()
        return 1

    print("已连接。直接输入协议命令，例如 TAP:enter / COMBO:cmd+c / MOUSE:move 10 0",
          file=sys.stderr)
    try:
        for line in sys.stdin:
            line = line.rstrip("\r\n")
            if line:
                link.send(line)
    except KeyboardInterrupt:
        pass
    finally:
        link.send(Cmd.RELEASE_ALL)
        link.disconnect()
    return 0


def _ensure_streams():
    """PyInstaller 的 --windowed 包里 stdout/stderr 是 None，print 会炸。"""
    for name in ("stdout", "stderr"):
        if getattr(sys, name, None) is None:
            try:
                setattr(sys, name, open(os.devnull, "w", encoding="utf-8"))
            except OSError:
                pass


def _resource_path(name):
    """图标这类随程序走的资源：源码运行看本文件旁边，打包后看 _MEIPASS。"""
    base = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, name)


def _enable_hi_dpi():
    """Windows 上先声明 DPI 感知，否则 125%/150% 缩放下整个窗口是糊的。"""
    if not IS_WIN:
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)      # 系统级 DPI 感知
    except Exception:                                       # noqa: BLE001
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:                                   # noqa: BLE001
            pass


def _choose_fonts(root):
    """按平台挑一个真实存在的字体，缺字体时中文会变成方块。"""
    global UI_FAMILY, MONO_FAMILY
    try:
        families = set(tkfont.families(root))
    except Exception:                                       # noqa: BLE001
        return
    ui = (("Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", "Arial") if IS_WIN
          else ("Helvetica", "PingFang SC", "Arial"))
    mono = (("Consolas", "Courier New") if IS_WIN else ("Menlo", "Monaco", "Courier"))
    for name in ui:
        if name in families:
            UI_FAMILY = name
            break
    for name in mono:
        if name in families:
            MONO_FAMILY = name
            break


def _apply_window_icon(root):
    """窗口和任务栏图标。macOS 的 Dock 图标由 .app 的 Info.plist 决定，这里不影响。"""
    ico = _resource_path("app_icon.ico")
    png = _resource_path("app_icon_256.png")
    if IS_WIN and os.path.exists(ico):
        try:
            root.iconbitmap(default=ico)
            return
        except tk.TclError:
            pass
    if os.path.exists(png):
        try:
            image = tk.PhotoImage(file=png)
            root.iconphoto(True, image)
            root._icon_image = image        # 不存引用会被 GC，图标变成空白
        except tk.TclError:
            pass


def _ensure_tcl_env():
    """给 Tk 指明 tcl/tk 库在哪。

    有些 Python 发行版（便携版、venv 套在便携版上）把 tcl 目录放在
    <prefix>/lib/tcl9.0 或 <prefix>/tcl/tcl8.6，而 Tk 自己的搜索路径只认
    编译时的前缀，于是启动时报 “Cannot find a usable init.tcl”。
    这里按实际目录补上环境变量，比让用户去设 TCL_LIBRARY 靠谱。
    """
    if os.environ.get("TCL_LIBRARY"):
        return
    candidates = []
    for base in (sys.base_prefix, sys.prefix):
        if not base:
            continue
        for folder in ("lib", "tcl"):
            for pattern in ("tcl8*/init.tcl", "tcl9*/init.tcl"):
                candidates.extend(sorted(Path(base, folder).glob(pattern)))
    if not candidates:
        return
    tcl_dir = candidates[0].parent
    os.environ["TCL_LIBRARY"] = str(tcl_dir)
    if not os.environ.get("TK_LIBRARY"):
        tk_dir = tcl_dir.parent / ("tk" + tcl_dir.name[3:])
        if tk_dir.is_dir():
            os.environ["TK_LIBRARY"] = str(tk_dir)


def main():
    _ensure_streams()
    parser = argparse.ArgumentParser(description="ESP32-S3 无线键盘控制端（Python 版）")
    parser.add_argument("--name", default=DEFAULT_NAME, help="BLE 设备名")
    parser.add_argument("--mode", choices=("ble", "wifi"), default="ble", help="链路类型")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Wi-Fi 链路的主机地址")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Wi-Fi 链路的端口")
    parser.add_argument("--cli", action="store_true", help="命令行模式")
    args = parser.parse_args()

    if args.cli:
        return run_cli(args.mode, args.name, args.host, args.port)

    if tk is None:
        print("当前 Python 没有 tkinter，请改用 --cli，或安装 python.org 版 Python / "
              "brew install python-tk", file=sys.stderr)
        return 1

    _enable_hi_dpi()
    _ensure_tcl_env()
    root = tk.Tk()
    _choose_fonts(root)
    _apply_window_icon(root)
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    root.geometry(f"{min(1256, sw - 80)}x{min(900, sh - 120)}")
    App(root, args.name, args.host, args.port)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
