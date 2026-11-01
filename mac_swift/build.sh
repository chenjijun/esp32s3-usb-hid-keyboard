#!/usr/bin/env bash
# 编译 SwiftUI 版客户端，产出一个可直接双击的 .app
#
#   用法：
#     ./mac_swift/build.sh                  # 只编当前架构（默认）
#     ./mac_swift/build.sh --universal      # arm64 + x86_64，能跑在 Intel Mac 上
#     ./mac_swift/build.sh --run            # 编译完直接启动
#     SIGN_IDENTITY="Apple Development: xxx" ./mac_swift/build.sh   # 用证书签名
#
#   不传 SIGN_IDENTITY 就用 ad-hoc 签名：本机自用没问题，
#   但每次重编译指纹会变，蓝牙/辅助功能授权可能要重新点一次。
set -euo pipefail
cd "$(dirname "$0")"

NAME="ESP32KeyboardSwift"
APP="../${NAME}.app"
MIN_MACOS="${MIN_MACOS:-14.0}"

UNIVERSAL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --run)       RUN=1 ;;
        *) echo "未知参数：$arg（可用 --universal / --run）"; exit 1 ;;
    esac
done

echo "== 清理 =="
rm -rf "$APP" build
mkdir -p build

# 抽取成函数，两种架构走同一份参数
compile_arch() {
    local arch="$1"
    local out="$2"
    swiftc -swift-version 5 -O \
        -target "${arch}-apple-macosx${MIN_MACOS}" \
        -o "$out" \
        Sources/*.swift
}

echo "== 编译 =="
if [ "$UNIVERSAL" = "1" ]; then
    for arch in arm64 x86_64; do
        echo "   $arch"
        compile_arch "$arch" "build/${NAME}-${arch}"
    done
    lipo -create -output "build/${NAME}" \
        "build/${NAME}-arm64" "build/${NAME}-x86_64"
else
    ARCH="$(uname -m)"
    echo "   $ARCH"
    compile_arch "$ARCH" "build/${NAME}"
fi

echo "== 组装 bundle =="
# 图标：Resources/AppIcon.icns 不存在时用根目录 app_icon.png 现场生成
if [ ! -f Resources/AppIcon.icns ]; then
    ./make_icon.sh
fi
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
# 版本号：package.sh 会传 VERSION 进来，不传就是 plist 里的默认值。
# 要在签名之前写，改完 plist 再签名才不会破坏签名。
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "${APP}/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "${APP}/Contents/Info.plist"
    echo "   版本号：$VERSION"
fi
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
cp "build/${NAME}" "${APP}/Contents/MacOS/${NAME}"

echo "== 签名 =="
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "   使用证书：$SIGN_IDENTITY"
    codesign --force --options runtime --timestamp=none \
        --sign "$SIGN_IDENTITY" "$APP"
else
    echo "   ad-hoc（无证书，仅本机可用）"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || {
        echo "   签名失败，重试一次"
        codesign --force --sign - "$APP"
    }
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "== 完成：$APP =="
lipo -info "${APP}/Contents/MacOS/${NAME}"
du -sh "$APP"

if [ "$RUN" = "1" ]; then
    open "$APP"
fi
