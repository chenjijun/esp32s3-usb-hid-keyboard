#!/bin/bash
# 用根目录的 app_icon.png 生成 Windows 用的 app_icon.ico 和界面用的 app_icon_256.png
#
#   ./tools/make_ico.sh            # 用 ../app_icon.png
#   ./tools/make_ico.sh 别的图.png  # 换一张
#
# 需要 ImageMagick（brew install imagemagick）。
# 生成的两份文件都提交进仓库，所以只有换图标时才需要跑这个脚本。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="${1:-$ROOT/app_icon.png}"
ICO="$ROOT/app_icon.ico"
PNG="$ROOT/app_icon_256.png"

if ! command -v magick >/dev/null 2>&1; then
    echo "需要 ImageMagick：brew install imagemagick" >&2
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "找不到源图：$SRC" >&2
    exit 1
fi

# 源图不是正方形：先按最长边补成正方形（补黑边，和源图背景同色），再缩到各尺寸。
# 直接裁切会切掉边缘的字，补边更安全。
W=$(magick identify -format "%w" "$SRC")
H=$(magick identify -format "%h" "$SRC")
SIDE=$(( W > H ? W : H ))

magick "$SRC" -background black -gravity center -extent "${SIDE}x${SIDE}" \
       -define icon:auto-resize=256,128,64,48,32,16 "$ICO"
magick "$SRC" -background black -gravity center -extent "${SIDE}x${SIDE}" \
       -resize 256x256 "$PNG"

echo "已生成："
magick identify -format "  %f  %wx%h\n" "$ICO"
magick identify -format "  %f  %wx%h\n" "$PNG"
