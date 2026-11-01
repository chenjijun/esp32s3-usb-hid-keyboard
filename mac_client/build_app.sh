#!/bin/bash
# 生成 ESP32Keyboard.app（Python 版客户端的启动壳）
#
# 为什么需要它：macOS 的 TCC 要求「访问蓝牙的进程所属 App」在 Info.plist 里
# 声明 NSBluetoothAlwaysUsageDescription。直接 `python3 xxx.py` 时，责任进程是
# 终端 / IDE，它们没有这个声明，系统会直接把进程 SIGKILL（表现就是窗口一闪就退）。
# 把脚本装进一个带声明的 .app 里启动，责任进程就变成了这个 .app 自己。
#
# 脚本本体被复制进 Contents/Resources/，所以生成出来的 .app 可以单独拷走。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="${APP_OUT:-$ROOT/ESP32Keyboard.app}"
PY="${PYTHON_BIN:-$(command -v python3 || true)}"
BUNDLE_ID="local.esp32keyboard"
VERSION="${VERSION:-1.2.1}"
# 启动脚本里写死哪个解释器：默认就是编译用的这个。
# 打成发布包时传 LAUNCH_PY=""，改成运行时自己找 python3（别人机器上路径不一样）。
LAUNCH_PY="${LAUNCH_PY-$PY}"

if [ -z "${PY}" ] || [ ! -x "${PY}" ]; then
    echo "找不到 python3，可用 PYTHON_BIN=/path/to/python3 ./build_app.sh 指定" >&2
    exit 1
fi

if ! "$PY" -c "import bleak" >/dev/null 2>&1; then
    echo "这个 Python 还没装 bleak：$PY" >&2
    echo "先执行：\"$PY\" -m pip install -r \"$HERE/requirements.txt\"" >&2
    exit 1
fi

echo "使用 Python: $PY"
if ! "$PY" -c "import Quartz" >/dev/null 2>&1; then
    echo "提示：这个 Python 没装 pyobjc，「本机键盘转发」会不可用（其余功能正常）"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$HERE/ble_keyboard_client.py" "$APP/Contents/Resources/ble_keyboard_client.py"

# 窗口图标（macOS 上窗口图标会被系统忽略，Dock 图标看 Info.plist；
# 这份 PNG 主要是给打包后的界面用的，Windows 版用同名 .ico）
if [ -f "$ROOT/app_icon_256.png" ]; then
    cp "$ROOT/app_icon_256.png" "$APP/Contents/Resources/app_icon_256.png"
fi

# 有 Swift 版的图标就复用，没有就算了
ICON_KEY=""
if [ -f "$ROOT/mac_swift/Resources/AppIcon.icns" ]; then
    cp "$ROOT/mac_swift/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ESP32Keyboard</string>
    <key>CFBundleDisplayName</key><string>ESP32 无线键盘</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>launch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
${ICON_KEY}
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>需要蓝牙与 ESP32-S3 无线键盘建立连接，用来接收你发送的按键。</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>需要蓝牙与 ESP32-S3 无线键盘建立连接，用来接收你发送的按键。</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/launch" <<LAUNCH
#!/bin/bash
# Finder 启动时 PATH 很短，所以先试编译时用的解释器，再用系统的兜底。
APP_DIR="\$(cd "\$(dirname "\$0")/../.." && pwd)"
SCRIPT="\$APP_DIR/Contents/Resources/ble_keyboard_client.py"

PY="${LAUNCH_PY}"
if [ -z "\$PY" ] || [ ! -x "\$PY" ]; then
    PY="\$(command -v python3 || true)"
fi
if [ -z "\$PY" ] || [ ! -x "\$PY" ]; then
    osascript -e 'display alert "找不到 python3" message "请安装 Python 3 后重新运行 build_app.sh。"' >/dev/null 2>&1
    exit 1
fi

if ! "\$PY" -c "import bleak" >/dev/null 2>&1; then
    osascript -e 'display alert "缺少 bleak 库" message "在终端执行：python3 -m pip install -r requirements.txt，装完再双击本 App。"' >/dev/null 2>&1
    exit 1
fi

exec "\$PY" "\$SCRIPT" "\$@"
LAUNCH
chmod +x "$APP/Contents/MacOS/launch"

if ! codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
    echo "提示：ad-hoc 签名失败，本机运行一般仍然可用" >&2
fi

echo "已生成: ${APP}（版本 ${VERSION}）"
echo "双击它启动；第一次点「连接」时系统会弹蓝牙授权，点「允许」。"
echo "要用「本机键盘转发」，还需在 系统设置 → 隐私与安全性 → 辅助功能 里勾选本 App。"
