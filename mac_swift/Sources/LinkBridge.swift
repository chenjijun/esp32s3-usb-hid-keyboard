//
//  LinkBridge.swift
//  两种链路二选一（和固件的 BOOT 键切换对应）：
//    · 蓝牙  BLE 中心设备：扫描 → 连接 → 写特征
//    · Wi-Fi TCP：连到板子热点的 192.168.4.1:8266
//
//  两种链路对上层是同一套接口：state / send() / cancel() / disconnect()，
//  文本协议完全一致，所以界面和键盘转发完全不关心当前走的是哪条链路。
//
//  注意：所有回调都在主队列，这样 @Published 更新不会跨线程，也不需要额外加锁。
//
//  超时策略（见文件底部的 Timing，可自行调整）：
//    · BLE：扫描 N 秒没发现设备 → 停止扫描，状态变「没找到设备」
//    · BLE：建立连接 / 服务发现各自有超时，超时后取消并最多自动重试 2 次
//    · Wi-Fi：TCP 握手有超时，失败同样自动重试
//    · 任何阶段界面都能点「停止」立刻中止，不会卡在无限扫描
//

import Combine
import CoreBluetooth
import Foundation
import Network

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    var isError = false
}

enum LinkState: Equatable {
    case idle
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未连接"
        case .bluetoothOff: return "蓝牙已关闭"
        case .unauthorized: return "蓝牙权限被拒绝"
        case .scanning: return "扫描中…"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed(let msg): return msg
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting: return true
        default: return false
        }
    }
}

/// 链路类型：和固件的 BOOT 键切换对应，两边必须选一样的
enum LinkKind: String, CaseIterable, Identifiable {
    case ble
    case wifi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ble: return "蓝牙"
        case .wifi: return "Wi-Fi"
        }
    }

    /// 固件默认开的热点与端口，和对端 #define 保持一致
    static let defaultHotspot = "ESP32-Keyboard"
    static let defaultPassword = "esp32keyboard"
    static let defaultHost = "192.168.4.1"
    static let defaultPort: UInt16 = 8266
}

final class LinkBridge: NSObject, ObservableObject {
    /// 用户选的链路（只在未连接时允许切换）
    @Published var kind: LinkKind = .ble
    @Published private(set) var state: LinkState = .idle
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var connectedName: String = ""
    /// 当前阶段距离超时还剩几秒，0 表示没有在倒计时
    @Published private(set) var remainingSeconds: Int = 0
    /// 当前阶段的总秒数，配合 remainingSeconds 画进度条
    @Published private(set) var phaseSeconds: Int = 0
    /// 正在找的设备名（界面提示用）
    @Published private(set) var targetDeviceName: String = Link.defaultName
    /// 固件回报的引导键参数（BOOTCFG: 那一行）。nil 表示还没查过 / 固件太老不认这条
    @Published private(set) var bootConfig: BootConfig?
    /// 这次连接里固件有没有回过 BOOTKEY:（用来区分「旧固件」和「完全没响应」）
    private var sawBootKeyReply = false

    /// 断开时回调（界面据此关闭键盘捕获，避免按键发进黑洞）
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var pending: [Data] = []
    /// 「未连接，按键被丢弃」这条提示上次写日志的时间（节流用）
    private var lastDropLog = Date.distantPast
    /// 屏幕键盘上一次 tap 结束（松开）的时间点，用来串行化连续点击
    private var tapBusyUntil = Date.distantPast
    private var wantConnection = false
    private var targetName = Link.defaultName

    // Wi-Fi（TCP）链路的状态
    private var nw: NWConnection?
    private var wifiRxBuffer = ""
    private var wifiTarget = ""
    private var wifiHost = LinkKind.defaultHost
    private var wifiPort = LinkKind.defaultPort

    private var retryCount = 0
    private var scanTimeoutWork: DispatchWorkItem?
    private var stageTimeoutWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var countdownTimer: Timer?
    private var countdownEnd: Date?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 对外接口

