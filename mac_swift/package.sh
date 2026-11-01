#!/usr/bin/env bash
# 把 Swift 客户端打包成可以直接发给别人 / 拖进 Applications 的安装包
#
#   用法：
#     ./mac_swift/package.sh                  # 默认打成 arm64 + Intel 通用版
#     VERSION=1.1 ./mac_swift/package.sh      # 指定版本号
#     NATIVE=1 ./mac_swift/package.sh         # 只打当前架构（体积小一半）
#
#   产出（都在 dist/ 下）：
#     ESP32-远程键盘-<版本>.dmg   拖拽安装，内含使用说明
#     ESP32KeyboardSwift-<版本>.zip  纯 app 备份/传输用
set -euo pipefail
cd "$(dirname "$0")"

NAME="ESP32KeyboardSwift"
VERSION="${VERSION:-1.0}"
export VERSION          # build.sh 要用它写进 Info.plist
ROOT="$(cd .. && pwd)"
APP="${ROOT}/${NAME}.app"
DIST="${ROOT}/dist"
LABEL="ESP32 远程键盘"

# 1. 构建
if [ "${NATIVE:-0}" = "1" ]; then
    ./build.sh
    ARCH_TAG="$(uname -m)"
else
    ./build.sh --universal
    ARCH_TAG="universal"
fi

mkdir -p "$DIST"
rm -f "${DIST}/ESP32-远程键盘-${VERSION}.dmg" \
      "${DIST}/${NAME}-${VERSION}.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# 卷根直接放 app，用户打开就能拖，不用再点进一层
cp -R "$APP" "${STAGE}/"

# 2. 使用说明（对方第一次打开一定会被 Gatekeeper 拦住，写清楚）
cat > "${STAGE}/使用说明.txt" <<TXT
${LABEL} ${VERSION}（${ARCH_TAG}）
----------------------------------------------

【第一次打开】
这个 App 没有 Apple 开发者签名、也没做公证（自用工具，没有付费账号），
直接双击会被系统拦下来。任选一种方式放行：

  方式一：右键点 App → 打开 → 弹窗里再点「打开」
  方式二：终端执行
          xattr -dr com.apple.quarantine "/Applications/${NAME}.app"

【第一次运行要授权两项】
1. 蓝牙 —— 弹窗点「允许」
   路径：系统设置 → 隐私与安全性 → 蓝牙

2. 辅助功能 —— 点「开始捕获」时若提示没权限，点「去授权」，
   在 系统设置 → 隐私与安全性 → 辅助功能 里勾选「${LABEL}」，
   然后回 App 点「重新检测」。
   （没有它就没法接管键盘，只能点屏幕键盘）

【两种链路：蓝牙 / Wi-Fi】
板子上短按 BOOT 键切换，App 顶栏的分段开关要选同一档。

  · 蓝牙：灯蓝=等连接，灯紫=已连上。设备名默认 ESP32-Keyboard
  · Wi-Fi：灯绿=等连接，灯黄=已连上。板子自己开热点：
        热点名  ESP32-Keyboard
        密码    esp32keyboard
        地址    192.168.4.1  端口 8266
    先把笔记本的 Wi-Fi 连到这个热点，再在 App 里切到 Wi-Fi、点连接。

【连接步骤】
1. ESP32-S3 插到被控主机的 USB 口（板子上的原生 OTG 口，不是调试口）
2. 被控主机应识别到一个 USB 键盘
3. 看板载灯判断当前模式：蓝/紫 = 蓝牙，绿/黄 = Wi-Fi
4. 蓝牙：App 选「蓝牙」，设备名保持 ESP32-Keyboard，点「连接」
   Wi-Fi：笔记本连上热点后，App 选「Wi-Fi」，地址 192.168.4.1:8266，点「连接」
5. 状态点变绿后点「开始捕获」，之后在这台 Mac 上敲的键会发到被控主机
6. 停止：点「停止捕获」，或按 ⌃⌥Esc（紧急出口，永远有效）

【连不上】
· 蓝牙：12 秒扫不到会自动停，顶栏有转圈 + 倒计时 + 橙色进度条，
  右边红色「停止」按钮随时可点，不用等超时
