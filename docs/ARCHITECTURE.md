> 这是 README 的**详细版**：保留完整的实现说明、代码地图、排错过程。
> 功能清单、打包命令、版本号以 [README](../README.md) 为准，这里可能是旧的。

# ESP32-S3 无线键盘桥（USB HID over BLE / Wi-Fi）

把一块 **ESP32-S3** 做成「无线接收 → USB 键盘/鼠标输出」的桥：控制端（MacBook、手机、任何能发
蓝牙或 TCP 的设备）把按键指令发过来，板子用 **OTG 口**以一个**标准 USB 键盘**（外加鼠标、多媒体键）
的身份打给被控主机。被控主机不装驱动、不改设置，插上就认。

![程序流程与架构](docs/architecture.jpg)

整条链路分三层，各管一段：

| 层 | 角色 | 做什么 |
| --- | --- | --- |
| 控制端 | Swift 客户端 / Python 客户端 / 手机 App | 产生按键、鼠标事件，编码成一行行 ASCII 命令 |
| 传输层 | BLE 自定义 GATT 或 Wi-Fi AP + TCP | 只负责把文本搬过去；20 字节一片，`\n` 分帧 |
| 执行端 | ESP32-S3 固件 | 解析命令 → 转成 USB HID 报告 → 从 OTG 口发给主机 |

关键点：**BLE/Wi-Fi 只是「控制链路」，不是把 ESP32 配对成 Mac 的蓝牙键盘**。所以 Mac 自带的
键盘、触控板完全不受影响；而被控主机那边看到的，是一个彻头彻尾的普通 USB 键盘（免驱，
Mac / Windows / Linux / BIOS 通吃）。

## 能干什么

- **双链路**：BLE 或 Wi-Fi 热点直连，板载 BOOT 键切换，RGB 灯用颜色区分状态（蓝/紫、绿/黄）。
- **复合 HID**：键盘 + 鼠标 + 多媒体键共用一个 USB 设备（report ID 1 / 2 / 4），一根线全搞定。
- **本机键盘转发**：用 `CGEventTap` 把 MacBook 键盘真按键转给主机，能吞键、支持组合键与输入法切换。
- **屏幕键盘 + 鼠标触控板**：没带键盘、或只想点两下时用；和本机转发走同一条发送路径。
- **进 BIOS / UEFI**：引导键写在固件里，开机后自己连发，不依赖链路是否已连上。
- **Windows 兼容**：修饰键镜像，能敲 Win+Space / Ctrl+Space 切输入法。
- **协议是纯文本**：`TAP:enter`、`COMBO:ctrl+alt+del`、`MOUSE:move 12 -7`，用任何语言都能写客户端。

```
 MacBook（控制端）              ESP32-S3                     被控主机
 ┌────────────────┐  BLE/Wi-Fi  ┌──────────────┐  USB OTG   ┌──────────┐
 │ Swift / Python │ ──────────> │ 协议解析      │ ─────────> │ 标准 USB │
 │  客户端         │  ASCII 命令  │ → USB HID    │  HID 报文   │ 键盘鼠标  │
 └────────────────┘             └──────────────┘            └──────────┘
```

## 目录结构

```
esp32s3usbhid/
├── esp32s3_ble_keyboard/
│   └── esp32s3_ble_keyboard.ino   # ESP32-S3 固件，1450 行单文件自包含
├── mac_swift/                     # Swift 版客户端（原生界面 + 本机键盘转发 + 鼠标）
│   ├── Sources/
│   │   ├── App.swift              # 入口、窗口尺寸、菜单栏项（MenuBarExtra）
│   │   ├── MenuBar.swift          # 菜单栏图标 + 下拉菜单（开/停捕获、松键、回窗口、退出）
│   │   ├── ContentView.swift      # 全部界面 + UIState（界面状态、鼠标位移攒批）
│   │   ├── LinkBridge.swift       # 双链路：CoreBluetooth + NWConnection，状态机与日志
│   │   ├── KeyForwarder.swift     # CGEventTap 捕获本机键盘 → 协议命令
│   │   ├── Protocol.swift         # 命令构造、键名映射、屏幕键盘布局、预设组合键
│   │   └── MousePad.swift         # 拖拽区手势、鼠标键「按下/松开」捕捉
│   ├── Resources/Info.plist
│   ├── Resources/AppIcon.icns     # App 图标（由 make_icon.sh 生成）
│   ├── tools/make_icon.swift      # 把普通图片裁成 macOS 圆角图标
│   ├── make_icon.sh               # app_icon.png → AppIcon.icns
│   ├── build.sh                   # 编译 .app（支持 --universal）
│   └── package.sh                 # 打 dmg / zip
├── mac_client/                    # Python 版客户端（GUI + CLI，功能与 Swift 版对齐）
│   ├── ble_keyboard_client.py     # 协议 / 双链路 / 本机键盘转发 / Tkinter 界面 / CLI
│   ├── build_app.sh              # 生成带蓝牙声明的 ESP32Keyboard.app（固定证书签名）
│   ├── package_app.sh            # 打 dist/ESP32Keyboard-Python-<版本>.zip
│   └── requirements.txt           # bleak（必需）+ pyobjc（本机转发用，可选）
├── docs/architecture.jpg          # 架构图（由 app.png 压缩而来，README 引用它）
├── app.png                        # 架构图原图
├── app_icon.png                   # 图标源图（方形裁切后使用）
├── platformio.ini                 # 想用 PlatformIO 编译时的配置
├── tools/test_python_ui.py        # Python 版界面自测（折叠 / 配色对比度 / 命令格式）
├── dist/                          # package.sh 产出：dmg / zip（不进 git）
├── ESP32KeyboardSwift.app         # Swift 版，双击启动（不进 git）
├── ESP32Keyboard.app              # Python 版启动器（不进 git）
└── README.md
```

---

## 一、ESP32-S3 端

### 1. 硬件

- ESP32-S3 开发板（必须有**原生 USB**，即 GPIO19 = D-、GPIO20 = D+）。
- 用板子上的 **USB / OTG 口**接被控主机（不是 UART 调试口）。供电也走这个口。
- 若板子只有一个 Type-C 且标注 USB，就是它；若有两个，选写着 `USB` 的那个。

### 2. 编译环境

- Arduino IDE 2.x
- esp32 开发板核心 **3.x**（已在 3.3.1 上实测编译通过）

### 3. 板卡设置（关键，选错直接编译报错）

| 选项 | 值 |
| --- | --- |
| 开发板 | **ESP32S3 Dev Module** |
| USB Mode | **USB-OTG (TinyUSB)** ← 默认值是 `Hardware CDC and JTAG`，必须手动改 |
| USB CDC On Boot | **Enabled**（USB 口上多一个串口，能看日志；不影响 HID） |
| Flash Size | 按模组选（如 16MB） |
| PSRAM | 按模组选，可选 |
| Partition Scheme | 默认即可 |

`USB Mode` 这两档到底差在哪，值得说清楚（也是新手最容易踩的坑）：

| 档位 | 编译宏 | USB 口的作用 | 能不能出 HID |
|---|---|---|---|
| USB-OTG (TinyUSB) | `ARDUINO_USB_MODE=0` | TinyUSB 栈，可做 HID / CDC / MSC | **能**，本固件要的就是它 |
| Hardware CDC and JTAG | `ARDUINO_USB_MODE=1` | 只有硬件 CDC 串口（+ JTAG 调试） | 不能，`USBHIDKeyboard` 根本链接不出来 |

所以代码里加了编译期拦截，选错会立刻停下并告诉你改哪里，而不是编到链接阶段再抛一堆
`undefined reference`：

```
error: #error "USB Mode 现在是 'Hardware CDC and JTAG'：这档只把 USB 口当硬件串口用…"
```

**解决**：工具 → USB Mode → `USB-OTG (TinyUSB)`，重新编译即可。想恢复串口日志，
另外把 工具 → USB CDC On Boot 设为 `Enabled`（这两项完全独立，别为了看日志把 USB Mode 改回去）。

命令行编译（`arduino-cli`，Arduino IDE 2.x 自带，路径在
`/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli`）：

```bash
arduino-cli compile --fqbn "esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc" esp32s3_ble_keyboard
```

注意 FQBN 里**必须显式写 `USBMode=default`**：只写 `esp32:esp32:esp32s3` 会取菜单第一项，
也就是 `Hardware CDC and JTAG`，同样会报上面的错。

### 4. 烧录

用 Arduino IDE 打开 `esp32s3_ble_keyboard.ino`，选好端口后上传。

烧完后：
- 串口（115200）会打印 `[BLE] 广播中，设备名: ESP32-Keyboard`
- 把 USB 口插到被控主机上，主机会把它识别成一个键盘

> 烧录时如果 IDE 找不到端口：按住 **BOOT** 键，点一下 **RST**，松开 BOOT，再上传。
> 因为程序运行后 USB 变成了 HID 复合设备，重新烧录通常都要这样进下载模式。

### 5. 想改设备名 / UUID？

改文件顶部：

```cpp
#define DEVICE_NAME "ESP32-Keyboard"
static const char *SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0";
```

