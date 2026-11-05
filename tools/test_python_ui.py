#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Python 版客户端的界面/协议自测（不需要板子，也不需要真的连上蓝牙）。

跑法：
    python3 tools/test_python_ui.py

为什么用「量控件」而不是截图：这台机器没有可用的显示服务，screencapture
拿不到画面；而 tkinter 自己能把每个控件的实际尺寸、颜色、布局状态都报出来，
断言这些数字比肉眼看图更可靠（折叠到底省了多少高度、字号变了会不会被裁，
都能量出来）。
"""

import importlib.util
import pathlib
import sys
import tempfile
import tkinter as tk

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLIENT = ROOT / "mac_client" / "ble_keyboard_client.py"

failures = []


def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + (("  <- " + detail) if detail and not ok
                                                     else ""))
    if not ok:
        failures.append(name)


def load_client():
    spec = importlib.util.spec_from_file_location("kb", CLIENT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # 别动用户真实的 ui.json
    module.UI_STATE_PATH = pathlib.Path(tempfile.mkdtemp()) / "ui.json"
    return module


def settle(root, times=5):
    for _ in range(times):
        root.update_idletasks()
        root.update()


def close(root):
    """先撤掉所有 after 定时器再销毁。

    App 里有 _poll / _refresh_trust 两个循环；本脚本一个进程建好几个 Tk，
    解释器销毁后这些定时器还会被 Tcl 叫一次，于是 stderr 刷一串
    「invalid command name ..._poll」。它们只是噪音，但会把测试输出弄脏。
    """
    try:
        for job in root.tk.eval("after info").split():
            root.after_cancel(job)
    except tk.TclError:
        pass
    root.destroy()


def rel_lum(hex_color):
    value = hex_color.lstrip("#")
    channels = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    channels = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                for c in channels]
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast(fg, bg):
    a, b = rel_lum(fg), rel_lum(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def is_hex(color):
    return isinstance(color, str) and color.startswith("#") and len(color) == 7


# ---------------------------------------------------------------------------
# 一、协议：命令字符串与 BOOTCFG 解析
# ---------------------------------------------------------------------------
def test_protocol(kb):
    print("\n[协议]")
    check("写入键位", kb.Cmd.boot_key("f2") == "BOOTKEY:f2", kb.Cmd.boot_key("f2"))
    check("写入时长", kb.Cmd.boot_key_window(10000) == "BOOTKEY:window 10000")
    check("写入间隔", kb.Cmd.boot_key_gap(220) == "BOOTKEY:gap 220")
    check("立即连发带参数",
          kb.Cmd.boot_key_now(10000, 220) == "BOOTKEY:now 10000 220",
          kb.Cmd.boot_key_now(10000, 220))
    check("查询", kb.Cmd.BOOT_KEY_QUERY == "BOOTKEY:?")

    tokens = [token for _label, token in kb.BIOS_KEYS]
    check("BIOS 键 15 个", len(kb.BIOS_KEYS) == 15, str(len(kb.BIOS_KEYS)))
    check("F1~F12 齐全", all(f"f{i}" in tokens for i in range(1, 13)))
    check("Del / Esc / 关闭都在",
          {"delete", "esc", "off"} <= set(tokens))
    check("键位不重复", len(tokens) == len(set(tokens)))

    cfg = kb.parse_bootcfg("BOOTCFG:key=delete,win=10000,gap=220,hold=80")
    check("BOOTCFG 解析", cfg == {"key": "delete", "win_ms": 10000, "gap_ms": 220,
                                  "hold_ms": 80}, str(cfg))
    check("坏数字返回 None", kb.parse_bootcfg("BOOTCFG:key=f2,win=abc") is None)
    check("别的行返回 None", kb.parse_bootcfg("BOOTKEY:delete") is None)
    check("摘要含关键词", "DELETE" in kb.boot_summary(cfg) and "220ms" in kb.boot_summary(cfg))


# ---------------------------------------------------------------------------
# 二、界面：能建起来、折叠真的省高度、颜色都够看
# ---------------------------------------------------------------------------
def build(kb, theme):
    root = tk.Tk()
    root.withdraw()                     # 不弹窗，纯离线量尺寸
    app = kb.App(root, theme=theme)
    settle(root)
    return root, app


def test_layout(kb, theme):
    print(f"\n[界面 / {theme}]")
    kb.UI_STATE_PATH.unlink(missing_ok=True)      # 每轮从「什么都没折叠」开始
    root, app = build(kb, theme)
    try:
        check("三张卡都能折叠", set(app.cards) == {"bios", "text", "presets"},
              str(list(app.cards)))
        check("默认都展开", all(not c.collapsed for c in app.cards.values()))

        before = sum(c.frame.winfo_reqheight() for c in app.cards.values())
        for card in app.cards.values():
            card.toggle()
        settle(root)
        after = sum(c.frame.winfo_reqheight() for c in app.cards.values())
        check("折叠后三张卡变矮", after < before - 250, f"{before} -> {after}")
        check("折叠后仍显示概要",
              all(c.summary_lbl.winfo_manager() == "pack"
                  for c in app.cards.values()))
        check("折叠后内容区摘掉",
              all(not c.body.winfo_manager() for c in app.cards.values()))

        # 概要内容：BIOS 卡说清键位和节奏，文字卡说「未输入」
        settle(root)
        check("BIOS 概要含节奏",
              app.cards["bios"].summary_lbl.cget("text").startswith("DELETE"))
        check("文字卡概要为未输入",
              app.cards["text"].summary_lbl.cget("text") == "未输入")

        # 写盘 + 新实例恢复
        saved = kb.load_ui_state()
        check("折叠状态已存盘", sorted(saved.get("collapsed", [])) == ["bios", "presets",
                                                                      "text"],
              str(saved))
    finally:
        close(root)

    root2, app2 = build(kb, theme)
    try:
        check("重新打开保持折叠",
              all(c.collapsed for c in app2.cards.values()))
        # 展开一张，别的还折着
        app2.cards["bios"].toggle()
        settle(root2)
        check("单独展开互不影响",
              not app2.cards["bios"].collapsed and app2.cards["text"].collapsed)
    finally:
        close(root2)


def test_contrast(kb, theme):
    print(f"\n[对比度 / {theme}]")
    root, app = build(kb, theme)
    try:
        worst = []
        for widget in kb._walk(root):
            cls = widget.winfo_class()
            if cls not in ("Label", "Button", "Radiobutton", "Checkbutton"):
                continue
            try:
                fg, bg = widget.cget("fg"), widget.cget("bg")
            except tk.TclError:
                continue
            if not (is_hex(fg) and is_hex(bg)):
                continue
            if cls == "Radiobutton" and widget.cget("indicatoron") in ("0", 0):
                sel = widget.cget("selectcolor")
                if is_hex(sel):
                    worst.append((min(contrast(fg, bg), contrast(fg, sel)),
                                  f"{cls}:{widget.cget('text')}"))
                    continue
            worst.append((contrast(fg, bg), f"{cls}:{widget.cget('text')}"))
        worst.sort()
        bad = [item for item in worst if item[0] < 4.2]
        check("所有文字对比度 >= 4.2", not bad,
              "; ".join(f"{name} {value:.2f}" for value, name in bad[:5]))
        low, name = worst[0]
        print(f"       最低：{name} = {low:.2f}")
    finally:
        close(root)


# ---------------------------------------------------------------------------
# 三、动作：点击/回执对应的协议命令
# ---------------------------------------------------------------------------
def test_actions(kb):
    print("\n[动作 / 协议]")
    root, app = build(kb, "light")
    sent = []
    app.link.send = lambda line: sent.append(line)
    try:
        app.bios_var.set("f12")
        app.on_bios_key()
        check("点键位只是选中、不发命令", sent == [], str(sent))

        app.boot_window_var.set("25")
        app.boot_gap_var.set("500")
        app.on_bios_write()
        check("写入固件发三条（键位/时长/间隔）",
              sent == ["BOOTKEY:f12", "BOOTKEY:window 25000", "BOOTKEY:gap 500"],
              str(sent))
        check("概要跟着更新", app.cards["bios"]._summary.startswith("F12"))

        sent.clear()
        app.on_bios_now()
        check("立即连发带上当前参数", sent == ["BOOTKEY:now 25000 500"], str(sent))

        sent.clear()
        app.on_bios_query()
        check("查询设置", sent == ["BOOTKEY:?"], str(sent))

        # 越界值要被夹回范围
        app.boot_window_var.set("999")
        app.boot_gap_var.set("1")
        app._on_boot_tune()
        check("时长夹到 60 秒", app.boot_window_ms == 60000, str(app.boot_window_ms))
        check("间隔夹到 60ms", app.boot_gap_ms == 60, str(app.boot_gap_ms))

        # 固件回报真值：以固件为准覆盖控件与概要
        app._note_reply("BOOTCFG:key=f2,win=8000,gap=300,hold=80")
        settle(root)
        check("回执回填键位", app.bios_var.get() == "f2", app.bios_var.get())
        check("回执回填时长", app.boot_window_ms == 8000, str(app.boot_window_ms))
        check("回执回填间隔", app.boot_gap_ms == 300, str(app.boot_gap_ms))
        check("回执写进底部说明",
              "间隔 300ms" in app.bios_note_var.get(), app.bios_note_var.get())

        # 老固件只回 BOOTKEY:xxx，也不能崩
        app._note_reply("BOOTKEY:esc")
        check("兼容老固件的 BOOTKEY 回执", app.bios_current == "esc")

        # 文字卡摘要跟着输入走
        app.text_var.set("hello world")
        settle(root)
        check("文字卡摘要跟随输入",
              app.cards["text"]._summary == "hello world",
              app.cards["text"]._summary)
    finally:
        close(root)


def test_theme_switch(kb):
    print("\n[换肤]")
    root, app = build(kb, "light")
    try:
        light_bg = app.cards["bios"].frame.cget("bg")
        kb.use_theme("dark")
        app.retint()
        settle(root)
        dark_bg = app.cards["bios"].frame.cget("bg")
        check("浅 -> 深：卡片底色变了", light_bg.lower() != dark_bg.lower(),
              f"{light_bg} / {dark_bg}")
        check("深色下文字变亮", app.cards["bios"].title_lbl.cget("fg").lower()
              == kb.THEME_DARK["ink_soft"].lower(),
              app.cards["bios"].title_lbl.cget("fg"))

        # 折叠着的卡换肤也要跟着变（不能只刷展开的那几张）
        app.cards["text"].toggle()
        kb.use_theme("light")
        app.retint()
        settle(root)
        check("折叠中的卡也换色",
              app.cards["text"].frame.cget("bg").lower()
              == kb.THEME_LIGHT["card"].lower(),
              app.cards["text"].frame.cget("bg"))

        # 按钮文字循环，不能抛异常
        app._cycle_appearance()
        app._cycle_appearance()
        app._cycle_appearance()
        check("外观按钮循环正常", app.appearance_btn.cget("text").startswith("外观："))
        check("外观选择已存盘", "theme" in kb.load_ui_state(), str(kb.load_ui_state()))
    finally:
        close(root)


def test_emergency_combo(kb):
    """紧急停止组合键：⌃⇧E 和 ⌃⌥Esc 都必须停，别的组合不许误停。

    这块最容易写成「条件写反」或者「少判一个修饰键」——真出问题的场合
    恰好是键盘已经被吞掉的时候，按错了就停不下来，所以单拎出来测。
    """
    print("\n[紧急停止组合键]")
    is_stop = kb.KeyForwarder._is_emergency
    check("⌃⇧E 停（keyCode 14）", is_stop(14, True, False, True))
    check("⌃⌥Esc 停（keyCode 53）", is_stop(53, True, True))
    check("⌃⇧⌥Esc 也停", is_stop(53, True, True, True))
    check("只按 Ctrl+E 不停", not is_stop(14, True, False, False))
    check("只按 Shift+E 不停", not is_stop(14, False, False, True))
    check("⌃⇧Q 不停（keyCode 12）", not is_stop(12, True, False, True))
    check("⌃⌥E 不停（少了 Shift）", not is_stop(14, True, True, False))
    check("⌃⇧Esc 不停（少了 Alt）", not is_stop(53, True, False, True))
    check("备用组合键文案存在", kb.STOP_COMBO_2 in ("⌃⇧E", "Ctrl+Shift+E"), kb.STOP_COMBO_2)


def main():
    kb = load_client()
    test_protocol(kb)
    test_emergency_combo(kb)
    test_layout(kb, "light")
    test_layout(kb, "dark")
    test_contrast(kb, "light")
    test_contrast(kb, "dark")
    test_actions(kb)
    test_theme_switch(kb)

    print()
    if failures:
        print(f"{len(failures)} 项失败：" + "、".join(failures))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
