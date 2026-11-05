//
//  MenuBar.swift
//  菜单栏（状态栏）里的捕获开关。
//
//  为什么需要它：捕获期间本机键盘被整体接管，主窗口里那个「停止捕获」按钮
//  就只能用鼠标去点。窗口一旦被盖住、最小化，或者干脆关掉（关窗口不会退进程），
//  就再没有别的出口了 —— 键盘已经不响应，⌃⇧E 这类快捷键又在被吞的那一侧。
//  菜单栏图标永远浮在最上层，鼠标点得到，等于给捕获留了一个随时可用的退路。
//
//  为什么做成菜单而不是「点一下图标就切换」：点一下直接开捕获太危险，
//  误点一下整块键盘就被吞掉，人会一脸茫然不知道发生了什么。菜单里两步操作，
//  而且打开就能看见当前状态和链路状态。
//
//  已知取舍：捕获期间菜单里的键盘导航（方向键 / Esc / 回车）也会被吞掉 ——
//  CGEventTap 插在会话事件流最前面，事件根本到不了菜单。用鼠标点即可。
//

import AppKit
import SwiftUI

/// 菜单栏上那个图标：平时是键盘，捕获中换成录制圆点。
///
/// 单独做成一个视图，是为了让它自己订阅 `KeyForwarder`：菜单栏项的内容由系统托管，
/// 能不能随状态刷新取决于 SwiftUI 有没有跟踪到依赖。把 `@ObservedObject` 放进
/// 标签视图内部最稳，不用指望 App.body 重新求值时顺带换掉图标。
struct StatusBarLabel: View {
    @ObservedObject var forwarder: KeyForwarder

    var body: some View {
        // 菜单栏图标是模板渲染（系统只取形状、颜色由亮/暗菜单栏决定），
        // 所以状态只能靠「换符号」表达，不能靠换颜色
        Image(systemName: forwarder.isCapturing ? "record.circle" : "keyboard")
    }
}

/// 菜单展开后的内容
struct CaptureMenu: View {
    @ObservedObject var bridge: LinkBridge
    @ObservedObject var forwarder: KeyForwarder

    var body: some View {
        Group {
            // 两行状态：不动手也能一眼看出「链路通没通、现在有没有在吞键盘」
            Text(linkLine)
            Text(captureLine)
            Divider()

            captureItem

            Button("释放全部按键") {
                bridge.send(Command.releaseAll)
                bridge.log("状态栏：已发送 RELEASEALL")
            }
            .disabled(!bridge.state.isConnected)

            // 没授权时把补救入口直接摆出来，省得为了点一下「去授权」还得把窗口找回来
            if !forwarder.trusted {
                Divider()
                Button("去授权（辅助功能）…") { forwarder.openAccessibilitySettings() }
                Button("重新检测权限") { forwarder.refreshTrust(explain: true) }
            }

            Divider()
            Button("显示主窗口") { showMainWindow() }
            Button("退出") { NSApp.terminate(nil) }
        }
        // 每次打开菜单都重查一次权限：可能在别处刚勾上辅助功能，
        // 界面里那份 trusted 还是旧的，这里不刷新就会一直显示「缺权限」
        .onAppear { forwarder.refreshTrust() }
    }

    // MARK: - 菜单项

    @ViewBuilder
    private var captureItem: some View {
        if forwarder.isCapturing {
            Button("停止捕获") {
                forwarder.stop()
                bridge.log("状态栏：已停止捕获")
            }
        } else {
            Button("开始捕获") {
                if forwarder.start() {
                    bridge.log("状态栏：已开始捕获")
                }
            }
            // 没连上就没地方发键；没授权 tap 建不起来。两种情况都不给点，
            // 上面的状态行已经说明了原因
            .disabled(!bridge.state.isConnected || !forwarder.trusted)
        }
    }

    // MARK: - 文案

    private var linkLine: String {
        switch bridge.state {
        case .connected:
            let name = bridge.connectedName.isEmpty ? "链路就绪" : bridge.connectedName
            return "链路：已连接（\(bridge.kind.label)）· \(name)"
        case .scanning, .connecting:
            return "链路：\(bridge.state.title)（\(bridge.kind.label)）"
        case .idle:
            return "链路：未连接"
        default:
            return "链路：\(bridge.state.title)"
        }
    }

    private var captureLine: String {
        if forwarder.isCapturing { return "捕获中：本机按键只发往主机" }
        if !forwarder.trusted { return "捕获：未开启（缺辅助功能权限）" }
        if !bridge.state.isConnected { return "捕获：未开启（先连接板子）" }
        return "捕获：未开启"
    }

    // MARK: - 动作

    /// 把主窗口调回前台。
    ///
    /// 窗口被关掉时 SwiftUI 只是把它隐藏起来，对象还在，`makeKeyAndOrderFront`
    /// 就能把它原样叫回来。不用 `openWindow(id:)` 是因为那会再开一个新窗口 ——
    /// 这个工具本来就不希望有多份窗口。
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
