//
//  Protocol.swift
//  ESP32-S3 无线键盘 —— 协议层
//
//  与固件 esp32s3_ble_keyboard.ino 第一部分保持一致的命令格式与键名。
//  这一层不碰蓝牙、不碰 UI：Command 负责拼字符串、KeyMap 负责键码映射、
//  ModifierMirror 负责决定什么时候该发 DOWN/UP。
//

import Foundation
import CoreGraphics

enum Link {
    static let service = "12345678-1234-5678-1234-56789abcdef0"
    static let rx = "12345678-1234-5678-1234-56789abcdef1"   // 写入命令
    static let tx = "12345678-1234-5678-1234-56789abcdef2"   // 通知回执
    static let defaultName = "ESP32-Keyboard"
}

enum Command {
    static func tap(_ token: String) -> String { "TAP:\(token)" }
    static func down(_ token: String) -> String { "DOWN:\(token)" }
    static func up(_ token: String) -> String { "UP:\(token)" }
    static func type(_ text: String) -> String { "TYPE:\(text)" }

    /// 组合键。keys 按顺序按下，固件会逆序松开。
    static func combo(_ keys: [String]) -> String { "COMBO:" + keys.joined(separator: "+") }

    static let releaseAll = "RELEASEALL"
    static let ping = "PING"

    /// 开机引导键：改固件在主机 POST 阶段自动连发的那个键（写进 NVS，掉电保持）
    static func bootKey(_ token: String) -> String { "BOOTKEY:\(token)" }
    /// 查询固件当前的引导键设置
    static let bootKeyQuery = "BOOTKEY:?"
    /// 立刻重来一轮连发（用于已经进了 BIOS 界面但还想敲一次）
    static let bootKeyNow = "BOOTKEY:now"
    /// 立刻连发，并顺手把时长/间隔写进固件（一次往返，少一次竞态）
    static func bootKeyNow(windowMs: Int, gapMs: Int) -> String {
        "BOOTKEY:now \(windowMs) \(gapMs)"
    }
    /// 连发时长：开机后连发多久（固件会夹到 1000~60000ms）
    static func bootKeyWindow(_ ms: Int) -> String { "BOOTKEY:window \(ms)" }
    /// 连发间隔：每两下之间隔多久（固件会夹到 60~5000ms）
    static func bootKeyGap(_ ms: Int) -> String { "BOOTKEY:gap \(ms)" }

    // MARK: - 鼠标
    //
    // 固件把鼠标做成同一个 USB HID 接口下的第二个 report（ID 2），
    // 所以插一根线既能打字也能动指针，主机那边是「键盘 + 鼠标」两个 HID 集合。
    //
    // 注意 dx/dy 在 HID 相对报告里是 int8，单条最大 ±127：
    // 走得快的时候这里会自动拆成多条，别指望固件帮你夹（夹了就丢位移）。

    /// 相对位移，单位是主机的像素
    static func mouseMove(_ dx: Int, _ dy: Int) -> String { "MOUSE:move \(dx) \(dy)" }
    /// 滚轮：正数向上，一格约 3
    static func mouseWheel(_ n: Int) -> String { "MOUSE:wheel \(n)" }
    static func mouseDown(_ button: String) -> String { "MOUSE:down \(button)" }
    static func mouseUp(_ button: String) -> String { "MOUSE:up \(button)" }
    /// 由固件自己按下 40ms 再松开（主机轮询 10ms，太快会整个 click 都采不到）
    static func mouseClick(_ button: String) -> String { "MOUSE:click \(button)" }
    /// 松开所有鼠标键
    static let mouseRelease = "MOUSE:release"
}

/// 固件回报的引导键参数，来自 `BOOTCFG:key=delete,win=10000,gap=220,hold=80`
struct BootConfig: Equatable {
    var key: String        // 键名，off = 已关闭
    var windowMs: Int      // 连发时长
    var gapMs: Int         // 连发间隔
    var holdMs: Int        // 单次按下保持（固件固定 80ms，仅供显示）

    var windowSeconds: Double { Double(windowMs) / 1000 }

    /// 一句话概括，卡片底部那行灰字用
    var summary: String {
        let name = key == "off" ? "已关闭" : key.uppercased()
        return "固件当前：\(name) · 时长 \(windowMs / 1000) 秒 · 间隔 \(gapMs)ms · 单次按下 \(holdMs)ms"
    }
}

