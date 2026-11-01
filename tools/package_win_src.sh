#!/bin/bash
# 打 Windows 源码包：dist/ESP32Keyboard-Python-<版本>-windows.zip
#
# 为什么没有现成的 exe：PyInstaller 不能跨平台编译，Windows 的 exe 只能在
# Windows 上打。所以这里给出的是「源码 + 一键打包脚本」，Windows 用户装好
# Python 后双击 mac_client\build_win.bat 就能得到 ESP32Keyboard.exe。
#
#   ./tools/package_win_src.sh              # 版本 1.2.1
#   VERSION=1.2.2 ./tools/package_win_src.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${VERSION:-1.2.1}"
NAME="ESP32Keyboard-Python-$VERSION-windows"
STAGE="$ROOT/dist/$NAME"
ZIP="$ROOT/dist/$NAME.zip"

rm -rf "$STAGE"
mkdir -p "$STAGE/mac_client/windows"
cp "$ROOT/mac_client/ble_keyboard_client.py" "$STAGE/mac_client/"
cp "$ROOT/mac_client/requirements.txt" "$STAGE/mac_client/"
cp "$ROOT/mac_client/build_win.bat" "$STAGE/mac_client/"
cp "$ROOT/mac_client/windows/README.txt" "$STAGE/mac_client/windows/"
cp "$ROOT/app_icon.ico" "$ROOT/app_icon_256.png" "$STAGE/"

cat > "$STAGE/START-HERE.txt" <<'TXT'
ESP32 无线键盘 · Windows 版客户端
=================================

这里没有现成的 exe（Windows 的 exe 只能在 Windows 上打包），
但打包只要一条命令，脚本会自动装依赖。

  1. 装 Python 3.9 或更高版本（python.org 官方安装包，安装时勾选
     "Add python.exe to PATH"）
  2. 双击 mac_client\build_win.bat
  3. 等它跑完，用 dist_win\ESP32Keyboard\ESP32Keyboard.exe 启动

详细用法见 mac_client\windows\README.txt。
TXT

rm -f "$ZIP"
( cd "$ROOT/dist" && zip -r -X -q "$(basename "$ZIP")" "$NAME" )
rm -rf "$STAGE"
echo "已生成: $ZIP ($(du -h "$ZIP" | cut -f1))"
