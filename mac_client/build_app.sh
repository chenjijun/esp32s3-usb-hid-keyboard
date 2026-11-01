#!/bin/bash
# 生成 ESP32Keyboard.app
#
# 为什么需要它：macOS 的 TCC 要求「访问蓝牙的进程所属 App」在 Info.plist 里
# 声明 NSBluetoothAlwaysUsageDescription。直接 `python3 xxx.py` 时，责任进程是
# 终端 / IDE，它们没有这个声明，系统会直接把进程 SIGKILL（表现就是窗口一闪就退）。
# 把脚本装进一个带声明的 .app 里启动，责任进程就变成了这个 .app 自己。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../ESP32Keyboard.app"
PY="${PYTHON_BIN:-$(command -v python3 || true)}"
BUNDLE_ID="local.esp32keyboard"

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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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
cd "${HERE}"
exec "${PY}" "${HERE}/ble_keyboard_client.py" "\$@"
LAUNCH
chmod +x "$APP/Contents/MacOS/launch"

if ! codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
    echo "提示：ad-hoc 签名失败，本机运行一般仍然可用" >&2
fi

echo "已生成: $APP"
echo "双击它启动；第一次点「连接」时系统会弹蓝牙授权，点「允许」。"