改 UUID 的话，`mac_client/ble_keyboard_client.py` 顶部的三个 UUID 也要同步改。

### 6. 固件的代码结构

**单文件，没有别的 .h**。整个 `esp32s3_ble_keyboard.ino` 约 1300 行，分两部分：

| 段落 | 内容 | 改动频率 |
|---|---|---|
| 第一部分：协议解析与键名映射 | 键码表 `KT_KEY_*`、命令枚举、`kt_parse()` | 加键名/加命令时改这里 |
| 第二部分：BLE + USB HID | GATT 服务、收包、调 `Keyboard` 发按键 | 基本不用动 |

分界处有醒目注释（「键名映射结束」）。第一部分是纯 C/C++，不依赖 Arduino，
只用到 `stddef` / `stdint` / `string` 三个标准头。

文件里还有一组 `static_assert`，把自建的 `KT_KEY_*` 和 Arduino 核心的 `KEY_*`
钉在一起。哪天 ESP32 核心升级改了键码编码，编译期就会报错，不会烧进去才发现按键全错。

### 7. 双链路：BLE 与 Wi-Fi（BOOT 键切换）

同时支持两种链路，**同一时刻只用一种**，短按板载 **BOOT 键**切换，选择存进 NVS，
重新上电还是上次那个模式。

| 模式 | 客户端怎么连 | 指示灯（WS2812） |
| --- | --- | --- |
| BLE | 按设备名 `ESP32-Keyboard` 扫描连接 | 等待连接 **蓝**，连上 **紫** |
| Wi-Fi | 板子开热点，电脑连上热点后连 `192.168.4.1:8266` | 等待连接 **绿**，连上 **黄** |

两种模式跑的是同一套文本协议（`TAP:` / `TYPE:` / `COMBO:` / `PING` …），
客户端只换传输层，功能完全一样；按键、多媒体键、文字输入都走同一条命令通路。

**指示灯**是板载 WS2812，默认 `GPIO48`（ESP32-S3-DevKitC-1 / DevKitM-1）。
别的板子可能是 38 / 21 / 45，改文件顶部的 `LED_RGB_PIN`；板子没有 RGB 灯就把
`LED_USE_RGB` 设 0（此时只能靠串口日志看状态）。上电时会红、绿、蓝各闪一下做自检，
不闪就是引脚不对。

**嫌灯太亮**调 `LED_BRIGHTNESS`（0~255，当前 128 ≈ 50%）：

```cpp
#define LED_BRIGHTNESS  128   // 255 = 全亮，64 ≈ 25%，16 ≈ 6%，0 = 关灯
```

三个通道乘同一个系数，所以色相不变（蓝还是蓝，只是暗）。改完要重新烧录。

**指令闪灯**：每执行完一条协议命令，再白闪一下，闪几下由命令长度决定。这是唯一一个
「不看屏幕也知道命令进去了没有」的反馈——被控主机全屏、画面被盖住、或者手机端盲打长文本时，
灯就是全部的回应。

| 命令长度 | 闪几下 | 典型命令 |
| --- | --- | --- |
| 1–8 字节 | 1 | `TAP:q`、`RELEASEALL` |
| 9–32 字节 | 2 | `MOUSE:click right`、`BOOTKEY:?` |
| 33–128 字节 | 3 | `TYPE:hello` |
| 129–512 字节 | 4 | 一句话 |
| 513–1024 字节 | 5 | 一段话 |
| > 1024 字节 | 6 | 一次粘一大坨 |

白闪是插在链路底色上的：亮的时候白，灭的那一下露出蓝/紫/绿/黄，所以「有命令在走」
和「链路是什么状态」可以同时读出来。`PING` 心跳不闪（每 10 秒一次，闪起来像故障）；
`MOUSE:move` / `MOUSE:wheel` 也不闪（客户端是 30Hz 攒批发的），`MOUSE:down/up/click/release` 照闪。

节奏、上限、开关都在文件顶部：

```cpp
#define LED_CMD_FLASH       1     // 0 = 关掉闪灯，灯只表示链路状态
#define LED_CMD_ON_MS       45    // 每下亮多久
#define LED_CMD_GAP_MS      55    // 两下之间灭多久（灭的时候露出底色）
#define LED_CMD_MAX_BLINKS  6     // 一次最多连闪几下：连发按键时排队累加，到顶就不再叠加
```

闪灯是**非阻塞**的：`processCommand()` 里只改状态，真正的亮灭由 `loop()` 里每 2ms
一次的 `ledFlashTick()` 推进。因为那条执行路径上有大量 `delay()`（按键保持 24ms、
逐字输入的字间隔、鼠标 click 的 40ms、开机连发引导键的 220ms），在那里阻塞闪灯会把
命令排队、鼠标拖卡。

**Wi-Fi 参数**（文件顶部可改）：

```cpp
#define AP_SSID "ESP32-Keyboard"   // 热点名，和蓝牙设备名一致
#define AP_PASS "esp32keyboard"    // 少于 8 位会自动变成开放热点
#define TCP_PORT 8266              // 客户端连的端口
```

### 8. 开机引导键（进 BIOS / UEFI）

**问题**：主机自检时，BLE/WiFi 一条都没连上，客户端根本发不出按键。所以「开机按 Del 进 BIOS」
这件事，靠客户端按键天然做不到——按键到达时 BIOS 早就跳过那个窗口了。

**做法**：固件自己在 USB 枚举完成后连发一个引导键，完全不依赖链路。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `BOOTKEY_DEFAULT` | `KT_KEY_DELETE` | 连发哪个键，可改 `KT_KEY_F2` / `KT_KEY_F10` / `KT_KEY_F12` |
| `BOOTKEY_HOLD_MS` | 80 | 单次按下持续时间。UEFI 的轮询比 Windows 慢（有的 16ms），太短会整次采不到 |
| `BOOTKEY_GAP_MS` | 220 | 两次之间的默认间隔（客户端可改，60~5000ms） |
| `BOOTKEY_WINDOW_MS` | 10000 | 连发多久的默认值（客户端可改，1~60 秒） |
| `BOOTKEY_START_MS` | 1500 | 上电后等多久开始（等 USB 枚举完） |

运行时改（都写进 NVS，掉电保持，不用重新烧录）：

```
BOOTKEY:delete        // 设成 Del
BOOTKEY:f2            // 设成 F2
BOOTKEY:off           // 关掉
BOOTKEY:now           // 立刻重来一轮
BOOTKEY:?             // 查询（回 BOOTKEY:<键> 和 BOOTCFG: 两行）
BOOTKEY:window 8000   // 连发时长 8 秒（1000~60000）
BOOTKEY:gap 300       // 连发间隔 300ms（60~5000）
BOOTKEY:now 8000 300  // 立即连发，并顺手把这两个值写进去
```

参数两种写法都收（`BOOTKEY:window=8000` 等价）。超出范围的值会被夹到区间边界，
不会报错——客户端手滑输 999999 也只是变成 60 秒。

**回执为什么是两条**：`BOOTKEY:<键>` 只有键名，是给老客户端看的（它们把 `BOOTKEY:`
后面整段当键名）；完整参数走单独的 `BOOTCFG:key=delete,win=10000,gap=220,hold=80`，
老客户端不认这条，只会把它当未知回执丢进日志，不会显示成乱码。

客户端「BIOS 启动键」那张卡片就是这些命令的按钮：F1~F12 全给（各家主板进设置的键不一样），
两个数字框改时长和间隔，「立即连发」会一次带上参数，`BOOTCFG:` 回来后把控件同步成固件里的真值。

**「关闭」是怎么记住的**：NVS 里 `bootkey` 有两种状态必须分开——「从没写过」（用宏里的
出厂默认 `delete`）和「写成了 0」（明确关闭）。固件用 `prefs.isKey()` 判有没有记录，
读到 0 就一次也不敲；写完立刻回读比对，写不进去（分区满 / 只读）会回一条 `[WARN]` 让客户端
显出来。这个区分很重要：早先版本用 `getChar("bootkey", -1)` + `>= 0` 判断，逻辑虽对但语义
含糊，一旦有别的路径写了脏值就会退回到「出厂默认 delete」，表现就是关闭失效。

**客户端不再自己猜**（这是「设了关闭，开机还是敲键」最真实的成因）：界面里引导键的默认值是
`delete`，而「写入固件」是把界面上的值原样发过去。用户在上一轮设成关闭、下一轮只想改连发
时长时顺手点了一次写入，板子就被悄悄改回 delete。现在两处都堵上了——选择存本地（Swift 是
`UserDefaults` 的 `ui.biosKey`，Python 是 `ui.json` 的 `bios_key`），并且每次连上都自动发一次
`BOOTKEY:?`，以固件回报的真值为准；固件若只回 `BOOTKEY:` 不回 `BOOTCFG:`，日志里会明确写
「旧固件，键位能用但改不了连发节奏」。

**只在上电（冷启动）时才连发**：固件读 `esp_reset_reason()`，只有 `ESP_RST_POWERON`
才开窗口。重新烧录、按板子上的复位键都不会触发，免得连着正在跑的 Windows 时
突然刷一串 Del 把人家文档删了。另外只要有命令从客户端进来，连发立即停止。

