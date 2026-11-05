#!/bin/bash
# 打包 Python 版客户端：dist/ESP32Keyboard-Python-<版本>.zip
#
# zip 里有：ESP32Keyboard.app（启动壳，运行时自己找 python3）、
#           源码、requirements.txt、build_app.sh、使用说明.txt
#
# 用法：
#   ./package_app.sh                 # 版本默认 1.2.1
#   VERSION=1.2.2 ./package_app.sh
#   PYTHON_BIN=/path/to/python3 ./package_app.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${VERSION:-1.2.1}"
STAGE="$ROOT/dist/ESP32Keyboard-Python-$VERSION"
ZIP="$ROOT/dist/ESP32Keyboard-Python-$VERSION.zip"

# 发布包里不写死解释器路径，换台机器也能跑
LAUNCH_PY="" VERSION="$VERSION" "$HERE/build_app.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$ROOT/ESP32Keyboard.app" "$STAGE/"
cp "$HERE/ble_keyboard_client.py" "$HERE/requirements.txt" "$HERE/build_app.sh" "$STAGE/"

cat > "$STAGE/README.txt" <<'TXT'
ESP32 无线键盘 · Python 版客户端（使用说明）
==========================================

【这是什么】
ESP32-S3 板子插在被控主机的 USB 口上，本程序在你的 Mac 上把按键发过去。
板子对主机来说就是一个普通 USB 键盘（外加鼠标和多媒体键），免驱。

【第一次用】
1. 装依赖（本机没有 bleak 时双击 App 会弹窗提示）：
       python3 -m pip install -r requirements.txt
2. 双击 ESP32Keyboard.app。
   —— 别用终端直接 python3 ble_keyboard_client.py 开，
      那样蓝牙会被 macOS 拦掉（TCC 只认带蓝牙声明的 App）。
3. 板子上按 BOOT 键选链路：
       BLE     ：灯蓝色（未连）→ 紫色（已连）
       Wi-Fi   ：灯绿色（未连）→ 黄色（已连）
4. 界面上选同样的链路，点「连接」。

【Wi-Fi 模式】
先让 Mac 连上板子开的热点：ESP32-Keyboard / 密码 esp32keyboard
然后主机填 192.168.4.1、端口 8266，点「连接」。

【本机键盘转发】
点「开始捕获」，本机按键会被吞掉、转给主机。
第一次要先授权：系统设置 → 隐私与安全性 → 辅助功能 → 勾选本 App。
想停下：点「停止」，或按 ⌃⇧E（Control+Shift+E，备用 ⌃⌥Esc）。
这一步需要 pyobjc（见 requirements.txt），不装只影响这一个功能。

【鼠标】
右侧「按住拖动」区域拖动 = 移动指针，速度滑杆 0.5×–4×。
左/中/右三键是按下发 down、松手发 up；要框选或拖文件，先点「按住左键」锁住，
再去拖拖拽区，完事点「松开左键」。

【BIOS】
「BIOS 启动键」里 Del / Esc / F1~F12 全给了（各家主板进设置的那个键不统一），
点一下只是选中，再点「写入固件」才真正写进板子（掉电保持）。
上面还能调「时长」（连发持续几秒）和「间隔」（每两下隔多少毫秒），
写一次之后每次上电板子自己连发，主机 POST 阶段就能收到。
已经开机想再敲一次，用「立即连发」；点「查询设置」读回板子里的真值。

【折叠与外观】
BIOS 启动键、文字、常用快捷键这三块，点标题栏就能收起 / 展开，
收起时标题右边会显示一句概要（比如「DELETE · 10 秒 / 220ms」）。
收起来的状态会记住，下次打开还是那样。
界面配色在启动时跟随系统明暗；想手动换，点右上角「外观」按钮切换。

【卡住了】
点「释放全部按键」；断开连接或关窗口也会自动松键。

【已知限制】
· 没有 Apple 开发者证书，App 用的是本机自签证书。首次打开若提示
  「无法验证开发者」，右键点 App → 打开。
· 在打包这台机器上，签名身份是固定的，重新打包不会掉蓝牙 / 辅助功能授权；
  但别把仓库根目录和 /Applications 里的两份 App 混着用——TCC 按路径记账，
  混用会各存一条记录，于是又要授权。
· 本机键盘转发会接管整块键盘，按 ⌃⇧E（或 ⌃⌥Esc）永远能停。
TXT

mkdir -p "$ROOT/dist"
rm -f "$ZIP"
# 用 zip 而不是 ditto：不产生 __MACOSX/._ 这些资源叉垃圾，
# -X 去掉多余属性，文件名按 UTF-8 存（Windows 解压也不乱码）
( cd "$ROOT/dist" && zip -r -X -q "$(basename "$ZIP")" "$(basename "$STAGE")" )
rm -rf "$STAGE"

echo "已生成: $ZIP ($(du -h "$ZIP" | cut -f1))"
