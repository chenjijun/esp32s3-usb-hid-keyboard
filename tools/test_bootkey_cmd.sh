#!/usr/bin/env bash
# ============================================================================
#  引导键命令解析的离线测试（不需要板子、不需要 PlatformIO）
# ----------------------------------------------------------------------------
#  做法：从 esp32s3_ble_keyboard.ino 里把两段原样抠出来——
#    A) 连发参数变量 + 范围夹取 + bootKeyBeginWindow/Stop
#    B) notifyBootCfg + pushCommand + handleBootKeyCommand
#  再拼上 tools/bootkey_cmd_test.cpp 里的 Arduino 桩，用本机 clang++ 编译跑一遍。
#
#  测的是「一条 BOOTKEY: 命令怎么被解析、越界值怎么夹、回执长什么样」——
#  这部分最容易写错，而且没有板子根本看不出来。
#
#  用法：./tools/test_bootkey_cmd.sh
#  依赖：clang++（macOS 自带；Linux 上装 clang 或把 CXX 指向 g++）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INO="$ROOT/esp32s3_ble_keyboard/esp32s3_ble_keyboard.ino"
SRC="$ROOT/tools/bootkey_cmd_test.cpp"
CXX="${CXX:-clang++}"

[ -f "$INO" ] || { echo "找不到固件源码: $INO" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A) 从 bootKeyCode 定义到「命令分发」之前：夹取/开关窗口、NVS 存取、
#    bootKeyName、serviceBootKey 都在这一段里
awk '/^static uint8_t bootKeyCode/{f=1} /^\/\/ -+ 命令分发/{f=0} f' \
    "$INO" > "$TMP/block_a.inc"

# B) 从「引导键的完整状态回执」到鼠标那一节之前
awk '/^\/\/ 引导键的完整状态回执/{f=1} /^\/\/ -+ 鼠标/{f=0} f' \
    "$INO" > "$TMP/block_b.inc"

if [ ! -s "$TMP/block_a.inc" ] || [ ! -s "$TMP/block_b.inc" ]; then
  echo "没抽到引导键相关代码段，检查 .ino 里那两处注释是否还在" >&2
  exit 1
fi

cp "$SRC" "$TMP/main.cpp"
"$CXX" -std=c++17 -Wall -Wextra -Wno-unused-function -I "$TMP" \
       -o "$TMP/t" "$TMP/main.cpp"
"$TMP/t"