**仍然进不去 BIOS 的话，按顺序查**：

1. 板子是不是接在**主机**的 USB 口上（不是接在这台 Mac 上）。键盘只对它插的那台机器有效
2. 开机时板子有没有断电重启。板子一直供电的话，PC 重启它不会重新枚举，`esp_reset_reason`
   也不会是 `POWERON` —— 这种情况用客户端点「立即连发」，或者把板子拔了重插
3. 换 `BOOTKEY:f2` 试试，不同主板进设置的键不一样（Del / F2 / F10 / F12 / Esc）
4. 老主板（纯 Legacy BIOS，2010 年以前）只认 boot protocol 的 8 字节报告，而 Arduino
   ESP32 核心的 HID 描述符带 Report ID（9 字节）。这类机器上键盘能打字但 BIOS 不认，
   属于核心库限制，要改核心或自己写 HID 描述符

### 9. Windows 键盘兼容性

被控主机是 Windows 时，有三件事和 macOS 不一样，固件与客户端都做了对应处理：

**① 修饰键必须"真按下"，不能一次性拼成组合键**

以前客户端把「Ctrl+Space」压成一条 `COMBO:ctrl+space` 发过去。这个做法对
`Ctrl+C` 这种没问题，但对下面这些**纯修饰键或需要时序**的操作完全失效：

- `Ctrl+Shift`（切换键盘布局）——两个都是修饰键，以前一个都不会发出去
- 单按一下 `Shift`（微软拼音默认的中英切换）——同上
- `Win+Space` 先按 Win 再按 Space——组合键是一次性合成的，不是真实时序

现在改成**镜像**：`flagsChanged` 不再吞掉，修饰键单独 `DOWN:lshift` / `UP:lshift`；
普通键也单独 `DOWN:` / `UP:`。主机收到的就是一把真键盘的时序。

| 操作 | 之前 | 现在发出的 |
| --- | --- | --- |
| Ctrl+Shift | 什么都不发 | `DOWN:lctrl` `DOWN:lshift` `UP:lshift` `UP:lctrl` |
| 单按 Shift | 什么都不发 | `DOWN:lshift` `UP:lshift` |
| Win+Space | `COMBO:cmd+space` | `DOWN:lcmd` `DOWN:space` `UP:space` `UP:lcmd` |
| 按住 Shift 连打 | 每个字符重新按一遍 | 只发一次 `DOWN:lshift` |

配套的三处细节：

- 长按产生的自动重复（`keyboardEventAutorepeat`）**不转发**，键一直按着，让 Windows 自己连发。
  否则每个重复都重新按一次，输入法会乱
- 修饰键每次事件都按当时的 `flags` 全量对齐，丢一个 `keyUp` 也能在下一个事件自愈
- 开始/停止捕获、事件 tap 被系统关掉时，都补发一次 `RELEASEALL`，不会在主机上留一个卡住的 Ctrl

**② 固件侧不能用 `Keyboard.press/release` 处理修饰键**

Arduino 的 `release()` 在遇到大写字母或符号时会把左 Shift 位一起清掉。既然客户端会
单独发 `DOWN:shift`，就必须绕开它：固件自己把 `KT_*` 键码换算成 HID usage，走
`pressRaw/releaseRaw`（`0x80..0x87` → `0xE0..0xE7`，`>=0x88` → 减 `0x88`）。
只有 ASCII 仍然交给库查表。

**③ 键位补齐**

| 补了什么 | 说明 |
| --- | --- |
| `F13`~`F24` | HID usage 从 0x68 起（和 F1~F12 的 0x3A 不连续），Mac 的 F13–F20 现在能正确落到 Windows |
| `menu` / `apps` | Application 键（右键菜单） |
| `lcmd` / `rcmd` / `lwin` / `rwin` | 左右 Win 键 |
| `printscreen` / `scrolllock` / `pause` / `numlock` | 原来就有，客户端预设里可直接点 |

**Windows 上的换键对照**：客户端里 `⌘` 发出去就是 **Win 键**。所以
`⌘Space` = `Win+Space`（Windows 11 切换输入法），`⌘D` = `Win+D`。快捷键区顶部的
`Windows / macOS` 开关会把预设换成对应系统的一套（复制粘贴用 Ctrl，切换窗口用 Alt+Tab，
任务管理器 Ctrl+Shift+Esc，截图 Win+Shift+S 等）。

**④ 主机锁定键状态**

固件注册了 `ARDUINO_USB_HID_KEYBOARD_LED_EVENT`，把主机下发的 LED 状态记下来，
`PING` 的回执是 `PONG:<毫秒>,leds=<位图>`，其中 `1 = NumLock, 2 = CapsLock, 4 = ScrollLock`。

> ⚠️ 加了 Wi-Fi 之后固件 **1.17 MB，默认分区已用 89%**（`1,166,743 / 1,310,720` 字节）。
> 还能烧，但没有余量了：要在 Arduino IDE 里把 **工具 → Partition Scheme** 改成
> `8M Flash (3MB APP/1.5MB SPIFFS)` 或 `Huge APP (3MB No OTA)`，后面加功能才不会超。
> Flash 只有 4 MB 的板子选 `Default 4MB with spiffs` 也能跑，但别再往里加东西。

---

## 二、MacBook 端

### 1. 安装依赖

```bash
cd mac_client
python3 -m pip install -r requirements.txt
```

- `bleak`：蓝牙链路，macOS 上走 CoreBluetooth，无需额外驱动。
- `pyobjc-framework-Quartz` / `pyobjc-framework-ApplicationServices`：**可选**，只给
  「本机键盘转发」用（CGEventTap）。不装也能用屏幕键盘、鼠标、快捷键，只是点
  「开始捕获」会提示缺少 pyobjc。

### 2. 启动方式（重要，别直接用 python3 跑）

**推荐：双击项目根目录的 `ESP32Keyboard.app`。**

macOS 的 TCC 隐私机制要求：访问蓝牙的进程，其所属 App 必须在 `Info.plist` 里声明
`NSBluetoothAlwaysUsageDescription`。直接在终端里 `python3 ble_keyboard_client.py` 时，
系统认定的「责任进程」是终端或 IDE，而 **Terminal.app、iTerm、WorkBuddy 都没有这个声明**，
于是系统不再弹授权框，而是直接 `SIGKILL` 杀掉进程——你看到的现象就是点「连接」后窗口一闪就退，
崩溃报告里写着：

```
TCC: This app has crashed because it attempted to access privacy-sensitive data
without a usage description.
```

所以必须让「责任进程」变成我们自己的 App。`ESP32Keyboard.app` 就是干这个的：
它带 `NSBluetoothAlwaysUsageDescription`，里面 exec 你的 Python 解释器。

如果 app 不存在、或你换了 Python 版本，重新生成：

```bash
cd mac_client
./build_app.sh
```

脚本会自动检测 `python3` 是否装了 bleak；要指定解释器就：

```bash
PYTHON_BIN=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 ./build_app.sh
```

首次点「连接」会弹「ESP32Keyboard 想使用蓝牙」，点**允许**即可（只需一次）。
程序里也做了权限预探测：万一你还是在终端里直接跑，它会明确告诉你原因并退出，
不会再出现「窗口无故消失」。

要打一个可以发给别人的压缩包（含 App、源码、依赖清单、使用说明）：

```bash
cd mac_client
./package_app.sh            # → dist/ESP32Keyboard-Python-1.2.0.zip
```

### 3. 界面功能（与 Swift 版对齐）

顶部两行：第一行选链路（**蓝牙 / Wi-Fi**）和地址，第二行是「连接 / 停止 / 断开 / 释放全部按键」
加状态灯、状态文字、倒计时进度条，最右端是「外观」切换。

- **双链路**：和固件的 BOOT 键切换对应。蓝牙用设备名找；Wi-Fi 连板子热点里的
  `192.168.4.1:8266`（先让笔记本连上热点 `ESP32-Keyboard`，密码 `esp32keyboard`）。
- **连接有反馈**：扫描 / 连接分别有超时（蓝牙 12s 扫描、20s 建链；Wi-Fi 12s），
  进度条会显示剩余秒数，失败自动重试 2 次；任何阶段都能点「停止」立刻中止，
  不会卡在无限扫描里。
- **文字**：输入字符串，点「输入」或「输入+回车」，走 `TYPE:` 命令，一次发一整段。
- **常用快捷键**：`macOS / Windows` 两页预设。Windows 那页含切换输入法（Win+Space）、
  中英切换（Ctrl+Space）、单按 Shift、布局切换（Ctrl+Shift）、任务管理器、
  Win+D/E/R/I/L、Win+Shift+S 等，走 `COMBO:`。
- **BIOS 启动键**：**Del / Esc / F1~F12 / 关闭**，8 列网格，和 Swift 版同一份清单
  （各家主板进设置的那个键不统一，干脆全给出来）。点一下只是「选中」，
  再点「写入固件」才把键位 + 连发时长 + 连发间隔三条一起写进 NVS（掉电保持），
  不会因为手滑点错就把板子改成连发别的键。另有「立即连发」
  （`BOOTKEY:now <win> <gap>`，一次带参数，少一次往返）和「查询设置」。
  固件回 `BOOTCFG:key=…,win=…,gap=…,hold=…` 后，控件和底部那行灰字都按固件真值刷新
  ——始终以固件为准，客户端不自己记。