/// Mac 虚拟键码（kVK_*）→ 协议键名。
/// 这里刻意用固定的 US 布局表（而不是读本机键盘布局）：
/// 被控主机也按 US 布局解释按键，两边一致才不会串字符。
enum KeyMap {
    static let tokens: [Int64: String] = [
        // 字母
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
        12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z",
        // 数字与符号
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
        // 编辑与导航
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
        53: "esc", 114: "insert", 115: "home", 119: "end",
        116: "pageup", 121: "pagedown", 57: "capslock",
        123: "left", 124: "right", 125: "down", 126: "up",
        // Windows 键盘上才有、Mac 键盘上一般没有的那几个
        110: "menu",        // Application / 右键菜单键
        // 功能键（Mac 的 F13 起在 Windows 上也是 F13，靠固件按 usage 0x68 起发）
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16",
        64: "f17", 79: "f18", 80: "f19", 90: "f20",
        // 小键盘
        82: "kp0", 83: "kp1", 84: "kp2", 85: "kp3", 86: "kp4",
        87: "kp5", 88: "kp6", 89: "kp7", 91: "kp8", 92: "kp9",
        65: "kpdot", 67: "kpasterisk", 69: "kpplus", 78: "kpminus",
        75: "kpslash", 76: "kpenter", 81: "kpequals",
    ]

    /// 修饰键：类（左右不分的语义类）→ 默认用哪一侧的 token
    static let modifierClassOfToken: [String: String] = [
        "lshift": "shift", "rshift": "shift",
        "lctrl": "ctrl", "rctrl": "ctrl",
        "lalt": "alt", "ralt": "alt",
        "lcmd": "cmd", "rcmd": "cmd",
        "shift": "shift", "ctrl": "ctrl", "alt": "alt", "cmd": "cmd",
    ]

    /// CGEventFlags 里四个修饰位对应的语义类
    static let modifierClasses = ["shift", "ctrl", "alt", "cmd"]

    /// 修饰键默认发左侧（真实键盘上左右各一个，Windows 只关心有没有按下）
    static func defaultToken(forClass cls: String) -> String {
        switch cls {
        case "shift": return "lshift"
        case "ctrl": return "lctrl"
        case "alt": return "lalt"
        default: return "lcmd"
        }
    }

    /// flagsChanged 事件的 keyCode 就是那个修饰键本身，用它区分左右
    static func modifierToken(keyCode: Int64) -> String? {
        switch keyCode {
        case 56: return "lshift"
        case 60: return "rshift"
        case 59: return "lctrl"
        case 62: return "rctrl"
        case 58: return "lalt"
        case 61: return "ralt"
        case 55: return "lcmd"
        case 54: return "rcmd"
        default: return nil
        }
    }
}

// MARK: - 修饰键镜像

/// 把「系统当前的修饰键状态」翻译成需要发出去的 DOWN/UP。
///
/// 为什么单独抽一个类型：这一段是「Windows 上能不能切输入法」的全部逻辑，
/// 但它本身不碰事件 tap，可以脱离键盘权限单独跑测试。
///
/// 设计要点：
///   · 每次都按 flags 做「全量对齐」，而不是只处理变化的那一个键。
///     这样即使某个 keyUp 丢了，下一个事件就会自动纠正，不会留下卡住的 Ctrl。
///   · 左右修饰键尽可能保留（右 Alt 在部分布局里是 AltGr），但语义类只按
///     「有没有按下」判断，够 Windows 用。
struct ModifierMirror {
    /// 语义类（shift/ctrl/alt/cmd）→ 实际发出去的 token（lshift/rshift…）
    private(set) var tokens: [String: String] = [:]

    var isEmpty: Bool { tokens.isEmpty }

    mutating func reset() { tokens.removeAll() }

    /// 返回 (要松开的 token, 要按下的 token)。先松后按是故意的：
    /// 松开旧键再按新键，主机不会看到「Shift 与 Ctrl 同时瞬间消失」的中间态。
    mutating func sync(flags: CGEventFlags, sideKeyCode: Int64?) -> (release: [String], press: [String]) {
        var want: Set<String> = []
        if flags.contains(.maskShift) { want.insert("shift") }
        if flags.contains(.maskControl) { want.insert("ctrl") }
        if flags.contains(.maskAlternate) { want.insert("alt") }
        if flags.contains(.maskCommand) { want.insert("cmd") }

        var release: [String] = []
        var press: [String] = []

        for cls in KeyMap.modifierClasses where tokens[cls] != nil && !want.contains(cls) {
            if let tok = tokens.removeValue(forKey: cls) {
                release.append(tok)
            }
        }

        for cls in KeyMap.modifierClasses where want.contains(cls) && tokens[cls] == nil {
            var tok = KeyMap.defaultToken(forClass: cls)
            if let kc = sideKeyCode,
               let side = KeyMap.modifierToken(keyCode: kc),
               KeyMap.modifierClassOfToken[side] == cls {
                tok = side
            }
            press.append(tok)
            tokens[cls] = tok
        }

        return (release, press)
    }
}

