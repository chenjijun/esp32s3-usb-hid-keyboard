#!/usr/bin/env bash
# 手机端图标：一张 app_icon.png 生成 Android / iOS 需要的所有尺寸。
#
# 依赖：ImageMagick（brew install imagemagick）、flutter（dev 依赖里的
# flutter_launcher_icons 负责真正写入 mipmap / AppIcon.appiconset）。
#
#   ./tools/make_mobile_icons.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app_icon.png"
OUT="$ROOT/mobile_client/assets/app_icon.png"

if [ ! -f "$SRC" ]; then
  echo "找不到 $SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

# 源图不是正方形（862x810），先补成正方形再缩到 1024。
# 补边用纯黑，和图标本身的底色一致，看不出接缝。
magick "$SRC" -background black -gravity center -extent 862x862 \
  -resize 1024x1024 -strip "$OUT"

echo "写入 $OUT"
magick identify "$OUT"

# 再让 flutter_launcher_icons 铺到两端工程里
cd "$ROOT/mobile_client"
dart run flutter_launcher_icons

echo "完成：Android mipmap-* / iOS AppIcon.appiconset 已更新"