    /// 按当前链路类型连接。BLE 用设备名，Wi-Fi 用热点里的 IP:端口。
    func connect(kind: LinkKind, name: String, host: String, port: UInt16) {
        self.kind = kind
        retryCount = 0
        cancelPendingWork()

        if kind == .wifi {
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            wifiHost = trimmedHost.isEmpty ? LinkKind.defaultHost : trimmedHost
            wifiPort = port
            wantConnection = true
            startWiFi()
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        targetName = trimmed.isEmpty ? Link.defaultName : trimmed
        targetDeviceName = targetName
        wantConnection = true

        guard central.state == .poweredOn else {
            switch central.state {
            case .unauthorized: state = .unauthorized
            case .poweredOff: state = .bluetoothOff
            case .unsupported: state = .failed("这台机器不支持蓝牙")
            default:
                // .unknown / .resetting：蓝牙栈还在启动（首次约 1~3 秒）。
                // 立刻给出可见反馈，等 poweredOn 回调再真正开始扫描。
                state = .scanning
                log("等待蓝牙就绪…")
            }
            return
        }
        if let p = peripheral, p.state == .connected { return }
        startScan()
    }

    /// 中止正在进行的扫描或连接（界面上的「停止」）
    func cancel() {
        wantConnection = false
        retryCount = 0
        cancelPendingWork()
        stopCountdown()
        central.stopScan()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        teardownLink()
        teardownWiFi()
        state = .idle
        log("已取消")
    }

    func disconnect() {
        wantConnection = false
        retryCount = 0
        cancelPendingWork()
        stopCountdown()
        central.stopScan()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        teardownLink()
        teardownWiFi()
        state = .idle
        log("已断开")
    }

    /// 屏幕键盘按键：按下 → 30ms → 松开。
    ///
    /// 为什么不用固件的 `TAP:` 而是自己分成两条 DOWN/UP：
    /// 这条路径和「本机键盘转发」是**完全同一条**，主机收到的报告序列一模一样，
    /// 不会出现「捕获能用、屏幕键盘点了没反应」这种一处行一处不行的情况。
    /// 30ms 也足够跨过 USB 的 10ms 轮询周期，UEFI 的慢轮询同样能采到。
    func tapKey(_ token: String) {
        guard state.isConnected else {
            noteDropped()
            return
        }
        // 串行化：上一次还没松完（30ms 内又点了一下）就把这一下排到后面，
        // 否则两个 DOWN 会挤在一个「按住」里，快速连点会丢字。
        let now = Date()
        let start = max(now, tapBusyUntil)
        let downDelay = start.timeIntervalSince(now)
        let upDelay = downDelay + 0.03
        // +5ms：让下一次的 DOWN 明确排在上一次的 UP 之后，
        // 免得两个 asyncAfter 落在同一时刻、谁先谁后靠运气
        tapBusyUntil = now.addingTimeInterval(upDelay + 0.005)

        let down = Command.down(token)
        let up = Command.up(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + downDelay) { [weak self] in
            self?.send(down)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + upDelay) { [weak self] in
            self?.send(up)
        }
    }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)

        if kind == .wifi {
            guard let conn = nw, state.isConnected else {
                noteDropped()
                return
            }
            conn.send(content: data, completion: .contentProcessed { _ in })
            return
        }