- **折叠**：BIOS 启动键 / 文字 / 常用快捷键三张卡点标题栏就收起，收起时标题右边
  留一句概要（`DELETE · 10 秒 / 220ms`、输入的文本前 22 个字符、`macOS 预设`）。
  状态存 `~/Library/Application Support/ESP32Keyboard/ui.json`（Windows 是
  `%APPDATA%\ESP32Keyboard\ui.json`），下次打开还是那个样子。
  收起来用的是 `pack_forget` 而不是 `destroy`，所以展开回来输入框内容和日志都还在。
- **外观**：启动时读系统明暗（macOS `defaults read -g AppleInterfaceStyle`，
  Windows 注册表 `AppsUseLightTheme`），两套调色板二选一；顶栏「外观」按钮可以在
  **跟随系统 → 浅色 → 深色** 之间循环，点了当场换色（`retint()` 按控件 role 重刷，
  不重建界面），选择也会记住。配色和 `mac_swift/Sources/Theme.swift` 是同一组色值。
- **鼠标**：左边一块拖拽区（按住拖动 = 移指针，速度 0.5×–4×），右边左/中/右三键
  （按下发 `MOUSE:down`、松手发 `MOUSE:up`）、滚轮 ↑↓、以及「按住左键」——
  要框选或拖文件时先锁住主机左键，再拖拖拽区。位移按 30Hz 攒批发送，
  超过 ±127 自动拆包，不会被 HID 的 int8 截断。
- **本机键盘转发**：「开始捕获」后本机按键被吞掉、原样转给主机，修饰键按 flags 全量镜像，
  所以 Windows 上 Shift、Ctrl+Space、Win+Space 这些纯修饰键操作也能生效。
  **⌃⇧E**（或 ⌃⌥Esc）紧急停止。未映射的键会放行给本机而不是吞掉。
  这条需要 pyobjc + 「辅助功能」授权。
- **屏幕键盘**：完整 QWERTY + 方向键 + 空格。
  - `⇧ ⌥ ⌘ ctrl` 是**粘滞键**：点一下高亮，再按任意普通键会发送组合并自动松开修饰键
    （松手之后再松修饰键，组合才不会被拆散）。
  - 一次点击 = `DOWN:` + 30ms + `UP:`，**和「开始捕获」走的是同一条发送路径**，
    而不是让固件自己 `TAP:`。两条路各走各的曾经导致「捕获能打字母、屏幕键盘点了没反应」。
    连续快点时会自动排队（每次敲击都完整，不会粘成一个长按）。
  - 未连接时点击不会发出按键，日志里会写「未连接，刚才的按键没有发出去」。
- **日志**：显示固件回执（`PONG:…`、`BOOTKEY:…`）、错误和连接阶段变化，最新 400 行。
- **释放全部按键**：任何情况下按键卡住，点它（或断开连接）会发 `RELEASEALL` 并松开鼠标键。

### 4. 命令行模式

不想开 GUI 或想接脚本时：

```bash
python3 ble_keyboard_client.py --cli                     # 蓝牙
python3 ble_keyboard_client.py --cli --mode wifi         # Wi-Fi（默认 192.168.4.1:8266）
python3 ble_keyboard_client.py --cli --mode wifi --host 192.168.4.1 --port 8266
```

连上后逐行输入协议命令（见下表），适合调试；固件回执也会打印出来。
注意蓝牙模式同样受上面的 TCC 限制：只有在「有蓝牙声明的 App 的终端里」运行才不会被杀
（例如 VS Code 的集成终端）。被拦时它会打印原因并以退出码 1 结束，不会静默崩溃。
Wi-Fi 模式不需要蓝牙权限，在终端里直接跑没问题。

---

## 三、Swift 版客户端（原生界面 + 本机键盘转发）

`ESP32KeyboardSwift.app`：SwiftUI 重写，界面是原生控件，浅色/深色自动跟随。
**最大的区别是能用 Mac 自己的键盘**——不只是点屏幕键盘。

### 构建

```bash
./mac_swift/build.sh          # 产出 ESP32KeyboardSwift.app
open ESP32KeyboardSwift.app
```

需要 Xcode（你机器上是 27.1 / Swift 6.4，够用）。没有 Xcode 就用 Python 版。

### 链路模式：蓝牙 / Wi-Fi

顶栏最右边有 **蓝牙 / Wi-Fi** 分段开关，必须和板子上 BOOT 键选的那一档一致
（认灯色最快：蓝/紫 = 蓝牙，绿/黄 = Wi-Fi）。切模式前请先断开当前连接。

**蓝牙模式**：设备名填固件里的 `DEVICE_NAME`（默认 `ESP32-Keyboard`），点连接。
扫描 12 秒、连接 10 秒、服务发现 8 秒，每阶段都有倒计时、进度条和「停止」按钮。

**Wi-Fi 模式**（板子是 AP，电脑当客户端）：

1. 在 macOS 的 Wi-Fi 菜单里连热点 `ESP32-Keyboard`，密码 `esp32keyboard`
   （客户端会显示这两个值，旁边有复制按钮和「打开 Wi-Fi 设置」）
2. 回 App 切到 `Wi-Fi`，地址默认 `192.168.4.1:8266`，点连接
3. 状态点变绿、显示 `192.168.4.1:8266` 即链路就绪，之后用法和蓝牙完全一样

> 为什么不让 App 自动连热点？`networksetup` 加入网络在多数 macOS 版本上要管理员权限，
> 弹密码框比自己点一下 Wi-Fi 菜单更烦，所以这里只把 SSID/密码摆出来一键复制。
> 板子自己也会把 IP 和端口打在串口日志里（115200）。

TCP 握手超时 6 秒，失败会自动重试 2 次；断线后会和蓝牙一样自动重连。

### 配色：跟随系统明暗 + 青紫强调

全部颜色集中在 `Theme.swift` 的 `Palette` 里，视图只引用名字，不再各写各的
`Color(nsColor: .controlBackgroundColor)`。

**为什么能跟随系统**：每个颜色都用 `NSColor(name:dynamicProvider:)` 打包成「浅色值 + 深色值」，
由 AppKit 按当前外观挑，不用在视图里到处读 `@Environment(\.colorScheme)`，
也就不会出现「某个角落忘了适配深色」。项目没有 Xcode 工程（`swiftc Sources/*.swift` 直接编），
用不了 Asset Catalog，动态 NSColor 正好是纯代码能做的等价物。

| 用途 | 浅色 | 深色 |
| --- | --- | --- |
| 强调色（标题图标、选中键、进度条） | `#0E8CA6` 青 | `#3BE0FF` 亮青 |
| 强调色另一端 | `#6C5CE7` 紫 | `#B18CFF` 亮紫 |
| 窗口底 / 卡片上沿 / 卡片下沿 | `#ECEFF7` / `#FFFFFF` / `#FAFBFE` | `#0D0F14` / `#1C2029` / `#171A22` |
| 凹槽（拖拽区、日志） | `#E6EAF3` | `#080A0E` |
| 已连接 / 进行中 / 警告 / 出错 | `#0F9D74` / `#7C5CF0` / `#B9770A` / `#D93F45` | `#3BE0A8` / `#A98BFF` / `#FFC15E` / `#FF7B7B` |

三个值得记下来的决定：

1. **按钮色比装饰色深一档**（`brandButton`，深色下 `#1A8FA8` 而不是 `#3BE0FF`）。
   `borderedProminent` 的前景色由系统定，深色主题的亮青底上它仍然给白字，白字压亮青看不清。
   装饰性的青可以亮（上面没有字），按钮的底必须暗。
   同理有 `onBrand`：压在品牌色块上的文字，深色主题下是近黑的冷色而不是白色。
2. **深色主题下凹槽要比窗口底更暗**（`well` 比 `canvas` 暗）。一开始两者都很暗、只差一点点，
   结果底部日志条和窗口背景连成一片，看不出那是一条独立区域。
3. **分段控件自己画**（`BrandSegmented`）。`NSSegmentedControl` 的选中块跟的是**系统强调色**，
   SwiftUI 的 `.tint()` 对它不生效，青紫配色里会突兀地冒出一块系统蓝。自绘版本还能精确控制段宽，
   两段等宽、总宽可预测（顶栏那个槽位原来就是 116pt）。

卡片统一走 `cardSurface()` 修饰符：上下渐变填充、一层极淡的青紫斜向微光（浓度 0.10 → 0，
目的是「有点颜色」而不是「一眼看出是渐变」）、1pt 描边、柔和投影。
投影挂在圆角形状上而不是视图上，否则圆角外会多一圈方影。

### 界面：可折叠的三张卡片 + 完整 F1~F12