· Wi-Fi：6 秒连不上会自动重试 2 次；先确认笔记本真的连到了 ESP32-Keyboard 热点
· 检查板子上电、在 3 米内、固件里的设备名是否改成了别的
· 板载灯颜色就是模式指示：蓝=蓝牙待连，紫=蓝牙已连，绿=Wi-Fi 待连，黄=Wi-Fi 已连
· 下方日志会写明卡在哪一步（扫描 / 连接 / 服务发现 / TCP）

【点了屏幕键盘没反应】
· 1.0.1 起整块键格都能点中（旧版只有字母笔画那一小条是有效区域，
  点在键格的空白处等于没点，很容易被当成「按钮坏了」）
· 先看顶栏状态点是不是绿色。没连上时点屏幕键盘不会发任何东西，
  日志里会写「未连接，刚才的按键没有发出去」，这不是坏了
· 连上之后，屏幕键盘和「开始捕获」走的是同一条发送路径：
  一次点击 = 按下 + 30ms + 松开，和真键盘的一次敲击一样
· 日志显示已经发出、主机还是没反应，就看板载灯：
  紫色 / 黄色 = 链路已通，问题在主机侧（换个窗口、确认输入框有焦点）
  蓝色 / 绿色 = 只在等连接，键其实没进去

【开机进 BIOS】
主机自检时链路还没连上，App 发不出按键，所以让板子自己连发：
  App → 「BIOS 启动键」→ 选 Del / F2 / F10 / F12 / Esc → 点「写入固件」
写一次就存在板子里（掉电不丢），以后每次上电自动连发约 10 秒。
已经开着机、想再敲一次时点「立即连发」。
注意：只在「断电再来电」时自动连发；重新烧录或按复位键不触发，避免往
正在跑的 Windows 里灌 Del。

【在 Windows 上切换输入法】
App 里的 ⌘ 就是 Win 键，所以：
  ⌘Space  = Win+Space   ← Windows 11 默认切换输入法
  单按 ⇧   = 微软拼音中英切换
  ⌃⇧      = 切换键盘布局
快捷键区顶部有 Windows / macOS 开关，切到 Windows 就是 Ctrl+C / Alt+Tab 那一套。

【用鼠标】
板子插一根线，被控主机同时认到键盘和鼠标（同一个 USB 设备里的两个 HID 集合）。
「鼠标」卡片在屏幕键盘右边，上面是拖拽区、下面是按钮：
  · 移动：在上面拖拽区按住拖动。拖到边缘松手、把手移回中间再拖一段
  · 单击：快速点一下「左键」（按下+松开）
  · 框选 / 拖文件：先点「按住左键」（变橙色 = 主机左键被锁住），
    拖拖拽区，完事再点「松开左键」
  · 右键菜单：点「右键」一下
  · 滚轮：滚轮 ↑ / ↓，一次 3 格
  · 速度：0.5×~4× 可调，默认 1.6×（拖一次能走多远）
掉线、切模式都会自动松开所有鼠标键，不会卡在「左键按住」的状态。

【已知限制】
· 只发按键位置，不处理输入法候选；被控主机请用 US 布局
· 纯 Legacy BIOS（2010 年以前的老机器）只认 boot protocol 的 8 字节报告，
  Arduino 核心的 HID 描述符带 Report ID（9 字节），这类机器上 BIOS 可能不认；
  UEFI 机器（2012 年后）按描述符解析，没有这个问题
TXT

# 3. dmg（拖拽安装）
ln -s /Applications "${STAGE}/Applications"
echo "== 生成 dmg =="
hdiutil create \
    -volname "$LABEL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${DIST}/ESP32-远程键盘-${VERSION}.dmg" >/dev/null

# 4. zip（ditto 才能保留签名所需的扩展属性，别用 zip 命令）
echo "== 生成 zip =="
ditto -c -k --sequesterRsrc --keepParent "$APP" \
    "${DIST}/${NAME}-${VERSION}.zip"

echo ""
echo "== 完成 =="
ls -lh "$DIST" | tail -n +2
