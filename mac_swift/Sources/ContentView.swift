//
//  ContentView.swift
//  界面。整体用系统材质 + 圆角卡片，跟随浅色/深色模式。
//
//  说明：这里不用 @State / @Environment 等 SwiftUI 宏，改用 ObservableObject
//  手动持有状态。这样只靠 swiftc 就能编译（宏需要 swift-plugin-server，
//  在某些沙箱环境里会失败），工程量差别很小。
//

import AppKit
import Combine
import SwiftUI

/// 被控主机是 Windows 还是 macOS —— 决定「常用快捷键」那一排发什么
enum PresetOS: String, CaseIterable, Identifiable {
    case windows = "Windows"
    case mac = "macOS"
    var id: String { rawValue }
}

/// 界面本地状态
final class UIState: ObservableObject {
    @Published var deviceName = Link.defaultName
    @Published var text = ""
    @Published var sticky: Set<String> = []
    /// 刚被点到的键。用来闪一下高亮，让「点了有反应」这件事看得见
    @Published var flash: Set<String> = []
    /// Wi-Fi 模式下要连的地址：板子热点里 TCP 服务端的 IP 和端口
    @Published var wifiHost = LinkKind.defaultHost
    @Published var wifiPort = String(LinkKind.defaultPort)
    /// 快捷键区当前按哪套系统显示
    @Published var presetOS: PresetOS = .windows
    /// 开机引导键（写进固件的那个）
    @Published var biosKey = "delete"

    // MARK: 鼠标
    /// 当前按着的鼠标键（界面高亮用；真实状态在固件里）
    @Published var mouseHeld: Set<String> = []
    /// 拖拽锁：让主机左键保持按下，用来框选文字 / 拖动文件
    @Published var dragLocked = false
    /// 指针速度倍率：触控板位移 × 这个数才是主机上的像素
    @Published var mouseSpeed: Double = 1.6

    /// 拖拽区的采样点（View 是无状态的，位移基准得存在对象里）
    let padTracker = PadTracker()

    /// 屏幕键盘卡片的实测高度。鼠标卡要和它等高（并排两栏底部才齐），
    /// 多出来的高度由拖拽区吸收，而不是去改按钮行高。
    @Published var boardHeight: CGFloat = 0

    /// 发命令的出口，onAppear 时接到 LinkBridge.send 上。
    /// 位移是高频事件，交给这里攒批，而不是让每个视图自己调 bridge。
    var send: ((String) -> Void)?
    /// 还没发出去的位移（小于 1px 的部分也攒着，别扔）
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var drainTimer: Timer?

    var deviceNameBinding: Binding<String> {
        Binding(get: { self.deviceName }, set: { self.deviceName = $0 })
    }

    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }

    var wifiHostBinding: Binding<String> {
        Binding(get: { self.wifiHost }, set: { self.wifiHost = $0 })
    }

    var wifiPortBinding: Binding<String> {
        Binding(get: { self.wifiPort }, set: { self.wifiPort = $0 })
    }

    var presetOSBinding: Binding<PresetOS> {
        Binding(get: { self.presetOS }, set: { self.presetOS = $0 })
    }

    var biosKeyBinding: Binding<String> {
        Binding(get: { self.biosKey }, set: { self.biosKey = $0 })
    }

    var portValue: UInt16 {
        UInt16(wifiPort.trimmingCharacters(in: .whitespaces)) ?? LinkKind.defaultPort
    }

    var mouseSpeedBinding: Binding<Double> {
        Binding(get: { self.mouseSpeed }, set: { self.mouseSpeed = $0 })
    }

    // MARK: - 鼠标

    /// 触控板位移入口：先攒、再按 30Hz 批量发。
    ///
    /// 为什么要攒：BLE 一次只写 20 字节，60Hz 的高频位移会把连接间隔塞满，
    /// 手感反而变粘；攒 33ms 一次既够跟手，也顺手把超过 ±127 的位移拆成多条
    /// （HID 相对报告的 dx/dy 是 int8，单条超了会被固件夹住，等于丢位移）。
    func padMove(dx: Double, dy: Double) {
        pendingX += dx * mouseSpeed
        pendingY += dy * mouseSpeed
        guard drainTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.drainPad()
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func drainPad() {
        var x = Int(pendingX)
        var y = Int(pendingY)
        pendingX -= Double(x)
        pendingY -= Double(y)

        while x != 0 || y != 0 {
            let stepX = max(-127, min(127, x))
            let stepY = max(-127, min(127, y))
            send?(Command.mouseMove(stepX, stepY))
            x -= stepX
            y -= stepY
        }

        // 没有待发位移了就停表，别让界面空转
        if abs(pendingX) < 0.5 && abs(pendingY) < 0.5 {
            drainTimer?.invalidate()
            drainTimer = nil
        }
    }

    func pressMouse(_ name: String) {
        guard !mouseHeld.contains(name) else { return }
        mouseHeld.insert(name)
        send?(Command.mouseDown(name))
    }

    func releaseMouse(_ name: String) {
        guard mouseHeld.remove(name) != nil else { return }
        send?(Command.mouseUp(name))
    }

    func toggleDragLock() {
        dragLocked.toggle()
        send?(dragLocked ? Command.mouseDown("left") : Command.mouseUp("left"))
    }

    func wheel(_ steps: Int) {
        send?(Command.mouseWheel(steps))
    }

    /// 停捕获 / 掉线时把本地鼠标状态清干净（固件那边也会自己全松一次）
    func resetMouse() {
        dragLocked = false
        mouseHeld.removeAll()
        pendingX = 0
        pendingY = 0
        drainTimer?.invalidate()
        drainTimer = nil
    }
}