页面从上到下依次是：连接卡、本机键盘转发、**BIOS 启动键**、**文字**、**常用快捷键**、
屏幕键盘 + 鼠标。后四块里前三块不是每次都用，堆在一起页面就很长，所以给这三张卡片加了折叠：
- 点标题栏任意位置收起 / 展开（右边的小箭头会转 90°，收起时朝右）；
- **收起时标题右边会留一句概要**（`DEL · 10 秒 / 220ms`、当前文字、`Windows 预设`），
  所以折叠不等于「什么都看不见」；
- 状态记在 `UserDefaults`（`ui.collapsedSections`），下次打开还是收着的样子。

「本机键盘转发」是横跨整窗的一条工具栏：**「开始捕获」紧跟标题靠左**（以前排在整条的最右端，
中间隔着大半屏空白，点它之前眼睛得先扫一圈），权限胶囊和「去授权 / 重新检测」留在右边。

### 菜单栏常驻：捕获的第二条出口

菜单栏上常驻一个图标（`App.swift` 里的 `MenuBarExtra` + `MenuBar.swift`），
平时是键盘符号，**捕获中换成录制圆点**，点开是这些：

| 菜单项 | 说明 |
|---|---|
| 链路：… / 捕获：… | 两行只读状态，打开就知道通没通、有没有在吞键盘 |
| 开始捕获 / 停止捕获 | 和主窗口那个按钮是同一件事 |
| 释放全部按键 | 发一条 `RELEASEALL`，对付主机上卡住的修饰键 |
| 去授权（辅助功能）… | **只在没授权时出现**，省得为了点它把窗口找回来 |
| 显示主窗口 / 退出 | 关掉窗口后还能把窗口叫回来 |

为什么要这个入口：捕获期间本机键盘被整体接管，主窗口的「停止捕获」只能用鼠标点，
而窗口一旦被盖住、最小化或关掉（关窗口不退进程），键盘又不响应，就真的没有出口了。
菜单栏图标浮在最上层、鼠标永远点得到，等于给捕获留了一条随时可用的退路。

两个实现细节：

- **图标靠换符号表达状态，不靠换颜色**。菜单栏图标是模板渲染（系统只取形状，
  颜色随亮/暗菜单栏走），上色没用；所以捕获中换成 `record.circle`。
- **标签视图自己订阅 `forwarder`**（`StatusBarLabel` 里挂 `@ObservedObject`）：
  菜单栏项由系统托管，把观察放在标签视图内部最稳，不依赖 `App.body` 重新求值时顺手换图标。

已知取舍：捕获期间菜单里的键盘导航（方向键 / Esc / 回车）也会被 tap 吞掉 ——
事件在到达菜单之前就被拦下了，用鼠标点即可。另外从菜单栏「退出」时进程会直接结束，
`KeyForwarder` 监听 `NSApplication.willTerminateNotification` 先走一遍 `stop()`，
尽量把还按着的键松开（表现上聊胜于无：进程一结束 tap 就没了）。

BIOS 那一块的几个改动：

1. **键位从分段控件换成网格，F1~F12 全部给出**。分段控件塞不下 15 个键：
   `NSSegmentedControl` 不会压缩段内文字，段一多就互相叠着挤出卡片边界（上一版只有 8 段就已经
   逼近极限）。网格还有一层好处——点一下只是「选中」，真正写进固件要再按一次按钮，不会误触。
   键帽**定宽 52pt**、不跟着窗口拉伸：卡片是整窗宽（≥1000pt），8 个弹性列每个会被撑到 100pt
   以上，一排又宽又扁，看着像主按钮而不是键帽。定宽之后键区只占 456pt，右边空出来的地方放
   「连发时长 / 间隔」和三个操作按钮（左右两栏），卡片反倒矮了一截。
2. **连发时长 / 间隔可调**。板子上电后在 POST 阶段自己连发引导键，节奏原本写死在
   `BOOTKEY_WINDOW_MS` / `BOOTKEY_GAP_MS` 两个宏里，现在改成运行时值、存 NVS：

   | 控件 | 范围 | 对应命令 |
   | --- | --- | --- |
   | 连发时长 | 1~60 秒 | `BOOTKEY:window <ms>` |
   | 连发间隔 | 60~5000 ms | `BOOTKEY:gap <ms>` |

   「立即连发」发的是 `BOOTKEY:now <win> <gap>`，一次带参数：少一次往返，也不会出现
   「点了立即连发但板子用的是旧值」的错觉。固件回 `BOOTCFG:` 之后，控件会被同步成固件里的真值
   （以固件为准，客户端不自己记一套）。

### App 图标

图标来自根目录的 `app_icon.png`。`build.sh` 发现 `Resources/AppIcon.icns` 不存在会
自动调用 `make_icon.sh` 生成；换了图之后手动跑一次再编译：

```bash
./mac_swift/make_icon.sh            # 用 ../app_icon.png
./mac_swift/make_icon.sh 别的图.png  # 换一张
```

它会先把图居中裁成正方形、按 macOS 的比例做圆角（内容区约占 80%，圆角半径 22.4%）
和四周留白，再输出 16~1024 共 10 个尺寸。**直接 `sips` 缩图不行**——Dock 里会是一块
方方正正的图片，边缘也没有圆角。生成后如果 Finder 还显示旧图标，是图标缓存的问题，
把 App 换个位置或 `killall Dock` 即可。

### 连接过程的状态提示

点「连接」之后顶栏会立刻变成进行中状态，不会出现「按钮变黑、不知道在干什么」：

| 位置 | 表现 |
|---|---|
| 左侧指示 | 原点变成**橙色转圈**（自绘，11pt） |
| 标题 | 「扫描中…」/「连接中…」，橙色 |
| 副标题 | `正在搜索 “ESP32-Keyboard” · 还剩 9 秒，可随时停止` |
| 底部细条 | 橙色进度条，按本阶段超时进度走（扫描 12s / 连接 10s / 服务发现 8s） |
| 右侧按钮 | 变成红色 **停止** 按钮，点一下立即中止，不用等超时 |

连上后按钮变成「断开」，状态点变绿；失败时状态点变红并给出下一步提示。
进度条和转圈的数据来自 `BLEBridge` 的 `remainingSeconds` / `phaseSeconds`。

### 打包分发

```bash
./mac_swift/package.sh              # 产出 dist/ 下的 dmg + zip（arm64 + Intel 通用）
VERSION=1.1 ./mac_swift/package.sh  # 换版本号
NATIVE=1 ./mac_swift/package.sh     # 只打本机架构，体积小一半
```

| 文件 | 用途 |
|---|---|
| `dist/ESP32-远程键盘-1.0.dmg` | 2.1 MB，拖拽安装，内含 `使用说明.txt` |
| `dist/ESP32KeyboardSwift-1.0.zip` | 2.1 MB，备份/传输用（`ditto` 打包，签名不会失效） |

App 本身是 **universal**（arm64 + x86_64），Intel Mac 也能跑，解压后 3.3 MB
（其中约 1.8 MB 是 1024px 的图标）。

**对方拿到 dmg 后**：双击打开 → 把 App 拖进 Applications → **右键点 App 选「打开」**。
第一次必须这样，因为没有公证，直接双击会被 Gatekeeper 拦成「无法验证的开发者」。

**两个限制**：

1. 没有 Apple 开发者证书，签名只能是本机自签证书（或 ad-hoc）。
   `codesign --verify` 是有效的，但经网络下载后一定会被 Gatekeeper 标记，
   需要右键打开绕过（或 `xattr -dr com.apple.quarantine`）。
2. **对方机器没有这个自签证书**，所以换机器、发给别人，授权还是要从头给一次。
   免重复授权是「同一台机器 + 同一个位置」才成立的事。

### 签名身份：为什么以前每次重编都要重新授权

macOS 的 TCC（隐私授权）记的是「哪个 App」。App 的身份由代码签名决定，而
ad-hoc 签名（`codesign -s -`）里唯一能标识它的只有 **cdhash**——每次重新编译都变。
系统于是认为「这是一个新 App」，于是：

- 系统设置里那条开关**还是勾着的**
- 但 `AXIsProcessTrusted()` 返回 `false`，点「重新检测」永远不变绿

`build.sh` 现在默认用固定证书签名，签名身份不再随编译变化。做法是先建一个自签名证书
（只需一次），之后的签名指定要求变成：

```
identifier "local.esp32keyboard.swift" and certificate leaf = H"5966ab01…"
```

**里面没有 cdhash**，只有 bundle id + 证书指纹。所以重编一百次，系统都认为还是同一个 App，
辅助功能和蓝牙授权一直有效。`build.sh` 每次都会把这一行打出来，可以自己确认。

```bash
./mac_swift/make_cert.sh      # 只跑一次：造证书（openssl 自签 → 专用钥匙串 → 免弹框 → 信任根）
./mac_swift/build.sh          # 之后每次编译自动认这张证书，不用再传 SIGN_IDENTITY
./mac_swift/build.sh --install  # 想固定装到 /Applications 时用（见下）
```

**为什么证书装在专用钥匙串里**（`~/Library/Keychains/esp32-signing.keychain-db`），
而不是登录钥匙串：`codesign` 读私钥时，如果私钥 ACL 没预放行，macOS 会弹一个
「codesign 想要访问钥匙串中的密钥」的授权框，等用户输密码。没有图形界面时
（CI、远程会话、脚本里跑）这个框根本不出现，`codesign` 就一直卡在
`replacing existing signature` 不动，等五分钟也不会自己好。