        guard let p = peripheral, p.state == .connected, let ch = rxChar else {
            // 只有「已连上、但特征还没就绪」那一瞬间才排队；
            // 未连接时的按键直接丢弃，否则连上瞬间会一次性灌给主机。
            if let p = peripheral, p.state == .connected, pending.count < 32 {
                pending.append(data)
                return
            }
            // 以前这里是静默 return：没连上时点屏幕键盘毫无反应，也没任何提示，
            // 看上去就像「字母按键坏了」。现在至少把原因写在日志里。
            noteDropped()
            return
        }
        write(data, to: p, char: ch)
    }

    /// 未连接时的提示。2 秒内只写一条，避免连点刷屏。
    private func noteDropped() {
        let now = Date()
        guard now.timeIntervalSince(lastDropLog) > 2 else { return }
        lastDropLog = now
        log("未连接，刚才的按键没有发出去（先点右上角「连接」）", isError: true)
    }

    func log(_ text: String, isError: Bool = false) {
        logs.append(LogEntry(text: text, isError: isError))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    /// 连上之后主动问一次固件里的引导键设置。
    ///
    /// 为什么必须问：客户端自己记的是「上次在这个 App 里点过什么」，固件记的是
    /// 真值，两者可能不一致（换了机器、刷过固件、用手机端改过）。一旦不一致，
    /// 用户点「写入固件」就会把界面上的旧值写回去——最典型的现象就是把已经设成
    /// 「关闭」的引导键又改回了 delete，于是「设了关闭，开机还是敲键」。
    /// 所以每次连上都对齐一次：以固件为准。
    private func queryBootConfig() {
        bootConfig = nil
        sawBootKeyReply = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.state.isConnected else { return }
            self.send(Command.bootKeyQuery)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.state.isConnected, self.bootConfig == nil else { return }
                if self.sawBootKeyReply {
                    // 老固件：认识 BOOTKEY:<键>，但不认识 window/gap，也不回 BOOTCFG。
                    // 键位是生效的，只是连发节奏改不了——说清楚，别让人以为整个功能坏了
                    self.log("固件只回了 BOOTKEY:（旧固件）：键位能用，"
                             + "但连发时长/间隔改不了。要用这两项得重新烧录当前固件", isError: true)
                } else {
                    self.log("固件没有回应 BOOTKEY:?：多半是更旧的固件（还不认识引导键命令），"
                             + "用当前源码重新烧录一次即可", isError: true)
                }
            }
        }
    }

    /// 收到一行固件回执。解析 BOOTCFG（引导键的完整参数）；
    /// BOOTKEY: / BOOTKEY-ERR: 只用来判断固件新旧，其余（PONG / READY）只进日志。
    private func noteIncoming(_ text: String) {
        if text.hasPrefix("BOOTKEY:") {
            sawBootKeyReply = true
        } else if text.hasPrefix("BOOTKEY-ERR:") {
            sawBootKeyReply = true
            log("固件不认这条引导键命令：\(text.dropFirst("BOOTKEY-ERR:".count))", isError: true)
            return
        } else if !text.hasPrefix("BOOTCFG:") {
            return
        }
        guard text.hasPrefix("BOOTCFG:") else { return }
        var fields: [String: String] = [:]
        for part in text.dropFirst("BOOTCFG:".count).split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                fields[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
                    String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        bootConfig = BootConfig(
            key: fields["key"] ?? "?",
            windowMs: Int(fields["win"] ?? "") ?? 0,
            gapMs: Int(fields["gap"] ?? "") ?? 0,
            holdMs: Int(fields["hold"] ?? "") ?? 0
        )
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - 扫描 / 连接

    private func startScan() {
        guard kind == .ble, central.state == .poweredOn else { return }
        cancelPendingWork()
        central.stopScan()

        state = .scanning
        if retryCount == 0 {
            log("扫描 “\(targetName)”，最长 \(Int(Timing.scan)) 秒")
        } else {
            log("重新扫描（第 \(retryCount)/\(Timing.maxAutoRetries) 次重试）")
        }

        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        startCountdown(Timing.scan)

        let work = DispatchWorkItem { [weak self] in self?.scanTimedOut() }
        scanTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.scan, execute: work)
    }

    private func scanTimedOut() {
        guard case .scanning = state else { return }
        central.stopScan()
        stopCountdown()
        wantConnection = false
        state = .failed("没找到 “\(targetName)”")
        log("扫描超时：\(Int(Timing.scan)) 秒内没有发现该设备，已停止。"
            + "确认板子已上电、在范围内，且设备名一致", isError: true)
    }

    /// 连接 / 服务发现阶段的超时。到期就取消这条连接，再决定是否重试。
    private func startStageTimeout(_ seconds: TimeInterval, reason: String) {
        stageTimeoutWork?.cancel()
        startCountdown(seconds)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isBusy else { return }
            self.stopCountdown()
            if let p = self.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
            self.teardownWiFi()
            self.log("\(reason)（超过 \(Int(seconds)) 秒）", isError: true)
            self.retryOrFail(reason)
        }
        stageTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func retryOrFail(_ reason: String) {
        stopCountdown()
        teardownLink()
        teardownWiFi()
        guard wantConnection else { state = .idle; return }

        retryCount += 1
        guard retryCount <= Timing.maxAutoRetries else {
            wantConnection = false
            state = .failed(reason)
            log("\(reason)，已重试 \(Timing.maxAutoRetries) 次仍未成功，停止自动重连", isError: true)
            return
        }
        state = .failed("\(reason)（重试 \(retryCount)/\(Timing.maxAutoRetries)）")
        log("\(Int(Timing.retryGap)) 秒后自动重试", isError: true)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        guard wantConnection else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnection else { return }
            self.restartAttempt()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.retryGap, execute: work)
    }

    /// 重连时按当前链路类型重新发起，别把 Wi-Fi 的连接请求发到蓝牙上
    private func restartAttempt() {
        switch kind {
        case .ble: startScan()
        case .wifi: startWiFi()
        }
    }

    // MARK: - Wi-Fi 链路（TCP）

    /// 连到板子热点里的 TCP 服务端。板子必须先连上它开的热点，
    /// 否则这里会因为「找不到路由」直接失败——错误文案里会提示。
    private func startWiFi() {
        cancelPendingWork()
        central.stopScan()
        teardownWiFi()

        wifiTarget = "\(wifiHost):\(wifiPort)"
        wifiRxBuffer = ""
        state = .connecting
        if retryCount == 0 {
            log("连接 Wi-Fi 桥 \(wifiTarget)，最长 \(Int(Timing.wifiConnect)) 秒")
        } else {
            log("重新连接 \(wifiTarget)（第 \(retryCount)/\(Timing.maxAutoRetries) 次重试）")
        }

        guard let port = NWEndpoint.Port(rawValue: wifiPort) else {
            state = .failed("端口不合法：\(wifiPort)")
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(wifiHost),
                                port: port,
                                using: .tcp)
        nw = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self, self.nw === conn else { return }
            switch newState {
            case .ready:
                self.retryCount = 0
                self.stageTimeoutWork?.cancel()
                self.stageTimeoutWork = nil
                self.stopCountdown()
                self.connectedName = self.wifiTarget
                self.state = .connected
                self.log("Wi-Fi 链路就绪（\(self.wifiTarget)）")
                self.receiveWiFi(conn)
                self.queryBootConfig()
            case .waiting(let error):
                self.log("网络暂不可达：\(error.localizedDescription)", isError: true)
            case .failed(let error):
                self.log("连不上 \(self.wifiTarget)：\(error.localizedDescription)", isError: true)
                self.retryOrFail("连不上 \(self.wifiTarget)")
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .main)

        startCountdown(Timing.wifiConnect)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isBusy else { return }
            self.stopCountdown()
            self.teardownWiFi()
            self.log("Wi-Fi 连接超时（超过 \(Int(Timing.wifiConnect)) 秒）："
                + "确认笔记本已连上热点 \(LinkKind.defaultHotspot)", isError: true)
            self.retryOrFail("Wi-Fi 连接超时")
        }
        stageTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.wifiConnect, execute: work)
    }

    /// 持续收包，按 \n 切行。协议和 BLE 完全相同。
    private func receiveWiFi(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.nw === conn else { return }

            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                self.wifiRxBuffer += text
                while let idx = self.wifiRxBuffer.firstIndex(of: "\n") {
                    let line = String(self.wifiRxBuffer[..<idx])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.wifiRxBuffer.removeSubrange(self.wifiRxBuffer.startIndex...idx)
                    if !line.isEmpty {
                        self.log("← \(line)")
                        self.noteIncoming(line)
                    }
                }
                // 防止对端一直不发换行把内存撑大
                if self.wifiRxBuffer.count > 8192 {
                    self.wifiRxBuffer = ""
                }
            }

            if let error {
                self.log("Wi-Fi 链路错误：\(error.localizedDescription)", isError: true)
            }
            if isComplete || error != nil {
                self.handleWiFiDrop()
                return
            }
            self.receiveWiFi(conn)
        }
    }

    private func handleWiFiDrop() {
        teardownWiFi()
        onDisconnect?()
        stopCountdown()

        guard wantConnection else {
            state = .idle
            return
        }
        retryCount = 0
        state = .idle
        log("Wi-Fi 连接已断开，准备重连", isError: true)
        scheduleReconnect()
    }

    private func teardownWiFi() {
        if let conn = nw {
            nw = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        wifiRxBuffer = ""
        if kind == .wifi { connectedName = "" }
    }

    // MARK: - 倒计时

    private func startCountdown(_ seconds: TimeInterval) {
        stopCountdown()
        countdownEnd = Date().addingTimeInterval(seconds)
        phaseSeconds = max(1, Int(seconds.rounded(.up)))
        remainingSeconds = phaseSeconds
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let end = self.countdownEnd else { return }
            let left = Int(ceil(end.timeIntervalSinceNow))
            if left <= 0 {
                self.stopCountdown()
            } else if left != self.remainingSeconds {
                self.remainingSeconds = left
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEnd = nil
        if remainingSeconds != 0 { remainingSeconds = 0 }
        if phaseSeconds != 0 { phaseSeconds = 0 }
    }

    // MARK: - 内部

    private func cancelPendingWork() {
        scanTimeoutWork?.cancel(); scanTimeoutWork = nil
        stageTimeoutWork?.cancel(); stageTimeoutWork = nil
        reconnectWork?.cancel(); reconnectWork = nil
    }

    private func teardownLink() {
        rxChar = nil
        peripheral = nil
        connectedName = ""
        pending.removeAll()
    }

    private func write(_ data: Data, to p: CBPeripheral, char: CBCharacteristic) {
        let type: CBCharacteristicWriteType =
            char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // 按最小 MTU(23) 保守分片，不依赖协商结果
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 20, limitedBy: data.endIndex) ?? data.endIndex
            p.writeValue(Data(data[index..<end]), for: char, type: type)
            index = end
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LinkBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙就绪")
            // 只要有连接意图且没连上，就（重新）开始扫描。
            // 这样在 .unknown 阶段点过连接、界面已进入「扫描中」的情况也能接上。
            // Wi-Fi 模式不看蓝牙状态，否则蓝牙关着会误触发扫描。
            if wantConnection && !state.isConnected && kind == .ble { startScan() }
        case .poweredOff:
            wantConnection = false
            cancelPendingWork()
            stopCountdown()
            teardownLink()
            state = .bluetoothOff
            log("蓝牙已关闭", isError: true)
        case .unauthorized:
            state = .unauthorized
            log("蓝牙权限被拒绝：系统设置 → 隐私与安全性 → 蓝牙", isError: true)
        case .unsupported:
            state = .failed("这台机器不支持蓝牙")
            log("这台机器不支持蓝牙", isError: true)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? ""
        guard !name.isEmpty,
              name.localizedCaseInsensitiveContains(targetName) else { return }
        guard case .scanning = state else { return }

        central.stopScan()
        scanTimeoutWork?.cancel(); scanTimeoutWork = nil

        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        log("发现 “\(name)”（\(RSSI.intValue) dBm），正在连接…")
        central.connect(peripheral, options: nil)
        startStageTimeout(Timing.connect, reason: "连接超时")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopCountdown()
        retryCount = 0
        connectedName = peripheral.name ?? targetName
        log("已连接 \(connectedName)，正在发现服务…")
        peripheral.discoverServices([CBUUID(string: Link.service)])
        startStageTimeout(Timing.discover, reason: "服务发现超时")
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        stageTimeoutWork?.cancel(); stageTimeoutWork = nil
        guard wantConnection else {
            stopCountdown()
            teardownLink()
            state = .idle
            return
        }
        log("连接失败：\(error?.localizedDescription ?? "未知原因")", isError: true)
        retryOrFail("连接失败")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stageTimeoutWork?.cancel(); stageTimeoutWork = nil
        stopCountdown()
        let wasConnected = state.isConnected
        teardownLink()
        onDisconnect?()

        guard wantConnection else {
            state = .idle
            return
        }
        if let error {
            log("连接断开：\(error.localizedDescription)，准备重连", isError: true)
        } else {
            log(wasConnected ? "连接已断开，准备重连" : "连接已断开")
        }
        retryCount = 0
        state = .idle
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension LinkBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("发现服务失败：\(error.localizedDescription)", isError: true)
            retryOrFail("发现服务失败")
            return
        }
        for service in peripheral.services ?? [] where service.uuid == CBUUID(string: Link.service) {
            peripheral.discoverCharacteristics(
                [CBUUID(string: Link.rx), CBUUID(string: Link.tx)], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            log("发现特征失败：\(error.localizedDescription)", isError: true)
            retryOrFail("发现特征失败")
            return
        }
        for char in service.characteristics ?? [] {
            if char.uuid == CBUUID(string: Link.rx) {
                rxChar = char
            } else if char.uuid == CBUUID(string: Link.tx) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        guard rxChar != nil else {
            log("没有找到写入特征，检查两端 UUID 是否一致", isError: true)
            retryOrFail("设备特征不匹配")
            return
        }

        stageTimeoutWork?.cancel(); stageTimeoutWork = nil
        stopCountdown()
        state = .connected
        log("链路就绪")
        let queued = pending
        pending.removeAll()
        if let ch = rxChar {
            for data in queued {
                write(data, to: peripheral, char: ch)
            }
        }
        queryBootConfig()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let value = characteristic.value,
              let text = String(data: value, encoding: .utf8) else { return }
        log("← \(text)")
        noteIncoming(text)
    }
}

// MARK: - 超时参数

private enum Timing {
    /// 扫描多久没发现设备就放弃（秒）
    static let scan: TimeInterval = 12
    /// 从发起连接到连接成功的超时（秒）
    static let connect: TimeInterval = 10
    /// 服务/特征发现阶段的超时（秒）
    static let discover: TimeInterval = 8
    /// Wi-Fi TCP 握手超时（秒）。热点在本地，通常 1 秒内就通
    static let wifiConnect: TimeInterval = 6
    /// 失败后自动重试的间隔（秒）与次数上限
    static let retryGap: TimeInterval = 1.5
    static let maxAutoRetries = 2
}
