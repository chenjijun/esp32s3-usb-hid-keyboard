# ESP32-S3 无线键盘桥（USB HID over BLE / Wi-Fi）

一块 ESP32-S3 插在被控主机的 USB 口上，充当**标准 USB 键盘 + 鼠标**；你的 Mac / Windows 电脑
通过 **蓝牙** 或 **Wi-Fi** 把按键发过去。被控主机免驱、不改设置，插上就认，Mac / Windows / Linux / BIOS 通吃。

![程序流程与架构](docs/architecture.jpg)

关键点：**BLE / Wi-Fi 只是控制链路，不是把 ESP32 配成电脑的蓝牙键盘**。所以本机键盘触控板完全不受影响，
被控主机那边看到的是一个彻底的普通 USB 键盘。

| 层 | 角色 | 做什么 |
| --- | --- | --- |
| 控制端 | Swift / Python 客户端 | 产生按键、鼠标事件，编码成一行行 ASCII 命令 |
| 传输层 | BLE 自定义 GATT 或 Wi-Fi AP + TCP | 只搬文本，20 字节一片，`\n` 分帧 |
| 执行端 | ESP32-S3 固件 | 解析命令 → USB HID 报告 → OTG 口发给主机 |

## 主要功能

- **双链路**：蓝牙 BLE 或 Wi-Fi 热点直连，板载 BOOT 键切换，RGB 灯用颜色区分状态（蓝/紫、绿/黄）。
- **复合 HID**：键盘、鼠标、多媒体键共用一个 USB 设备（report ID 1 / 2 / 4），一根线全搞定。
- **本机键盘转发**：接管控制端键盘，按键原样转给主机；修饰键全量镜像，能敲 Win+Space / Ctrl+Space 切输入法。
- **屏幕键盘 + 鼠标触控板**：没带键盘或只想点两下时用，和本机转发走同一条发送路径。
- **进 BIOS / UEFI**：引导键写进固件 NVS（掉电保持），上电自己连发，不依赖链路是否已连上。
- **纯文本协议**：`TAP:enter`、`COMBO:ctrl+alt+del`、`MOUSE:move 12 -7`，任何语言都能写客户端。
- **两个客户端**：Swift 版（macOS 原生界面）+ Python 版（macOS / Windows 通用，含命令行模式）。

## 硬件

- ESP32-S3 开发板，必须有**原生 USB**（GPIO19 = D-、GPIO20 = D+）。
- 用板上的 **USB / OTG 口**接被控主机（不是 UART 调试口），供电也走这个口。

## 一、烧固件

Arduino IDE 2.x + esp32 核心 3.x（实测 3.3.1）。板卡选 **ESP32S3 Dev Module**，然后：

| 选项 | 值 |
| --- | --- |
| USB Mode | **USB-OTG (TinyUSB)** ← 默认不是它，必须手动改，否则 `USBHIDKeyboard` 链接不出来 |
| USB CDC On Boot | Enabled（USB 口上多个串口看日志，不影响 HID） |
| Flash Size / PSRAM | 按模组选 |
| Partition Scheme | 默认 |

命令行编译（`arduino-cli`）：

```bash
arduino-cli compile --fqbn "esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc" esp32s3_ble_keyboard
```

烧录时 IDE 找不到端口：按住 **BOOT**，点一下 **RST**，松开 BOOT 再上传（程序跑起来后 USB 是 HID，重烧都要这样进下载模式）。

烧完串口会打印 `[BLE] 广播中，设备名: ESP32-Keyboard`；把 USB 口插到被控主机上，主机就把它识别成键盘。
想改设备名 / UUID 改文件顶部常量。

## 二、用客户端