登录钥匙串的密码是用户登录密码，脚本无从得知，也就没法自动放行。专用钥匙串密码固定
（`esp32local`，只保护这张本地自签证书，不含别的凭据），`make_cert.sh` 里那句
`security set-key-partition-list` 把 codesign 写进私钥的 partition list，
`build.sh` 每次先 `unlock-keychain` 再签——全自动、不弹框。

**路径也要固定**。TCC 是「bundle id + 路径」一起记的：仓库根目录那份
`ESP32KeyboardSwift.app` 和 `/Applications` 那份会各存一条记录，两边混着启动，
就会被要求重新授权两次。挑一个位置用到底，要么仓库根目录，要么 `--install`。

### 首次运行要授权两次

1. **蓝牙**：弹出「想使用蓝牙」→ 允许。路径：系统设置 → 隐私与安全性 → 蓝牙
2. **辅助功能**：点「开始捕获」时提示没有权限 → 点界面里的「去授权」→
   在 隐私与安全性 → 辅助功能 里勾上「ESP32 远程键盘」→ 回到 App 点「重新检测」

> 从 ad-hoc 换成固定证书的**那一次**，还是得重新授权一次（旧记录是 ad-hoc 时期的，
> 和新身份对不上）。这一次之后就不用再授权了。

### 「明明授权了，重新检测还是未授权」

先确认 `codesign -d -r- ESP32KeyboardSwift.app` 打出来的指定要求里是
`certificate leaf = H"…"` 而不是 `cdhash H"…"`：

- 是 `cdhash` → 说明还在用 ad-hoc 签名，跑一次 `./mac_swift/make_cert.sh` 再编译
- 是 `certificate leaf` → 那就是 TCC 里存着一条旧记录（多半是 ad-hoc 时期留下的）

旧记录的处理顺序：

1. 点权限胶囊右边的 **重置按钮**（圆形箭头图标）→ 清除失效的旧授权记录
2. 点「去授权」，在列表里用 **+** 重新添加 `ESP32KeyboardSwift.app`
3. 回到 App 点「重新检测」

手动做法等价于：在辅助功能列表里选中「ESP32 远程键盘」，点 **—** 删掉，再点 **+** 加回来。
**仅仅把开关关掉再打开是没用的**，因为那条记录本身已经和当前签名对不上了。

### Python 版：依赖与授权

Python 版（`mac_client/`）功能已经和 Swift 版一致，但有一处差别要注意：

- **解释器换来换去，授权会丢。** 辅助功能是按「哪个程序在跑」授权的。用
  `python3 ble_keyboard_client.py` 直接跑时，被授权的是那个 python 解释器；
  换成 `.app` 启动，被授权的是 `.app` 里的同一个解释器路径——路径变了就要重新勾。
  固定用 `ESP32Keyboard.app` 启动最省事。
- **签名也是固定的**：`build_app.sh` 和 `build.sh` 共用
  `make_cert.sh` 造的那张自签证书（专用钥匙串 `esp32-signing.keychain-db`），
  所以重新打包不会掉蓝牙 / 辅助功能授权。两个 App 的 bundle id 不同
  （`local.esp32keyboard` / `local.esp32keyboard.swift`），在系统里是两条独立授权，
  各授权一次即可。没跑过 `make_cert.sh` 时会退回 ad-hoc 并在结尾明确警告。
- **提示缺少 pyobjc**：`python3 -m pip install -r mac_client/requirements.txt`。
  只有「本机键盘转发」需要它，屏幕键盘、鼠标、快捷键不受影响。
- **蓝牙仍然必须走 .app**：TCC 只认带 `NSBluetoothAlwaysUsageDescription` 的 App。
  Wi-Fi 模式不受这条限制，终端里直接跑也行。
- **`build_app.sh` 会把 python 路径写进启动脚本**。之后换 Python 版本（或删了那个
  venv / Homebrew Python），App 会改用 `command -v python3`，并在缺 bleak 时弹窗提示，
  而不是毫无反应地退出。
- **界面自测**：`python3 tools/test_python_ui.py` 不需要板子、也不需要真的连蓝牙，
  它把窗口建起来量控件（折叠省了多少高度、颜色对比度够不够、点击发的是哪条命令），
  改完界面跑一遍比肉眼快。

### 连接超时与取消

点「连接」后不会无限等下去：

| 阶段 | 超时 | 超时后 |
|---|---|---|
| 扫描设备 | 12 秒 | 停止扫描，状态变「没找到 “ESP32-Keyboard”」 |
| 建立连接 | 10 秒 | 断开重来，最多自动重试 2 次（间隔 1.5 秒） |
| 服务/特征发现 | 8 秒 | 同上 |

- 状态栏实时显示倒计时（如「扫描中… 9s」），能看见还剩多久
- 扫描/连接期间按钮变成「取消」，点一下立刻中止，不会卡住
- 意外掉线会自动重扫一次，同样受上面的超时约束
- 蓝牙栈刚启动的头 1~3 秒也会立刻显示「扫描中…」，不会出现点了没反应

超时参数在 `mac_swift/Sources/BLEBridge.swift` 末尾的 `Timing` 里，改完重新编译即可。

### 用本机键盘转发

1. 先连上 ESP32（状态点变绿）
2. 点「开始捕获」→ 之后在这台 Mac 上敲的键**不会打进本机**，全部发到被控主机
3. 停止：点「停止」、按 **⌃⇧E**（备用 **⌃⌥Esc**），或者点**菜单栏图标**里的「停止捕获」。
   后面这条是为「窗口被盖住 / 关掉了」准备的 —— 键盘已经不响应，只有鼠标还可靠。这两个组合永远优先处理，
   判断放在「同步修饰键」之前，所以哪怕键盘已经被吞掉也一定停得下来
4. 断开连接会自动停止捕获，不会让按键掉进黑洞

实现上用的是 `CGEventTap`（`cgSessionEventTap` / `headInsertEventTap`），
所以能真正**吞掉**按键；`NSEvent` 的全局监听只能旁观，按键仍会打进本机。

### 用鼠标（键盘 + 鼠标是同一个 USB 设备）

板子插一根线，主机同时认到「键盘」和「鼠标」。客户端里「鼠标」卡片在**屏幕键盘右边**
（两栏并排、等高），卡片内部是上下结构：上面一块大拖拽区管移动，下面三行是按键、滚轮、速度。

- **移动指针**：在上面那块拖拽区里按住拖动，位移会按速度倍率发给主机。
  拖到边缘松手、把手移回中间再拖一段即可（指针不会跑出窗口，这是有意的：
  不劫持本机光标，随时能把鼠标还给 Mac）。
- **左/中/右键**：按下就发 `MOUSE:down`，松手发 `MOUSE:up`，所以快速点一下 = 单击，
  按住不放 = 主机上一直按着。
- **框选 / 拖文件**：一只手没法同时按住按钮再拖拖拽区，所以用「按住左键」把主机左键
  **锁住**（按钮变橙），再拖拖拽区，完事点「松开左键」。右键菜单同理：点一下「右键」
  就是按下+松开一次。
- **滚轮**：`滚轮 ↑ / ↓` 每次 3 格（Windows 一格 = 3 行）。
- **速度**：0.5×~4×，默认 1.6×。位移是按 30Hz 攒批发出去的，
  甩得快时客户端会把超过 ±127 的部分自动拆成多条（HID 相对报告是 int8）。

掉线、切模式、停捕获时固件会自动松开所有鼠标键，不会留下「左键一直被按着」的状态。

### 一个设计取舍

**早期做法**：带修饰键时，每个按键都发成 `COMBO:shift+cmd+4` 这种完整组合，而不是
`DOWN:shift` … `UP:shift` 保持按住状态。原因是固件用的 Arduino HID 库在
`release()` 里会顺手清掉左 Shift 位，逐键 TAP 打一个需要 Shift 的字符后，
「按住」状态就丢了。

**现在的做法**：固件改走 `pressRaw/releaseRaw`（绕开库里那段清 Shift 的逻辑），
客户端就能安全地按真实时序镜像修饰键。于是 `Ctrl+Shift`、单按 `Shift`、
`Win+Space` 这些「纯修饰键」操作才发得出去——这是 Windows 上能切换输入法的前提。
详见「一、8. Windows 键盘兼容性」。

`COMBO:` 仍然保留，用在两处：**「常用快捷键」按钮**（一次发完整组合最省事）和
**粘滞键 + 普通键**（`⇧` 红着时点 `4`，发的是 `DOWN:4`，你手上按住的那几个修饰键
本来就已经在主机上按着了）。屏幕键盘的普通键现在也发 `DOWN:`/`UP:`，见「三、3」。

### 和 Python 版怎么选

