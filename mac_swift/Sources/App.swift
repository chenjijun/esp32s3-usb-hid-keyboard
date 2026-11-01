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
    }
}