// MARK: - 屏幕键盘布局

struct KeyDef: Identifiable {
    let id = UUID()
    let label: String
    let token: String
    var isModifier: Bool { ["shift", "ctrl", "alt", "cmd"].contains(token) }
}

enum Layout {
    static let rows: [[KeyDef]] = [
        [k("esc"), k("1"), k("2"), k("3"), k("4"), k("5"), k("6"), k("7"), k("8"), k("9"),
         k("0"), k("-"), k("="), k("⌫", "backspace")],
        [k("tab"), k("q"), k("w"), k("e"), k("r"), k("t"), k("y"), k("u"), k("i"), k("o"),
         k("p"), k("["), k("]"), k("\\")],
        [k("caps"), k("a"), k("s"), k("d"), k("f"), k("g"), k("h"), k("j"), k("k"), k("l"),
         k(";"), k("'"), k("⏎", "enter")],
        [k("⇧", "shift"), k("z"), k("x"), k("c"), k("v"), k("b"), k("n"), k("m"),
         k(","), k("."), k("/"), k("⇧", "shift")],
        [k("ctrl", "ctrl"), k("⌥", "alt"), k("⌘", "cmd"), k("space"), k("⌘", "cmd"),
         k("⌥", "alt"), k("←", "left"), k("↓", "down"), k("↑", "up"), k("→", "right")],
    ]

    static let presets: [(label: String, combo: [String])] = [
        ("复制", ["cmd", "c"]), ("粘贴", ["cmd", "v"]), ("剪切", ["cmd", "x"]),
        ("撤销", ["cmd", "z"]), ("全选", ["cmd", "a"]), ("保存", ["cmd", "s"]),
        ("查找", ["cmd", "f"]), ("新建", ["cmd", "n"]), ("关闭窗口", ["cmd", "w"]),
        ("切换窗口", ["cmd", "tab"]), ("聚焦搜索", ["cmd", "space"]),
        ("区域截图", ["cmd", "shift", "4"]), ("全屏截图", ["cmd", "shift", "3"]),
        ("锁屏", ["ctrl", "cmd", "q"]),
    ]

    /// Windows 上的常用键。注意 cmd（⌘）在 Windows 上就是 Win 键，
    /// 所以 ⌘Space 发过去就是 Win+Space —— 正是 Windows 11 切换输入法的默认热键。
    static let winPresets: [(label: String, combo: [String])] = [
        ("切换输入法", ["win", "space"]),   // Win+Space：输入法/语言切换
        ("中英切换", ["ctrl", "space"]),    // Ctrl+Space：微软拼音中英切换
        ("Shift 中英", ["shift"]),          // 单按一下 Shift：微软拼音默认的中英切换
        ("布局切换", ["ctrl", "shift"]),    // Ctrl+Shift：多个键盘布局之间切换
        ("复制", ["ctrl", "c"]), ("粘贴", ["ctrl", "v"]), ("剪切", ["ctrl", "x"]),
        ("撤销", ["ctrl", "z"]), ("全选", ["ctrl", "a"]), ("保存", ["ctrl", "s"]),
        ("切换窗口", ["alt", "tab"]), ("关闭窗口", ["alt", "f4"]),
        ("任务管理器", ["ctrl", "shift", "esc"]),
        ("显示桌面", ["win", "d"]), ("资源管理器", ["win", "e"]), ("运行", ["win", "r"]),
        ("设置", ["win", "i"]), ("锁定", ["win", "l"]), ("搜索", ["win", "s"]),
        ("截图", ["win", "shift", "s"]), ("表情符号", ["win", "."]),
    ]

    /// BIOS / UEFI 启动键。客户端可以把它写进固件，让板子在上电后自己连发。
    ///
    /// 各家主板的「按 X 进设置」并不统一：技嘉/微星多是 Del，华硕/联想多是 F2，
    /// 品牌整机还可能是 F10 / F12 / Esc，个别工控板是 F1 / F8。
    /// 所以 F1~F12 全给出来，别让人因为一个键不对就以为功能坏了。
    static let biosKeys: [(label: String, token: String)] = [
        ("Del", "delete"), ("Esc", "esc"),
        ("F1", "f1"), ("F2", "f2"), ("F3", "f3"), ("F4", "f4"),
        ("F5", "f5"), ("F6", "f6"), ("F7", "f7"), ("F8", "f8"),
        ("F9", "f9"), ("F10", "f10"), ("F11", "f11"), ("F12", "f12"),
        ("关闭", "off"),
    ]

    private static func k(_ label: String, _ token: String? = nil) -> KeyDef {
        KeyDef(label: label, token: token ?? label)
    }
}