| | Swift 版 | Python 版 |
|---|---|---|
| 界面 | 原生 SwiftUI（渐变卡片、青紫强调） | Tkinter（同色系，纯色代替渐变） |
| 本机键盘转发 | ✅ CGEventTap | ✅ macOS 走 pyobjc / Windows 走 WH 键盘钩子 |
| 依赖 | 无（自己就是 .app） | Python + bleak + tkinter（转发另需 pyobjc） |
| 命令行调试 | ❌ | ✅ `--cli` |
| 改造/调试难度 | 要改代码得重新编译 | 改完直接跑 |
| 界面自测 | 离屏渲染截图 | `tools/test_python_ui.py` 量控件 |

两个版本协议完全一致，可以随时换着用。排查链路问题时用 Python 版更省事。

---

## 四、通信协议

BLE 特征 `...def1`（RX）上按行写入 ASCII 文本，`\n` 结尾。单条命令建议 < 2048 字节。

| 命令 | 说明 | 示例 |
| --- | --- | --- |
| `TAP:<键>` | 按一下 | `TAP:enter` |
| `DOWN:<键>` | 按下并保持（修饰键也走这条） | `DOWN:lshift` |
| `UP:<键>` | 松开 | `UP:rctrl` |
| `TYPE:<文本>` | 逐字符输入 | `TYPE:hello world` |
| `COMBO:<键>+<键>...` | 组合键，依次按下再逆序松开 | `COMBO:cmd+shift+4` |
| `MEDIA:<名称>` | 多媒体键 | `MEDIA:volup` |
| `RELEASEALL` | 释放所有按键 | `RELEASEALL` |
| `PING` | 心跳，ESP32 回 `PONG:<millis>,leds=<位图>` | `PING` |
| `BOOTKEY:<键>` | 设置开机连发的引导键（写 NVS） | `BOOTKEY:f2` |
| `BOOTKEY:off` | 关掉开机连发 | `BOOTKEY:off` |
| `BOOTKEY:now` | 立刻重来一轮 | `BOOTKEY:now` |
| `BOOTKEY:?` | 查询当前的引导键 | `BOOTKEY:?` |
| `MOUSE:move <dx> <dy>` | 鼠标相对位移（单条 ±127） | `MOUSE:move 12 -7` |
| `MOUSE:wheel <n>` | 滚轮，正数向上 | `MOUSE:wheel 3` |
| `MOUSE:down <键>` | 鼠标按下（`left`/`right`/`middle`） | `MOUSE:down left` |
| `MOUSE:up <键>` | 鼠标松开 | `MOUSE:up left` |
| `MOUSE:click <键>` | 固件自己按下 40ms 再松开 | `MOUSE:click right` |
| `MOUSE:release` | 松开所有鼠标键 | `MOUSE:release` |

`PONG` 里的 `leds` 是主机下发的键盘灯状态：`1 = NumLock`、`2 = CapsLock`、`4 = ScrollLock`。

### 键盘和鼠标是同一个 USB 设备

固件同时挂着三个 HID 设备（`USBHIDKeyboard` / `USBHIDMouse` / `USBHIDConsumerControl`），
它们共用一个 USB HID 接口，用 **report ID** 区分（键盘 1、鼠标 2、多媒体 4）。
主机设备管理器里会多出一个「HID-compliant mouse」，插一根线两样都能用，
BIOS 阶段只看键盘那个 report，不受影响。

相对鼠标的 `dx/dy/wheel` 在 HID 报告里是 **int8**，一条最多 ±127；
客户端会给超过的部分拆成多条发，直接手写协议的话注意这一点。

### 支持的键名

- **单字符**：直接写字符本身，`a`、`A`、`1`、`/`、`-` 都行。
  大写字母和需要 Shift 的符号（如 `?`、`!`）由库自动补 Shift。
- **修饰键**：`ctrl` `lctrl` `rctrl` `shift` `lshift` `rshift` `alt` `option` `lalt` `ralt`
  `cmd` `command` `gui` `win` `lgui` `lcmd` `lwin` `rcmd` `rwin` `rgui`
- **编辑键**：`enter` `return` `esc` `tab` `space` `backspace` `delete` `del` `insert` `home` `end` `pageup` `pagedown`
- **方向键**：`up` `down` `left` `right`
- **其他**：`capslock` `menu` `apps` `printscreen` `scrolllock` `pause` `numlock`
- **功能键**：`f1` ~ `f24`
- **小键盘**：`kp0` ~ `kp9`、`kpenter` `kpplus` `kpminus` `kpslash` `kpasterisk` `kpdot`
- **媒体键**：`volup` `voldown` `mute` `playpause` `next` `prev` `brightnessup` `brightnessdown`

---

## 五、程序结构与代码导读

这一节讲代码怎么组织的，用之前不必读；想改代码、或者好奇「点一下按键到主机出字」中间发生了什么，看这里。

### 1. 一次按键走过的完整路径

```
本机键盘            屏幕键盘             鼠标拖拽区
CGEventTap 回调     Button 点击          DragGesture
（KeyForwarder）    （tapKey）           （padMove，30Hz 攒批）
      │                 │                    │
      └────────┬────────┴────────────────────┘
               ▼
        Command.down("a") / Command.mouseMove(12,-7)
               ▼  "DOWN:a\n"（一行 ASCII）
        LinkBridge.send()
               ├─ BLE：按 20 字节切片写特征 0x...def1
               └─ Wi-Fi：NWConnection 直接写
               ▼
        固件收字节 → 拼成一行（\n 分帧）→ pushCommand() 入队
               ▼  命令队列（互斥量保护，最多 256 条）
        loop() 每次取一条，串行执行 processCommand()
               ▼
        kt_parse() → KtPlan{动作, 键码…}
               ▼
        hwPress / hwRelease / doCombo / typeText / Mouse.move
               ▼  USB HID 报告（report ID 1=键盘 2=鼠标 4=多媒体）
        被控主机收到普通按键事件
```

**为什么中间要过一个命令队列**：HID 的按下/松开是有时序的（按住 24ms、组合键间隙 10ms），
如果在 BLE 回调里直接 `delay()` 执行，下一个回调可能在等待期间插进来，把键序打乱。
队列把「收」和「执行」解耦，执行侧永远是单线程串行的。这也是本项目最核心的一个结构决定。

### 2. 固件代码地图（`esp32s3_ble_keyboard.ino`，约 1690 行，单文件自包含）
| 行号 | 段落 | 干什么 |
| --- | --- | --- |
| 68–145 | 键码表 | 与核心 `USBHIDKeyboard.h` 的 `KEY_*` 一一对应，用 `static_assert` 做编译期交叉校验 |
| 146–171 | `KtAction` | 命令类型枚举：TAP / DOWN / UP / TYPE / COMBO / MEDIA / RELEASEALL / PING |
| 172–382 | 键名解析 | `"enter"`、`"f2"`、`"kp0"`、单字符 → 键码；大小写不敏感 |
| 383–510 | `kt_parse()` | 一行文本 → `KtPlan`（动作 + 键码数组 + 警告/错误） |
| 511–605 | 用户配置 | 设备名、GATT UUID、双链路参数、`LED_BRIGHTNESS` / `LED_CMD_*`、引导键默认值与可调范围、按键保持时长 |
| 606–632 | 编译期检查 | USB Mode 选错时给一句中文 `#error`，而不是让链接期报天书 |
| 633–665 | 全局对象 | `Keyboard` / `Mouse` / `Consumer` 三个 HID 设备（同一接口，report ID 区分） |
| 666–795 | 状态灯 | `ledSet` / `ledRefresh` / 上电自检 / 主机灯态回调 / **指令闪灯状态机**（`ledFlashCommand` + `ledFlashTick`） |
| 796–903 | 按键动作 | `hwPress` / `hwRelease`（绕开库清左 Shift 的行为）、`tapCode`、`typeText`、`doCombo`、`doMedia` |
| 904–969 | 开机引导键 | 冷启动判定 + 连发窗口状态机 + 运行时可改的 `bootKeyWindowMs` / `bootKeyGapMs` |
| 970–1137 | 命令分发 | `notifyHost()` / `notifyBootCfg()`、`pushCommand()` 入队、`handleBootKeyCommand()`（键位 / 时长 / 间隔 / 立即连发） |
| 1138–1252 | 鼠标 | `mouseClamp`、`handleMouseCommand`（move/wheel/down/up/click/release，鼠标键事件在这里触发闪灯） |
| 1253–1363 | `processCommand` | 按前缀分流：`bootkey:`、`mouse:` 截走，其余交给 `kt_parse`；执行完调用 `ledFlashCommand()`（`PING` 除外） |
| 1364–1510 | 链路 | `startBLE` / `stopBLE` / `startWiFi`（AP）/ `stopWiFi` / `serviceWiFi`（accept + 读行） |
| 1511–1573 | 模式切换 | `setMode()` 写 NVS、`pollButton()` BOOT 键消抖 |
| 1574–1688 | `setup` / `loop` | 初始化（含读回引导键参数）；主循环 = 按键轮询 → 引导键 → 链路维护 → 取一条命令执行 → `ledFlashTick()` → 刷灯 |

