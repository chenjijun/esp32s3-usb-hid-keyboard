#!/usr/bin/env bash
# 用项目根目录的 app_icon.png 生成 App 图标 Resources/AppIcon.icns
#
#   ./mac_swift/make_icon.sh                 # 用 ../app_icon.png
#   ./mac_swift/make_icon.sh 别的图.png      # 换一张图
#
# build.sh 发现 Resources/AppIcon.icns 不存在时会自动调这个脚本，
# 所以平时不必单独执行。换了图之后重跑一次再编译即可。
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-../app_icon.png}"
OUT="Resources/AppIcon.icns"

[ -f "$SRC" ] || { echo "找不到源图：$SRC"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 生成图标 =="
echo "   源图：$SRC"
swift tools/make_icon.swift "$SRC" "$TMP/AppIcon.iconset"

mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"

echo "== 完成：$OUT =="
ls -lh "$OUT" | awk '{print "   体积：" $5}'
