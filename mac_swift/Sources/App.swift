import SwiftUI

@main
struct RemoteKeyboardApp: App {
    @StateObject private var bridge = LinkBridge()
    @StateObject private var forwarder = KeyForwarder()

    var body: some Scene {
        WindowGroup("ESP32 远程键盘") {
            ContentView()
                .environmentObject(bridge)
                .environmentObject(forwarder)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 这类工具不需要「新建窗口」
            CommandGroup(replacing: .newItem) {}
        }

        // 菜单栏常驻入口：开/停捕获、松键、回主窗口、退出。
        // 捕获期间本机键盘被吞掉，窗口又可能被盖住或关掉（关窗口不退进程），
        // 这一项是那时唯一还用鼠标点得到的出口，所以它必须一直挂着。
        // 和主窗口共用同一对 StateObject，两边状态天然同步。
        MenuBarExtra {
            CaptureMenu(bridge: bridge, forwarder: forwarder)
        } label: {
            StatusBarLabel(forwarder: forwarder)
        }
        .menuBarExtraStyle(.menu)
    }
}