发布包在 [Releases](https://github.com/chenjijun/esp32s3-usb-hid-keyboard/releases)：

| 包 | 平台 | 说明 |
| --- | --- | --- |
| `ESP32-RemoteKeyboard-*.dmg` | macOS | Swift 版，原生界面，拖进应用程序即可 |
| `ESP32KeyboardSwift-*.zip` | macOS | Swift 版源码 + 编译脚本 |
| `ESP32Keyboard-Python-*.zip` | macOS | Python 版（启动壳 + 源码） |
| `ESP32Keyboard-Python-*-windows.zip` | Windows | Python 版源码 + 一键打包脚本（`build_win.bat`） |

板子上按 **BOOT** 键选链路：BLE 灯蓝色（未连）→ 紫色（已连）；Wi-Fi 灯绿色（未连）→ 黄色（已连）。
客户端里选同一种链路，点「连接」。

- **蓝牙**：直接扫设备名 `ESP32-Keyboard`。
- **Wi-Fi**：电脑先连热点 `ESP32-Keyboard` / 密码 `esp32keyboard`，主机填 `192.168.4.1`、端口 `8266`。

### Swift 版（macOS）

```bash
./mac_swift/build.sh          # 编译出 ESP32KeyboardSwift.app
open ESP32KeyboardSwift.app
```

首次运行要授权两次：**蓝牙**（系统弹窗点允许）和 **辅助功能**（系统设置 → 隐私与安全性 → 辅助功能，
勾选本 App；重新编译过的 App 要重新勾）。

### Python 版

```bash
python3 -m pip install -r mac_client/requirements.txt
./mac_client/build_app.sh     # 生成 ESP32Keyboard.app（带蓝牙用途声明）
open ESP32Keyboard.app
```

macOS 上**别**用 `python3 ble_keyboard_client.py` 直接开：TCC 只认带蓝牙声明的 App，裸进程会被系统直接杀掉。
命令行模式可以用：

```bash
python3 mac_client/ble_keyboard_client.py --cli                # 蓝牙
python3 mac_client/ble_keyboard_client.py --cli --mode wifi    # Wi-Fi
```

Windows 没有现成的 exe（PyInstaller 不能跨平台编译），下载 `*-windows.zip` 后：

1. 装 Python 3.9+（python.org 安装包，勾选 *Add python.exe to PATH*）；
2. 双击 `mac_client\build_win.bat`，脚本会建虚拟环境、装 bleak 和 PyInstaller、打包并压成 zip；
3. 用 `dist_win\ESP32Keyboard\ESP32Keyboard.exe` 启动。也可以不打包，直接
   `python ble_keyboard_client.py` 跑。

Windows 上键盘转发不需要授权，但系统不允许拦截 `Ctrl+Alt+Delete`，也收不到「以管理员运行的窗口」的按键
（想让它们也生效，就右键 exe → 以管理员身份运行）。界面按 1256×862 设计，建议 1920×1080 以上分辨率。

两个客户端都支持：屏幕键盘（粘滞修饰键）、鼠标拖拽区 + 三键 + 滚轮 + 按住左键、常用快捷键预设、
BIOS 引导键写入 / 立即连发 / 查询、日志面板。停下本机键盘转发：点「停止」或按 `Ctrl+Alt+Esc`。

## 三、通信协议

BLE 特征 `...def1` 上按行写 ASCII，`\n` 结尾；Wi-Fi 是 TCP 直连，同样的行。

| 命令 | 说明 | 示例 |
| --- | --- | --- |
| `TAP:<键>` | 按一下 | `TAP:enter` |
| `DOWN:<键>` / `UP:<键>` | 按下 / 松开（修饰键走这条） | `DOWN:lshift` |
| `TYPE:<文本>` | 逐字符输入 | `TYPE:hello` |
| `COMBO:<键>+<键>…` | 组合键，依次按下再逆序松开 | `COMBO:cmd+shift+4` |
| `MEDIA:<名称>` | 多媒体键 | `MEDIA:volup` |
| `RELEASEALL` | 松开所有键 | `RELEASEALL` |
| `PING` | 心跳，回 `PONG:<millis>,leds=<位图>` | `PING` |
| `BOOTKEY:<键>` / `off` / `now` / `?` | 设 / 关 / 立即连发 / 查询引导键 | `BOOTKEY:f2` |
| `MOUSE:move <dx> <dy>` | 相对位移，单条 ±127（client 会自动拆条） | `MOUSE:move 12 -7` |
| `MOUSE:wheel <n>` | 滚轮，正数向上 | `MOUSE:wheel 3` |
| `MOUSE:down/up/click left\|middle\|right` | 鼠标键 | `MOUSE:click right` |
| `MOUSE:release` | 松开所有鼠标键 | `MOUSE:release` |

键名：单字符直接写（`a`、`1`、`/`，需要 Shift 的由库自动补）；命名键有
`enter` `esc` `tab` `space` `backspace` `delete` `insert` `home` `end` `pageup` `pagedown` `up` `down` `left` `right`
`capslock` `printscreen` `menu` `f1`~`f24` `kp0`~`kp9` 等；修饰键 `ctrl` `shift` `alt` `cmd`（= Win/GUI），
每个都带 `l`/`r` 侧别（`lshift`、`rctrl`…）。

## 四、常见问题

**插上没反应 / 主机不认识？** 看 USB Mode 是否选了 `USB-OTG (TinyUSB)`；换线；确认用的是板上的 USB 口而不是 UART 口。

**蓝牙连不上？** 确认板子灯是蓝色（BLE 模式）且没被别的设备占着；Windows 上要确认本机有蓝牙适配器。

**Wi-Fi 连不上？** 电脑要连的是板子开的热点 `ESP32-Keyboard`，主机地址是 `192.168.4.1`，端口 `8266`。

**按键卡住 / 主机一直按着某个键？** 点「释放全部按键」（发 `RELEASEALL`），断开连接和关窗口也会自动松键。

**本机键盘转发没反应？** macOS 看「辅助功能」授权（重新编译过的 App 要重新勾）；Windows 看是否被安全软件拦了键盘钩子。

**能进 BIOS 吗？** 能，引导键写在固件里，上电自己连发，跟链路连没连无关。注意部分主板要关掉「快速启动」。

**安全吗？** 这是个遥控键盘，能操作被控主机的一切。别在不受控的环境里开着本机键盘转发，用完点「停止」。

## 五、目录结构

```
├── esp32s3_ble_keyboard/esp32s3_ble_keyboard.ino  # 固件（单文件自包含）
├── mac_swift/                                     # Swift 版客户端 + build.sh / package.sh
├── mac_client/                                    # Python 版客户端（macOS / Windows）
│   ├── ble_keyboard_client.py                     # 协议 / 链路 / 键盘钩子 / 界面 / CLI
│   ├── build_app.sh  package_app.sh               # macOS 打包
│   └── build_win.bat  windows/README.txt          # Windows 打包
├── tools/make_ico.sh                              # app_icon.png → .ico / 256px png
├── app.png  app_icon.png                          # 架构图原图 / 图标源图
├── docs/architecture.jpg                          # README 用的架构图
└── docs/ARCHITECTURE.md                           # 详细实现说明（代码地图、设计取舍）
```

## 六、许可

[MIT](LICENSE) © 2026 chenjijun

更细的实现说明（一次按键走过的完整路径、固件代码分段地图、几个设计取舍）见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
