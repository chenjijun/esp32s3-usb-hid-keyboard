#!/usr/bin/env bash
# ============================================================================
#  指令闪灯的离线测试（不需要板子、不需要 PlatformIO）
# ----------------------------------------------------------------------------
#  做法：从 esp32s3_ble_keyboard.ino 里把「指令闪灯状态机」那一段原样抠出来，
#  拼上 tools/led_flash_test.cpp 的桩和断言，用本机 clang++ 编译跑一遍。
#  好处是测的就是固件里真正跑的那份代码——改了阈值、改了节拍，测试会立刻反映，
#  不会出现「测试里一份、固件里另一份」。
#
#  用法：./tools/test_led_flash.sh
#  依赖：clang++（macOS 自带；Linux 上装 clang 或把 CXX 指向 g++）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INO="$ROOT/esp32s3_ble_keyboard/esp32s3_ble_keyboard.ino"
SRC="$ROOT/tools/led_flash_test.cpp"
CXX="${CXX:-clang++}"

[ -f "$INO" ] || { echo "找不到固件源码: $INO" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 抠出闪灯状态机：从「---- 指令闪灯」到「蓝/紫 = 蓝牙模式」之前
awk '/^\/\/ ---- 指令闪灯/{f=1} /^\/\/ 蓝\/紫 = 蓝牙模式/{f=0} f' "$INO" > "$TMP/flash_block.inc"
if [ ! -s "$TMP/flash_block.inc" ]; then
  echo "没抽到闪灯代码段，试试把文件开头的 LED_CMD_FLASH 开关恢复成 1" >&2
  exit 1
fi

cp "$SRC" "$TMP/main.cpp"
"$CXX" -std=c++17 -Wall -Wextra -O1 -I "$TMP" -o "$TMP/t" "$TMP/main.cpp"
"$TMP/t"
