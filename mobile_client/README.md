# 手机端（Android / iOS）

ESP32-S3 无线键盘的 Flutter 客户端。协议、键名、GATT UUID 与 `mac_swift/`、`mac_client/` 完全一致，
只是把「控制端」搬到了手机上。

## 为什么是「遥控器」形态

iOS 和 Android 都不允许普通 App 抓本机键盘（没有 macOS 辅助功能授权那种口子），所以手机端不做
「本机键盘转发」，而是：

- **屏幕键盘**：字母 / 符号 / 编辑 / 功能 / 数字 五页，粘滞修饰键；
- **文本框**：用手机输入法把整段文字发过去，固件逐字符敲出来（只支持 ASCII）；
- **鼠标触控板**：单指移动、双指滚动、轻点左键，加左中右三键与「按住左键」；
- **快捷键**：Windows / macOS 两套预设 + BIOS 引导键。

## 跑起来

```bash
flutter pub get
flutter run -d <设备>              # 真机或模拟器
```

打包：

```bash
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
flutter build ios --release        # 需要 Xcode 里配好签名
```

（`android/app/build.gradle.kts` 里 release 暂时复用 debug 签名，方便侧载安装；
要上应用商店请换成自己的 keystore。）

## 代码结构

```
lib/
├── core/
│   ├── protocol.dart   # 命令拼装 + 键位布局 + 预设（纯 Dart，可单测）
│   ├── transport.dart  # BLE（GATT 写 RX / 订阅 TX）与 Wi-Fi TCP，同一个接口
│   ├── remote.dart     # 状态机：扫描、连接、粘滞修饰键、鼠标攒批、回执解析
│   └── scope.dart      # InheritedNotifier，把 Remote 注入界面
├── ui/                 # home / keyboard / mouse / keys / settings / connect_sheet
├── debug_flags.dart    # 截图用的构建期开关（START_TAB / OPEN_CONNECT / FORCE_LANDSCAPE）
└── main.dart
test/protocol_test.dart         # 19 项，含读 ../esp32s3_ble_keyboard/*.ino 核对键名与 UUID
integration_test/app_test.dart  # 真点界面 + 假 TCP 服务端，验证整条发送链路
```

## 测试

```bash
flutter analyze
flutter test                                   # 协议层 + 与固件一致性
flutter test integration_test -d <模拟器>       # 端到端（会自己起假固件服务端）
```

端到端测试干的事：起一个 `ServerSocket` 冒充固件，界面上依次点「连接 → q → ⇧+q → 鼠标拖动 →
右键 → 输入文本」，断言服务端收到的正好是 `PING` / `BOOTKEY:?` / `TAP:q` / `COMBO:shift+q` /
`MOUSE:move …` / `MOUSE:click right` / `TYPE:hi there`，最后回一条 `PONG:…,leds=3` 验证回执解析。

## 两个环境上的坑（改工程时注意）

1. **Xcode 的 Swift Package Manager**：Flutter 3.47 默认生成 SPM 依赖（`FlutterGeneratedPluginSwiftPackage`）。
   如果 `xcodebuild` 在受限环境里报 `sandbox-exec: sandbox_apply: Operation not permitted`，
   就把 `ios/Runner.xcodeproj/project.pbxproj` 里的 SPM 段落删掉、回到 CocoaPods：

   ```bash
   flutter config --no-enable-swift-package-manager
   # 再删掉 project.pbxproj 里的 FlutterGeneratedPluginSwiftPackage / XCLocalSwiftPackageReference 段落
   ```

   本仓库的 iOS 工程已经是 CocoaPods 形态，`pod install` 会自动跑。

2. **flutter_blue_plus 版本**：`pubspec.yaml` 固定 `1.36.8`。2.x 起许可证改成「商业使用需购买」，
   并在构建期发送许可上报；本项目是 MIT，不想把这种约束带给使用者。要升级请自行确认许可条款。

## 已知限制

- 只能敲 ASCII：固件按 HID 键码逐字符发送，中文要靠被控主机的输入法。
- ESP32 同时只接一个客户端（BLE 与 Wi-Fi 也是二选一，由板上 BOOT 键切换）。
- iOS 首次连 Wi-Fi 链路会弹「本地网络」授权，必须允许；Android 连板子热点时若提示
  「此 WLAN 无法访问互联网」，选择保持连接。