struct ContentView: View {
    @EnvironmentObject private var bridge: LinkBridge
    @EnvironmentObject private var forwarder: KeyForwarder
    @StateObject private var ui = UIState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 12) {
                    if bridge.kind == .wifi { wifiCard }
                    captureCard
                    bootCard
                    textCard
                    presetsCard
                    // 屏幕键盘和鼠标并排：键盘在左（宽度自适应，键位多、需要横向空间），
                    // 鼠标在右（固定列宽 —— 窄列里拖拽区在上、按键在下的纵向排布更顺手）。
                    // 高度以键盘卡为准，鼠标卡跟它齐平（两栏底部对齐，看着才整齐）。
                    HStack(alignment: .top, spacing: 12) {
                        keyboardCard
                            .background(
                                GeometryReader { g in
                                    Color.clear
                                        .onAppear { ui.boardHeight = g.size.height }
                                        .onChange(of: g.size.height) { _, h in ui.boardHeight = h }
                                }
                            )
                        mouseCard
                            .frame(width: 320)
                            // 200 是「量到之前」的兜底：没量到就让卡片按内容自然高度长
                            .frame(height: ui.boardHeight > 200 ? ui.boardHeight : nil,
                                   alignment: .top)
                    }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            logBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let bridgeRef = bridge
            let fwd = forwarder
            let uiRef = ui
            fwd.onCommand = { [weak bridgeRef] line in bridgeRef?.send(line) }
            fwd.onLog = { [weak bridgeRef] text in bridgeRef?.log(text) }
            uiRef.send = { [weak bridgeRef] line in bridgeRef?.send(line) }
            fwd.refreshTrust()
            bridgeRef.onDisconnect = { [weak fwd, weak uiRef] in
                fwd?.stop()
                uiRef?.sticky.removeAll()
                uiRef?.resetMouse()
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 11) {
                statusBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(bridge.state.isBusy ? Color.orange : Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if !statusDetail.isEmpty {
                        Text(statusDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 14)

                // 链路模式：必须和板子上 BOOT 键选的一致（灯色可以对照）
                Picker("", selection: Binding(get: { bridge.kind }, set: { bridge.kind = $0 })) {
                    ForEach(LinkKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .disabled(bridge.state.isBusy || bridge.state.isConnected)
                .help(bridge.kind == .ble
                      ? "蓝牙链路：按设备名扫描并连接"
                      : "Wi-Fi 链路：连到板子热点的 IP:端口")

                addressFields

                connectControls

                Button {
                    bridge.send(Command.ping)
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .frame(width: 16)
                }
                .buttonStyle(.bordered)
                .help("PING：测试链路是否有回执")
                .disabled(!bridge.state.isConnected)
            }

            // 只在扫描/连接时显示的细进度条。固定 3pt 高度，
            // 不显示时也不占位变化，避免顶栏高度跳动。
            busyBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    /// 左侧状态点：空闲是彩色圆点，扫描/连接时换成转圈，给「正在做事」的反馈
    @ViewBuilder
    private var statusBadge: some View {
        if bridge.state.isBusy {
            SpinningArc()
                .help("正在进行中，可以点「停止」中止")
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.06)))
        }
    }

    /// 主操作按钮：空闲「连接」/ 进行中「停止」/ 已连接「断开」，任何时候都能点
    @ViewBuilder
    private var connectControls: some View {
        if bridge.state.isBusy {
            Button {
                forwarder.stop()
                bridge.cancel()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .black))
                    Text("停止")
                }
                .frame(minWidth: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("立即停止扫描/连接，不用等超时")
        } else if bridge.state.isConnected {
            Button {
                forwarder.stop()
                bridge.disconnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("断开")
                }
                .frame(minWidth: 58)
            }
            .buttonStyle(.bordered)
            .help("断开当前连接")
        } else {
            Button {
                bridge.connect(kind: bridge.kind,
                               name: ui.deviceName,
                               host: ui.wifiHost,
                               port: ui.portValue)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: bridge.kind == .ble ? "link" : "wifi")
                        .font(.system(size: 10, weight: .bold))
                    Text("连接")
                }
                .frame(minWidth: 58)
            }
            .buttonStyle(.borderedProminent)
            .help(bridge.kind == .ble
                  ? "按设备名扫描并连接（最长 12 秒）"
                  : "连到 \(ui.wifiHost):\(ui.wifiPort)（最长 6 秒）")
        }
    }

    /// 顶栏里随模式变化的地址输入：蓝牙填设备名，Wi-Fi 填 IP + 端口
    @ViewBuilder
    private var addressFields: some View {
        let locked = bridge.state.isBusy || bridge.state.isConnected
        if bridge.kind == .ble {
            TextField("设备名", text: ui.deviceNameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 148)
                .disabled(locked)
                .help("固件里 DEVICE_NAME 的名字，默认 \(Link.defaultName)")
        } else {
            HStack(spacing: 5) {
                TextField("IP", text: ui.wifiHostBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 108)
                    .disabled(locked)
                TextField("端口", text: ui.wifiPortBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .disabled(locked)
            }
            .help("板子热点里 TCP 服务端的地址，默认 \(LinkKind.defaultHost):\(LinkKind.defaultPort)")
        }
    }

    /// 阶段剩余时间进度条，只有忙的时候才有内容。
    /// 自己用 Capsule 画而不用 ProgressView：高度可控（3pt），
    /// 也不会因为系统控件的默认内边距把顶栏撑高。
    private var busyBar: some View {
        let total = max(1, bridge.phaseSeconds)
        let done = min(max(Double(total - bridge.remainingSeconds) / Double(total), 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.orange)
                    .frame(width: geo.size.width * done)
            }
        }
        .frame(height: 3)
        .opacity(bridge.state.isBusy ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: bridge.state.isBusy)
    }

    private var statusColor: Color {
        switch bridge.state {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .idle: return Color.secondary
        default: return .red
        }
    }

    private var statusTitle: String {
        if forwarder.isCapturing { return "正在把本机键盘转发到主机" }
        return bridge.state.title
    }

    /// 状态点右侧的一行小字，说明现在卡在哪一步、下一步该做什么
    private var statusDetail: String {
        if forwarder.isCapturing { return "⌃⌥Esc 随时停止捕获" }

        if bridge.state.isBusy {
            let phase: String
            if bridge.kind == .wifi {
                phase = "正在连接 \(ui.wifiHost):\(ui.wifiPort)"
            } else if bridge.state == .scanning {
                phase = "正在搜索 “\(bridge.targetDeviceName)”"
            } else {
                phase = "已发现设备，正在建立连接"
            }
            if bridge.remainingSeconds > 0 {
                return "\(phase) · 还剩 \(bridge.remainingSeconds) 秒，可随时停止"
            }
            return phase
        }

        if bridge.state.isConnected {
            return bridge.connectedName.isEmpty ? "链路就绪" : bridge.connectedName
        }

        switch bridge.state {
        case .bluetoothOff: return "打开蓝牙后会自动继续"
        case .unauthorized: return "系统设置 → 隐私与安全性 → 蓝牙"
        case .failed:
            return bridge.kind == .wifi
                ? "先连上热点 \(LinkKind.defaultHotspot)，再按 IP 连接"
                : "确认板子已上电、设备名一致后重试"
        default:
            return bridge.kind == .wifi
                ? "连上热点后点「连接」，默认 \(LinkKind.defaultHost):\(LinkKind.defaultPort)"
                : "点「连接」按设备名搜索"
        }
    }

    // MARK: - Wi-Fi 直连说明

    /// 客户端没法替用户加入别人的 Wi-Fi（需要管理员权限），所以这里把
    /// 热点名/密码摆出来，一键复制，剩下让用户在系统 Wi-Fi 里点一下。
    private var wifiCard: some View {
        Card(title: "Wi-Fi 直连", icon: "wifi") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("① 笔记本先连热点")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    Text(LinkKind.defaultHotspot)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    copyButton(LinkKind.defaultHotspot, hint: "复制热点名")
                    Text("密码")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    Text(LinkKind.defaultPassword)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    copyButton(LinkKind.defaultPassword, hint: "复制密码")
                    Spacer(minLength: 8)
                    Button("打开 Wi-Fi 设置") { openWiFiSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }

                HStack(spacing: 6) {
                    Text("② 再按 IP 连板子")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    Text("\(LinkKind.defaultHost):\(LinkKind.defaultPort)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Button("填入地址") {
                        ui.wifiHost = LinkKind.defaultHost
                        ui.wifiPort = String(LinkKind.defaultPort)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    Spacer(minLength: 8)
                    Text("板子 BOOT 键短按切换链路：灯绿 = Wi-Fi 待连，灯黄 = 已连上")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func copyButton(_ value: String, hint: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help(hint)
    }

    private func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 键盘捕获

    /// 压成一条工具栏式横条：标题 + 权限胶囊 + 操作按钮占同一行，
    /// 只有出错时才多出一行提示，平时高度约 38pt。
    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("本机键盘转发", systemImage: "keyboard.badge.ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)

                Spacer(minLength: 8)

                permissionChip

                if !forwarder.trusted {
                    Button("去授权") { forwarder.openAccessibilitySettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                    Button("重新检测") { forwarder.refreshTrust(explain: true) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                    Button {
                        forwarder.resetAccessibility()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help("已勾选但一直显示未授权时点这里。会清掉失效的旧授权记录，然后需要重新添加本 App（ad-hoc 签名每次重新编译指纹都会变）")
                }

                captureButton
            }

            if let notice = forwarder.notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .help("开启捕获后，在这台 Mac 上敲的键会发给被控主机，本机不再响应。按 ⌃⌥Esc 随时停止。")
    }

    private var captureButton: some View {
        Group {
            if forwarder.isCapturing {
                Button("停止捕获") {
                    forwarder.stop()
                    ui.sticky.removeAll()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("也可以用 ⌃⌥Esc 紧急停止")
            } else {
                Button("开始捕获") {
                    _ = forwarder.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bridge.state.isConnected)
            }
        }
        .controlSize(.small)
    }

    /// 权限状态压成一个胶囊，取代原来那一整行说明
    private var permissionChip: some View {
        let ok = forwarder.trusted
        return HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(ok ? "辅助功能已授权" : "需辅助功能权限")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(ok ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.12)))
        .help(ok ? "已获得键盘接管权限" : "系统设置 → 隐私与安全性 → 辅助功能，勾选本 App")
    }

    // MARK: - BIOS 启动键

    /// 主机开机自检时链路还没连上，客户端发不出任何按键，
    /// 所以让固件自己在 USB 枚举完成后连发这个键，覆盖整个 POST 窗口。
    private var bootCard: some View {
        Card(title: "BIOS 启动键（板子自己连发，不依赖连接）", icon: "power") {
            VStack(alignment: .leading, spacing: 8) {
                // 分段控件独占一行，且**不要写死宽度**：
                // NSSegmentedControl 不会压缩段内文字，宽度不够时它按自然宽度排版、
                // 左右均摊溢出，于是首段顶出卡片边界、相邻段互相叠在一起。
                // 8 段（Del/F2/F10/F12/F1/F8/Esc/关闭）实测自然宽 400pt，
                // 窗口最窄 840（内容区 786）时余量约 370pt，不会再挤。
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: ui.biosKeyBinding) {
                        ForEach(Layout.biosKeys, id: \.token) { item in
                            Text(item.label).tag(item.token)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("写入固件") {
                            bridge.send(Command.bootKey(ui.biosKey))
                        }
                        .buttonStyle(.bordered)
                        .help("写进板子的 NVS，掉电保持；以后每次上电都会连发这个键")

                        Button("立即连发") {
                            bridge.send(Command.bootKeyNow)
                        }
                        .buttonStyle(.bordered)
                        .help("让板子马上再连发一轮（已经开着机、想再敲一次时用）")

                        Button("查询当前设置") {
                            bridge.send(Command.bootKeyQuery)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))

                        Spacer(minLength: 0)
                    }
                }
                .disabled(!bridge.state.isConnected)

                Text("上电后约 1.5 秒开始，每 220ms 敲一次，持续 15 秒（单次按下 80ms，照顾 UEFI 的慢轮询）。写一次就一直有效，不用每次开机都开客户端。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 文字

    private var textCard: some View {
        Card(title: "文字", icon: "text.cursor") {
            HStack(spacing: 8) {
                TextField("要输入的文字", text: ui.textBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendText(enter: true) }
                Button("输入") { sendText(enter: false) }
                    .buttonStyle(.bordered)
                Button("输入 + 回车") { sendText(enter: true) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func sendText(enter: Bool) {
        if !ui.text.isEmpty {
            bridge.send(Command.type(ui.text))
        } else if !enter {
            return
        }
        if enter { bridge.tapKey("enter") }
        ui.text = ""
    }

    // MARK: - 快捷键

    private var presetsCard: some View {
        Card(title: "常用快捷键", icon: "command") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Picker("", selection: ui.presetOSBinding) {
                        ForEach(PresetOS.allCases) { os in
                            Text(os.rawValue).tag(os)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // 别写死宽度：实测 2 段「Windows / macOS」的自然宽是 158pt，
                    // 给 150 会把控件压扁、双向溢出 4pt，文字贴到分隔线上。
                    .fixedSize()

                    Text(ui.presetOS == .windows
                         ? "⌘ 就是 Win 键：⌘Space = Win+Space（切输入法）"
                         : "⌘ 是 Command，发到主机上就是 Win 键")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7),
                          spacing: 7) {
                    ForEach(currentPresets, id: \.label) { item in
                        Button {
                            releaseSticky()
                            bridge.send(Command.combo(item.combo))
                        } label: {
                            // 宽度要加在 label 上，否则 bordered 样式的底色会跟着文字长短变化
                            Text(item.label).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var currentPresets: [(label: String, combo: [String])] {
        ui.presetOS == .windows ? Layout.winPresets : Layout.presets
    }

    // MARK: - 鼠标

    /// 鼠标卡片。竖着排：上面一大块拖拽区负责「移动」，下面是按键 / 滚轮 / 速度。
    ///
    /// 为什么拖拽区只管移动、按键单独放：这台 Mac 只有一只鼠标，
    /// 「按住左边按钮不放、同时去拖拖拽区」物理上做不到。
    /// 所以要框选/拖文件，用下面的「按住左键」把主机左键锁住，再拖拖拽区。
    private var mouseCard: some View {
        Card(title: "鼠标（拖动 = 移动指针）", icon: "computermouse", fillHeight: true) {
            VStack(spacing: 7) {
                // 拖拽区：底图 / 描边 / 提示文字都设成不吃事件，
                // 事件只留给人手势那一层，免得点了没反应
                MousePadView(tracker: ui.padTracker) { dx, dy in
                    ui.padMove(dx: dx, dy: dy)
                }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                        .allowsHitTesting(false)
                )
                .overlay(
                    VStack(spacing: 3) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 15))
                        Text("按住拖动，指针跟着走")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(Color.secondary)
                    .allowsHitTesting(false)
                )
                .frame(minHeight: 84, maxHeight: .infinity)
                .help("拖到边缘后松手、把手移回中间再拖一段；速度滑块可以放大倍数")

                HStack(spacing: 6) {
                    mouseKey("左键", "left")
                    mouseKey("中键", "middle")
                    mouseKey("右键", "right")
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    wheelKey("滚轮 ↑", 3)
                    wheelKey("滚轮 ↓", -3)
                    dragLockKey
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 7) {
                    Text("速度")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                    Slider(value: ui.mouseSpeedBinding, in: 0.5...4, step: 0.1)
                        .controlSize(.mini)
                    Text(String(format: "%.1f×", ui.mouseSpeed))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 鼠标键：按下就发 DOWN，松手发 UP。
    /// 这里必须自己接鼠标事件（PressCatcher），SwiftUI 的 Button 只有 click，
    /// 拆不出「按住」这一段，而右键菜单、拖拽都靠它。
    private func mouseKey(_ label: String, _ name: String) -> some View {
        let held = ui.mouseHeld.contains(name)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(held ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(held ? 0 : 0.12))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(held ? Color.white : Color.primary)
                .allowsHitTesting(false)
            PressCatcher(onPress: { ui.pressMouse(name) },
                         onRelease: { ui.releaseMouse(name) })
        }
        .frame(height: 26)
        .help("按住不松 = 主机上一直按着；快速点一下 = 单击")
    }

    private func wheelKey(_ label: String, _ steps: Int) -> some View {
        Button {
            ui.wheel(steps)
        } label: {
            Text(label)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("点一次滚 \(steps > 0 ? "上" : "下") 3 格")
    }

    /// 「按住左键」锁：主机左键保持按下，配合拖拽区就能框选 / 拖文件。
    /// 用锁而不是「按住」是物理限制——一只手没法同时按住按钮和拖拖拽区。
    @ViewBuilder
    private var dragLockKey: some View {
        if ui.dragLocked {
            Button {
                ui.toggleDragLock()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text("松开左键").font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .help("主机左键正被按住，拖拖拽区就是拖拽；点这里松开")
        } else {
            Button {
                ui.toggleDragLock()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "lock.open").font(.system(size: 9))
                    Text("按住左键").font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("按住主机左键不放，配合拖拽区做框选 / 拖文件")
        }
    }

    // MARK: - 屏幕键盘

    private var keyboardCard: some View {
        Card(title: "屏幕键盘（⇧ ⌥ ⌘ ctrl 为粘滞键）", icon: "keyboard") {
            VStack(spacing: 6) {
                ForEach(Array(Layout.rows.enumerated()), id: \.offset) { item in
                    HStack(spacing: 5) {
                        ForEach(item.element) { key in
                            keyButton(key)
                        }
                    }
                }
            }
        }
    }

    private func keyButton(_ key: KeyDef) -> some View {
        let active = ui.sticky.contains(key.token) || ui.flash.contains(key.token)
        return Button {
            press(key.token)
        } label: {
            Text(key.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 30)
                // 关键：`.frame` 只改变布局尺寸，不会扩大 SwiftUI 的点击判定区域。
                // 少了这一行，只有文字笔画那几个像素能点中，键格其余部分全是「死区」——
                // 表现就是「屏幕键盘点了没反应」。contentShape 把整格都变成可点区域。
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(active ? 0 : 0.12))
        )
        .foregroundStyle(active ? Color.white : Color.primary)
    }

    private func press(_ token: String) {
        flashKey(token)

        if ["shift", "ctrl", "alt", "cmd"].contains(token) {
            if ui.sticky.contains(token) {
                ui.sticky.remove(token)
                bridge.send(Command.up(token))
            } else {
                ui.sticky.insert(token)
                bridge.send(Command.down(token))
            }
            return
        }

        // 普通键走 DOWN → 30ms → UP 两段，和「本机键盘转发」是同一条路径。
        // 以前这里发的是 TAP:，由固件自己按下再延时松开；两条路各走各的，
        // 就出现了「捕获能打出字母、屏幕键盘点了没反应」这种一半好一半坏的情况。
        bridge.tapKey(token)
        // 粘滞的修饰键要等这一下敲完再松，否则「⇧ + a」会先松开 Shift 变成小写
        releaseSticky(after: 0.05)
    }

    /// 点一下闪 120ms 高亮。未连接时命令发不出去，如果没有这个反馈，
    /// 界面看上去就像完全没响应。
    private func flashKey(_ token: String) {
        ui.flash.insert(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak ui] in
            ui?.flash.remove(token)
        }
    }

    private func releaseSticky(after delay: TimeInterval = 0) {
        let uiRef = ui
        let link = bridge
        let work = {
            for mod in uiRef.sticky {
                link.send(Command.up(mod))
            }
            uiRef.sticky.removeAll()
        }
        if delay <= 0 {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - 日志

    private var logBar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bridge.logs.suffix(120)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.timeFormatter.string(from: entry.time))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                            Text(entry.text)
                                .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(height: 86)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            .onChange(of: bridge.logs.count) { _, _ in
                if let last = bridge.logs.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 小转圈

/// 扫描/连接时状态点位置上的转圈。这里用 TimelineView 按时间算角度，
/// 既不用 @State（本项目的编译环境里 SwiftUI 宏不可靠），
/// 也比 ProgressView 尺寸/颜色更可控。
struct SpinningArc: View {
    var body: some View {
        TimelineView(.animation) { context in
            let period = 0.9
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .foregroundStyle(Color.orange)
                .rotationEffect(.degrees(phase * 360))
        }
        .frame(width: 11, height: 11)
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    let title: String
    let icon: String
    /// true 时卡片会撑满父视图给的高度（并排等高就差这个），多出来的空间交给内容里的可伸缩视图
    let fillHeight: Bool
    let content: Content

    init(title: String, icon: String, fillHeight: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.fillHeight = fillHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity,
               maxHeight: fillHeight ? .infinity : nil,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}
