//
//  KeyForwarder.swift
//  用 CGEventTap 接管 Mac 本机键盘，把按键翻译成协议命令。
//
//  为什么必须用 CGEventTap 而不是 NSEvent 监听：
//    全局监听只能「观察」不能「吞掉」，按键仍会打进本机；只有事件 tap 返回 nil
//    才能真正拦截，这样 Mac 上敲的键就只发到被控主机去了。
//
//  需要的权限：系统设置 → 隐私与安全性 → 辅助功能（Accessibility）。
//

import AppKit
import Combine
import CoreGraphics

final class KeyForwarder: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var notice: String?

    /// 每翻译出一个按键就回调一条协议命令
    var onCommand: ((String) -> Void)?
    /// 过程性信息写日志，不占用界面上的提示位
    var onLog: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 已经提示过的未映射键码，避免每按一次都刷一条日志
    private var warnedCodes: Set<Int64> = []
    /// 修饰键镜像状态：决定了什么时候发 DOWN:lshift / UP:lctrl
    private var mirror = ModifierMirror()
    /// 当前按住不放的普通键（避免重复 DOWN，也方便兜底释放）
    private var heldKeys: Set<Int64> = []

    // MARK: - 权限

    func refreshTrust(prompt: Bool = false, explain: Bool = false) {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }

        // 用户主动点「重新检测」却没变绿时，直接告诉他最可能的原因，
        // 否则界面只会静静地继续显示「未授权」，让人以为按钮坏了。
        guard explain else { return }
        if trusted {
            notice = nil
        } else {
            notice = "系统仍判定未授权。若设置里已经勾选，是重新编译后签名变了：点右边圆形箭头重置，再重新添加本 App"
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 清掉本 App 在 TCC 里的辅助功能记录，然后重新申请。
    ///
    /// 为什么需要它：本项目用 ad-hoc 签名（没有开发者证书），TCC 是按「代码签名
    /// 指纹」认人的，每次重新编译 cdhash 都会变。于是会出现一种坑人的状态——
    /// 系统设置里那条开关仍是勾选的，但系统认为「这不是同一个程序」，
    /// AXIsProcessTrusted() 一直返回 false，点「重新检测」永远不会变绿。
    /// 只有把旧记录删掉、让系统重新记一次才行，这个按钮就是干这件事。
    func resetAccessibility() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            notice = "取不到 Bundle ID，无法重置"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", bundleID]
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                notice = "已清除旧授权记录。接下来点「去授权」，把本 App 重新加进去（旧条目已失效）"
                onLog?("已重置 Accessibility 授权：\(bundleID)")
            } else {
                notice = "重置失败（tccutil 退出码 \(proc.terminationStatus)）"
                onLog?("tccutil reset 失败，退出码 \(proc.terminationStatus)")
            }
        } catch {
            notice = "重置失败：\(error.localizedDescription)"
        }
        refreshTrust()
    }

    // MARK: - 启停

    @discardableResult
    func start() -> Bool {
        if isCapturing { return true }

        refreshTrust()
        guard trusted else {
            notice = "需要辅助功能权限：点「去授权」把本 App 加进去。如果那里已经勾选了却仍显示未授权，点重置按钮"
            refreshTrust(prompt: true)
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            notice = "创建键盘监听失败，多半是权限还没生效：关掉再打开辅助功能开关"
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        // 开始接管前先把主机上的按键状态清零：上一次异常退出可能在主机上
        // 留下了按住的修饰键（表现为「点什么都变快捷键」）。
        mirror.reset()
        heldKeys.removeAll()
        onCommand?(Command.releaseAll)
        isCapturing = true
        notice = nil
        return true
    }

    func stop() {
        guard isCapturing else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.tap = nil
        self.source = nil
        isCapturing = false
        warnedCodes.removeAll()
        // 停止/断链时把「还按着的键」全松开，否则主机上会留一个卡住的修饰键
        // （典型现象：主机一直以为 Ctrl 按着，点什么都是快捷键）
        if !mirror.isEmpty || !heldKeys.isEmpty {
            onCommand?(Command.releaseAll)
            mirror.reset()
            heldKeys.removeAll()
        }
    }

    // MARK: - 事件处理（主线程）

    /// 按当前 flags 校正修饰键状态，让固件那边和本机键盘保持一致。
    ///
    /// 这是「Windows 上能切换输入法」的关键：以前修饰键变化直接吞掉，
    /// 只在普通键上拼 COMBO，于是 Ctrl+Shift（两个都是修饰键）、单按 Shift、
    /// 先按 Win 再按 Space 这类操作根本发不出去。现在改成镜像：
    /// 修饰键单独 DOWN/UP，普通键也单独 DOWN/UP，主机看到的就是一把真键盘。
    private func syncModifiers(flags: CGEventFlags, sideKeyCode: Int64?) {
        let changes = mirror.sync(flags: flags, sideKeyCode: sideKeyCode)
        for token in changes.release {
            onCommand?(Command.up(token))
        }
        for token in changes.press {
            onCommand?(Command.down(token))
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统可能因为回调超时把 tap 关掉，这里原地重新打开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 被关掉期间的事件收不到，主机上可能留着按住的键
            onCommand?(Command.releaseAll)
            mirror.reset()
            heldKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isCapturing else { return Unmanaged.passUnretained(event) }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            // Fn 键不在我们的表里，直接忽略
            if code != 63 {
                syncModifiers(flags: event.flags, sideKeyCode: code)
            }
            return nil

        case .keyDown:
            // 紧急出口：⌃⌥Esc 停止捕获。判断要放在同步之前，
            // 免得多发出一对 ctrl/alt。
            if code == 53,
               event.flags.contains(.maskControl),
               event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stop()
                    self.onLog?("已停止捕获（⌃⌥Esc）")
                }
                return nil
            }

            syncModifiers(flags: event.flags, sideKeyCode: nil)

            // 长按自动重复交给主机自己处理：键一直按着，Windows 会自己连发。
            // 如果把重复事件也转发，等于每个重复都重新按下一次，输入法会乱。
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }

            guard let token = KeyMap.tokens[code] else {
                if !warnedCodes.contains(code) {
                    warnedCodes.insert(code)
                    let msg = "跳过未映射的键（keyCode \(code)），它不在当前键表里"
                    DispatchQueue.main.async { [weak self] in self?.onLog?(msg) }
                }
                return nil
            }
            if heldKeys.insert(code).inserted {
                onCommand?(Command.down(token))
            }
            return nil

        case .keyUp:
            syncModifiers(flags: event.flags, sideKeyCode: nil)
            if heldKeys.remove(code) != nil, let token = KeyMap.tokens[code] {
                onCommand?(Command.up(token))
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// C 函数指针入口，不能捕获上下文，所以通过 refcon 拿回实例
private func keyTapCallback(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let forwarder = Unmanaged<KeyForwarder>.fromOpaque(refcon).takeUnretainedValue()
    return forwarder.handle(type: type, event: event)
}