### 3. 客户端代码地图（`mac_swift/Sources`，约 2860 行）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `App.swift` | 21 | 入口，窗口最小 1000×620，注入两个 `ObservableObject` |
| `Theme.swift` | 241 | 品牌配色（跟随系统明暗的动态色）、卡片底 `CardSurface`、分段控件 `BrandSegmented`、渐变分隔线 |
| `ContentView.swift` | 1260 | 全部界面 + `UIState`（界面状态、折叠状态、鼠标位移攒批、拖拽锁）；`Card` 支持点标题栏折叠 |
| `LinkBridge.swift` | 735 | 双链路：`CBCentralManager` 扫描/连接/写特征，`NWConnection` 走 TCP；`LinkState` 状态机、三阶段超时、倒计时、日志、`tapKey` 串行化、`BOOTCFG` 回执解析 |
| `KeyForwarder.swift` | 265 | `CGEventTap` 抓本机键盘、修饰键全量镜像、开关捕获时补 `RELEASEALL`、TCC 授权检测 |
| `Protocol.swift` | 272 | `Command`（命令构造）、`BootConfig`（引导键参数）、`KeyMap`（kVK→键名）、`Layout`（键盘行 / 预设 / BIOS 键）、`ModifierMirror` |
| `MousePad.swift` | 69 | 拖拽手势（`DragGesture`）+ 鼠标键按下/松开捕捉（`PressCatcher`） |

三层分工很硬：**界面只负责产生 token**（`"a"`、`"ctrl"`、`"f2"`），**协议层只负责拼字符串**，
**链路层只负责把字符串送出去**。所以换界面、换传输方式都不用动协议。

### 4. 三个值得知道的设计决定

**① 界面不用 `@State`**
`@State`/`@Environment` 是 Swift 宏，需要 `swift-plugin-server`；本项目只用裸 `swiftc` 编译，
所以在 `UIState` / `LinkBridge` / `KeyForwarder` 里用 `ObservableObject` + `@Published` 手动管状态。
工程量差别很小，换来的是「一条命令就能编出 .app」。

**② 屏幕键盘和本机转发走同一条路**
两边都是 `DOWN → 30ms → UP`，而不是一个用固件的 `TAP:`、另一个用 DOWN/UP。
否则就会出现「捕获能用、屏幕键盘点了没反应」这种一半好一半坏的现象——这个坑真踩过。

**③ 鼠标位移在客户端攒批**
`padMove()` 按 30Hz 攒一次，超过 ±127 自动拆成多条。原因有两个：BLE 一次只写 20 字节，
60Hz 高频位移会把连接塞满、手感变粘；而 HID 相对报告的 `dx/dy` 是 int8，单条超 127 会被夹住丢位移。

---

## 六、常见问题

**点「连接」后窗口直接消失 / 程序自动退出**
- 这是 macOS TCC 杀进程，不是代码异常。看 `~/Library/Logs/DiagnosticReports/` 里最新的
  `Python*.ips`，`termination` 会写 `namespace: TCC` 和上面那段 usage description。
- 解决：用 `ESP32Keyboard.app` 启动（见「启动方式」）。不要直接 `python3 ble_keyboard_client.py`。
- 如果已经用了 app 还弹这个，通常是换了 Python 版本后没重新运行 `build_app.sh`。

**Mac 扫不到设备**
- 确认 ESP32 串口打印了「广播中」，且没被别的主机连着。
- 检查终端/编辑器的蓝牙权限。
- 设备名必须完全一致（区分大小写），或改 `--name` 参数。

**连上了，但被控主机没反应**
- 确认用的是 ESP32-S3 的**原生 USB 口**，不是 UART 口。
- 确认 USB Mode 是 `USB-OTG (TinyUSB)`。
- 换一根**能传数据**的 USB 线（很多线只能充电）。
- 主机端 `dmesg` / 设备管理器里应该能看到一个新的 HID 键盘。

**按键卡住**
- 点「释放全部按键」，或断开再重连。固件在 BLE 断开时也会自动 `releaseAll`。

**打出来的字符不对**
- HID 发的是**按键位置**，最终字符由被控主机的键盘布局决定。请把主机切成 **US 布局**，或自行修改 `Keyboard.begin(KeyboardLayout_xx_XX)`。

**中文输入**
- 这套方案只发按键，不处理输入法。要打中文得靠主机自己的输入法（先切到中文再 `TYPE:` 拼音），因为 HID 键盘本身也只能这么做。

**延迟**
- BLE 连接间隔 + HID 轮询，正常在 20~40ms。文字是整段发送的，长文本会有可感知的逐字输入时间（约 60 字/秒），这是 HID 轮询周期决定的，属于正常现象。

**想改成 WiFi 方案**
- 把 BLE 部分换成 `WiFi.softAP()` + `WiFiServer`，命令解析、按键映射这部分代码完全不用动，只是把「收到一行命令」的来源从 BLE 回调换成 TCP 连接。

### Swift 版专属

**点「开始捕获」没反应，提示没有权限**
- 需要「辅助功能」权限，不是蓝牙权限，两个是分开的。
- 系统设置 → 隐私与安全性 → 辅助功能，勾上「ESP32 远程键盘」；勾完有时代码不会立刻生效，退出 App 再开。
- 若列表里根本没有这个 App，点一下界面里的「打开设置」会把它带出来。

**重新编译后权限又要求重新授权**
- 说明这次是 ad-hoc 签名。用 `codesign -d -r- ESP32KeyboardSwift.app` 看一眼：
  指定要求里出现 `cdhash` 就是 ad-hoc，出现 `certificate leaf` 才是固定证书。
- 一次性解决：`./mac_swift/make_cert.sh`（只跑一次），之后 `./build.sh` 会自动用这张证书。
  换身份的那一次仍要重新授权，再往后重编都不用。
- 另外注意 App 的**路径**：仓库根目录那份和 `/Applications` 那份在 TCC 里是两条记录，
  混着启动会来回要授权。固定用其中一个（`./build.sh --install` 装到 /Applications 并启动）。

**开了捕获后键盘「失灵」了**
- 这是设计如此：按键被吞掉转发到被控主机，本机不再响应。
- 停止方式：点界面上的「停止」，或按 **⌃⇧E**（备用 ⌃⌥Esc）。
- 如果连窗口都点不到（比如切到别的 App 了），⌃⇧E 依然有效 —— 它的处理绕过转发逻辑。
- 为什么要两套：⌃⌥Esc 是 macOS 习惯，但某些远程桌面 / 输入法会先把它吃掉；
  ⌃⇧E 在键盘左上、左手一伸就到，作为第二条退路。

**设了「关闭」，板子开机还是敲键**

按这个顺序查，基本能在一步内定位：

1. 连上客户端点「查询设置」，看回执里 `key=` 是什么。若是 `key=off` 而板子还敲，
   那是板子跑的固件比当前源码旧（旧版本可能不认识 `BOOTKEY:off`，或者没有
   `isKey` 那套语义），用当前源码重新烧录一次即可。
2. 若回执里是 `key=delete`，说明「关闭」根本没写进去。看日志里有没有
   `[WARN] 引导键没写进 NVS` —— 有就是 NVS 写失败（分区满 / 只读）。
3. 若日志里连 `BOOTCFG:` 都没有，只有 `BOOTKEY:`，那是更老的固件：
   键位能用，但 `BOOTKEY:window` / `gap` 不认识，连发节奏改不了。
4. 还有一种最容易忽略的：**客户端把旧值写回去了**。界面上的引导键选择以前不存盘，
   重开 App 就回到 `delete`；这时哪怕只想改连发时长，点一次「写入固件」也会把关闭改回
   delete。现在的版本会存选择、连上后自动查一次真值，并把「这次写了什么」记进日志
   （`写入固件：off · 10 秒 / 220ms`），对照即可。

**屏幕键盘点了没反应（已修复）**
- 症状：鼠标点在键格里，只有正好戳在字母笔画的中间条带才有反应，其余位置全无响应。
- 原因：键上那层 `Text(...).frame(maxWidth: .infinity, minHeight: 30)` 只扩大了**布局**尺寸，
  SwiftUI 的点击判定仍然跟着文字本身走，所以 30pt 高的键格只有中间约 11pt 的横条是「活」的。
- 修法：在 label 里补一行 `.contentShape(Rectangle())`，让整格都进入命中区；同时点一下会闪
  120ms 高亮，未连接时也能看到「点了有反应」（命令会被丢弃并在日志里提示）。
- 同类坑：任何「小图标 + 大 frame」的自定义按钮都要 `contentShape`，否则点击区域只有图标那么大。

**未连接时点屏幕键盘会怎样**
- 按键会被丢弃（不会攒着，避免连上瞬间一次性灌给主机），日志里有一条红色提示。
- 所以调试顺序是：先点右上角「连接」，等状态变「已连接」，再点屏幕键盘。

**Swift 版能不能只转发某些键**
- 目前是全接管。想只转发特定组合（比如只转发 F13-F15 做快捷键）改 `KeyForwarder.handle` 里的判断即可。

## 七、许可

MIT License，见 [LICENSE](LICENSE)。商用、修改、再发布都可以，保留版权声明即可。

固件依赖 [arduino-esp32](https://github.com/espressif/arduino-esp32)（LGPL-2.1），
客户端使用 Apple 系统框架（CoreBluetooth / Network / ApplicationServices），
各自遵循其原有许可。
