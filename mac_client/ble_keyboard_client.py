#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MacBook 端控制程序 —— ESP32-S3 无线键盘桥

通过 BLE 连接 ESP32-S3（默认设备名 ESP32-Keyboard），把按键命令写进
自定义 GATT 特征，由 ESP32-S3 转成 USB HID 输入给主机。

用法：
    python3 ble_keyboard_client.py            # 图形界面
    python3 ble_keyboard_client.py --cli      # 命令行模式，逐行输入协议命令
    python3 ble_keyboard_client.py --name XXX # 指定设备名

依赖：
    pip3 install bleak
"""

import argparse
import asyncio
import os
import queue
import signal
import subprocess
import sys
import threading
import time

try:
    import tkinter as tk
except ImportError:  # 允许在无 tkinter 的环境下使用 --cli
    tk = None

# ---------------------------------------------------------------------------
# 与 ESP32 端保持一致
# ---------------------------------------------------------------------------
SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
RX_UUID = "12345678-1234-5678-1234-56789abcdef1"   # 写入命令
TX_UUID = "12345678-1234-5678-1234-56789abcdef2"   # 接收通知
DEFAULT_NAME = "ESP32-Keyboard"
WRITE_CHUNK = 20  # 按最小 MTU(23) 保守分片，保证兼容性

# 与 build_app.sh 里生成的 Info.plist 保持一致
BUNDLE_ID = "local.esp32keyboard"
TCC_HINT = (
    "macOS 拦住了蓝牙访问：当前进程所属的 App 没有蓝牙用途声明，"
    "系统会直接杀掉进程，所以窗口一闪就没了（这不是代码 bug）。\n\n"
    "请双击项目里的 ESP32Keyboard.app 启动；\n"
    "若还没有它，先运行 mac_client/build_app.sh 生成。"
)

_tcc_blocked = None  # None=未检测 / True=被拦截 / False=可用


def probe_macos_bluetooth():
    """在子进程里试一次蓝牙扫描，判断当前进程能否访问 CoreBluetooth。

    macOS 的 TCC 会对「没有 NSBluetoothAlwaysUsageDescription 声明的进程」
    直接发 SIGKILL。主进程一旦踩中必死，try/except 救不回来，
    所以只能先派一个牺牲进程去试探，主进程看它的死法做判断。
    """
    global _tcc_blocked
    if _tcc_blocked is not None:
        return _tcc_blocked
    if sys.platform != "darwin":
        _tcc_blocked = False
        return False

    code = (
        "import asyncio\n"
        "from bleak import BleakScanner\n"
        "asyncio.run(BleakScanner.discover(timeout=0.5))\n"
    )
    try:
        proc = subprocess.run(
            [sys.executable, "-c", code],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
        )
    except subprocess.TimeoutExpired:
        # 多半是授权弹窗还没点，先按不可用处理，提示用户去点「允许」
        _tcc_blocked = True
        return True
    except Exception:  # noqa: BLE001
        _tcc_blocked = False
        return False

    if proc.returncode == 0:
        _tcc_blocked = False
        return False

    # 被信号 9(SIGKILL) / 6(SIGABRT) 干掉，基本就是 TCC 干的
    if proc.returncode < 0 and -proc.returncode in (signal.SIGKILL, signal.SIGABRT):
        _tcc_blocked = True
        return True

    _tcc_blocked = False
    return False


# ---------------------------------------------------------------------------
# BLE 连接管理：asyncio 跑在后台线程，GUI 线程只投递任务
# ---------------------------------------------------------------------------
class Link:
    def __init__(self, status_cb):
        self._status = status_cb
        self._loop = asyncio.new_event_loop()
        self._lock = None
        self.client = None
        self.connected = False
        self.connected_event = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    # -- 线程入口 ----------------------------------------------------------
    def _run(self):
        asyncio.set_event_loop(self._loop)
        self._lock = asyncio.Lock()
        self._loop.run_forever()

    # -- 对外接口（任意线程可调用） ----------------------------------------
    def connect(self, name=DEFAULT_NAME, address=None):
        asyncio.run_coroutine_threadsafe(self._connect(name, address), self._loop)

    def disconnect(self):
        asyncio.run_coroutine_threadsafe(self._disconnect(), self._loop)

    def send(self, line):
        asyncio.run_coroutine_threadsafe(self._send(line), self._loop)

    def shutdown(self):
        try:
            asyncio.run_coroutine_threadsafe(self._disconnect(), self._loop).result(timeout=3)
        except Exception:
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)

    # -- 内部实现 ----------------------------------------------------------
    async def _connect(self, name, address):
        if self.connected:
            return
        try:
            from bleak import BleakClient, BleakScanner
        except ImportError:
            self._status("缺少 bleak 库，请先执行: pip3 install bleak")
            return

        self._status("检查蓝牙权限…")
        if await asyncio.to_thread(probe_macos_bluetooth):
            # 交给上层展示（GUI 弹窗 / CLI 打印），这里只发一条消息
            self._status("TCC:" + TCC_HINT)
            return

        self._status("扫描中…")
        device = None
        try:
            if address:
                device = await BleakScanner.find_device_by_address(address, timeout=10.0)
            if device is None and hasattr(BleakScanner, "find_device_by_name"):
                device = await BleakScanner.find_device_by_name(name, timeout=10.0)
            if device is None:
                # 兼容旧版 bleak
                devices = await BleakScanner.discover(timeout=10.0)
                for d in devices:
                    if d.name == name:
                        device = d
                        break
                    if d.name and name.lower() in d.name.lower():
                        device = d
                        break
        except Exception as exc:                       # noqa: BLE001
            self._status(f"扫描出错: {exc}")
            return

        if device is None:
            self._status(f"未找到设备 “{name}”，确认 ESP32 已上电并在广播")
            return

        self._status(f"正在连接 {device.address} …")
        client = BleakClient(device, disconnected_callback=self._on_disconnect)
        try:
            await asyncio.wait_for(client.connect(), timeout=25)
        except asyncio.TimeoutError:
            self._status("连接超时，请确认 ESP32 已上电且未被其它设备占用")
            await self._safe_disconnect(client)
            return
        except Exception as exc:                       # noqa: BLE001
            self._status(f"连接失败: {exc}")
            await self._safe_disconnect(client)
            return

        if self._find_char(client, RX_UUID) is None:
            try:
                await client.disconnect()
            except Exception:                          # noqa: BLE001
                pass
            self._status("已连接但找不到服务，检查两端 UUID 是否一致")
            return

        self.client = client
        self.connected = True
        self.connected_event.set()
        self._status(f"已连接 ({device.name or device.address})")

    async def _disconnect(self):
        client = self.client
        self.client = None
        self.connected = False
        self.connected_event.clear()
        if client is not None:
            try:
                await client.disconnect()
            except Exception:                          # noqa: BLE001
                pass
        self._status("已断开")

    @staticmethod
    async def _safe_disconnect(client):
        try:
            await client.disconnect()
        except Exception:                              # noqa: BLE001
            pass

    async def _send(self, line):
        if not self.connected or self.client is None:
            return
        if self._lock is None:  # 极少见的线程启动竞态
            self._lock = asyncio.Lock()
        payload = (line + "\n").encode("utf-8")
        async with self._lock:
            try:
                for i in range(0, len(payload), WRITE_CHUNK):
                    chunk = payload[i: i + WRITE_CHUNK]
                    try:
                        await self.client.write_gatt_char(RX_UUID, chunk, response=False)
                    except Exception:                   # noqa: BLE001
                        await self.client.write_gatt_char(RX_UUID, chunk, response=True)
            except Exception as exc:                    # noqa: BLE001
                self._status(f"发送失败: {exc}")

    def _on_disconnect(self, client):
        self.connected = False
        self.connected_event.clear()
        self._status("连接已断开")

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


# ---------------------------------------------------------------------------
# 屏幕键盘布局：(显示文字, 发送的键名)
# ---------------------------------------------------------------------------
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

MODIFIERS = {"shift", "ctrl", "alt", "cmd"}

PRESETS = [
    ("复制", "cmd+c"), ("粘贴", "cmd+v"), ("剪切", "cmd+x"), ("撤销", "cmd+z"),
    ("全选", "cmd+a"), ("保存", "cmd+s"), ("查找", "cmd+f"), ("新建", "cmd+n"),
    ("关闭窗口", "cmd+w"), ("切换窗口", "cmd+tab"), ("聚焦搜索", "cmd+space"),
    ("区域截图", "cmd+shift+4"), ("全屏截图", "cmd+shift+3"), ("锁屏", "ctrl+cmd+q"),
]


# ---------------------------------------------------------------------------
# 图形界面
# ---------------------------------------------------------------------------
class App:
    def __init__(self, root, device_name=DEFAULT_NAME):
        self.root = root
        self.msgs = queue.Queue()
        self.link = Link(self.msgs.put)
        self.sticky = {}          # 修饰键状态
        self.mod_buttons = {}     # 修饰键 -> [按钮, ...]（左右 Shift 各一个）
        self.active_relief = {}   # 记录原始 relief

        root.title("ESP32-S3 无线键盘")
        root.minsize(760, 420)

        self._build_top(device_name)
        self._build_text()
        self._build_presets()
        self._build_keyboard()

        root.protocol("WM_DELETE_WINDOW", self.on_close)
        root.after(100, self._poll_messages)

    # -- 界面搭建 ----------------------------------------------------------
    def _build_top(self, device_name):
        frame = tk.Frame(self.root, padx=12, pady=10)
        frame.pack(fill="x")

        tk.Label(frame, text="设备名").pack(side="left")
        self.name_var = tk.StringVar(value=device_name)
        tk.Entry(frame, textvariable=self.name_var, width=20).pack(side="left", padx=(6, 12))

        tk.Button(frame, text="连接", width=8, command=self.on_connect).pack(side="left")
        tk.Button(frame, text="断开", width=8, command=self.on_disconnect).pack(side="left", padx=6)
        tk.Button(frame, text="释放全部按键", command=self.on_release_all).pack(side="left", padx=6)

        self.status_var = tk.StringVar(value="未连接")
        tk.Label(frame, textvariable=self.status_var, fg="#2563eb", anchor="w").pack(
            side="left", padx=12, fill="x", expand=True)

    def _build_text(self):
        frame = tk.Frame(self.root, padx=12, pady=4)
        frame.pack(fill="x")

        tk.Label(frame, text="文字").pack(side="left")
        self.text_var = tk.StringVar()
        entry = tk.Entry(frame, textvariable=self.text_var)
        entry.pack(side="left", fill="x", expand=True, padx=8)
        entry.bind("<Return>", lambda _e: self.on_send_text(enter=True))

        tk.Button(frame, text="输入", width=8, command=lambda: self.on_send_text(False)).pack(side="left")
        tk.Button(frame, text="输入+回车", width=10, command=lambda: self.on_send_text(True)).pack(
            side="left", padx=6)

    def _build_presets(self):
        frame = tk.LabelFrame(self.root, text="常用快捷键", padx=10, pady=8)
        frame.pack(fill="x", padx=12, pady=6)

        for index, (label, combo) in enumerate(PRESETS):
            btn = tk.Button(frame, text=label, command=lambda c=combo: self.on_combo(c))
            btn.grid(row=index // 7, column=index % 7, sticky="ew", padx=3, pady=3)
        for col in range(7):
            frame.columnconfigure(col, weight=1)

    def _build_keyboard(self):
        frame = tk.LabelFrame(self.root, text="屏幕键盘（⇧ ⌥ ⌘ ctrl 为粘滞键，点一下生效，按完一个键自动松开）",
                              padx=8, pady=8)
        frame.pack(fill="both", expand=True, padx=12, pady=(6, 12))

        for r, row in enumerate(KB_ROWS):
            row_frame = tk.Frame(frame)
            row_frame.pack(fill="x", pady=1)
            for label, token in row:
                btn = tk.Button(
                    row_frame,
                    text=label,
                    height=1,
                    relief="raised",
                    command=lambda t=token: self.on_key(t),
                )
                btn.pack(side="left", fill="x", expand=True, padx=1)
                if token in MODIFIERS:
                    self.mod_buttons.setdefault(token, []).append(btn)
                    self.active_relief[token] = btn.cget("relief")
                    btn.configure(fg="#1d4ed8")

    # -- 消息轮询 ----------------------------------------------------------
    def _poll_messages(self):
        while True:
            try:
                msg = self.msgs.get_nowait()
            except queue.Empty:
                break
            if msg.startswith("TCC:"):
                # 蓝牙权限被 macOS 拦截，用弹窗把原因说清楚，否则用户只看到「连不上」
                self.status_var.set("蓝牙权限被拦截，请用 ESP32Keyboard.app 启动")
                from tkinter import messagebox
                messagebox.showerror("蓝牙权限被 macOS 拦截", msg[4:])
            else:
                self.status_var.set(msg)
        self.root.after(100, self._poll_messages)

    # -- 动作 --------------------------------------------------------------
    def on_connect(self):
        self.link.connect(self.name_var.get().strip() or DEFAULT_NAME)

    def on_disconnect(self):
        self.on_release_all(send_only=True)
        self.link.disconnect()

    def on_release_all(self, send_only=False):
        self.link.send("RELEASEALL")
        for mod in list(self.sticky):
            self.sticky[mod] = False
            self._paint_mod(mod)

    def _clear_sticky(self):
        for mod, active in list(self.sticky.items()):
            if active:
                self.link.send(f"UP:{mod}")
                self.sticky[mod] = False
                self._paint_mod(mod)

    def on_combo(self, combo):
        self._clear_sticky()
        self.link.send(f"COMBO:{combo}")

    def on_send_text(self, enter=False):
        text = self.text_var.get()
        if not text and not enter:
            return
        if text:
            self.link.send(f"TYPE:{text}")
        if enter:
            self.link.send("TAP:enter")
        self.text_var.set("")

    def on_key(self, token):
        if token in MODIFIERS:
            active = not self.sticky.get(token, False)
            self.sticky[token] = active
            self.link.send(f"DOWN:{token}" if active else f"UP:{token}")
            self._paint_mod(token)
            return

        self.link.send(f"TAP:{token}")
        # 粘滞键：按完一个普通键就松开所有修饰键，避免按键卡住
        for mod, active in list(self.sticky.items()):
            if active:
                self.link.send(f"UP:{mod}")
                self.sticky[mod] = False
                self._paint_mod(mod)

    def _paint_mod(self, token):
        buttons = self.mod_buttons.get(token, [])
        if not buttons:
            return
        for btn in buttons:
            if self.sticky.get(token):
                btn.configure(relief="sunken", fg="#dc2626")
            else:
                btn.configure(relief=self.active_relief.get(token, "raised"), fg="#1d4ed8")

    def on_close(self):
        self.on_release_all(send_only=True)
        self.link.shutdown()
        self.root.destroy()


# ---------------------------------------------------------------------------
# 命令行模式
# ---------------------------------------------------------------------------
def _cli_status(msg):
    if msg.startswith("TCC:"):
        print(msg[4:], file=sys.stderr, flush=True)
    else:
        print(f"[{msg}]", file=sys.stderr, flush=True)


def run_cli(device_name):
    blocked = threading.Event()

    def status(msg):
        _cli_status(msg)
        if msg.startswith("TCC:"):
            blocked.set()

    link = Link(status)
    link.connect(device_name)

    # 轮询等待：连上 / 被权限拦截 / 超时，任一命中就继续
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if link.connected_event.wait(0.2):
            break
        if blocked.is_set():
            link.shutdown()
            return 1

    if not link.connected_event.is_set():
        if not blocked.is_set():
            print("连接超时", file=sys.stderr)
        link.shutdown()
        return 1

    print("已连接。直接输入协议命令，例如 TAP:enter / COMBO:cmd+c / TYPE:hello", file=sys.stderr)
    try:
        for line in sys.stdin:
            line = line.rstrip("\r\n")
            if line:
                link.send(line)
    except KeyboardInterrupt:
        pass
    finally:
        link.send("RELEASEALL")
        link.shutdown()
    return 0


# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="ESP32-S3 无线键盘控制端")
    parser.add_argument("--name", default=DEFAULT_NAME, help="BLE 设备名")
    parser.add_argument("--cli", action="store_true", help="命令行模式")
    args = parser.parse_args()

    if args.cli:
        return run_cli(args.name)

    if tk is None:
        print("当前 Python 没有 tkinter，请改用 --cli，或安装 python.org 版 Python / brew install python-tk",
              file=sys.stderr)
        return 1

    root = tk.Tk()
    App(root, args.name)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
