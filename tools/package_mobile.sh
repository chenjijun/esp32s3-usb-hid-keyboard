#!/usr/bin/env bash
# 手机端发布包：release APK + 源码 zip（放到仓库根目录的 dist/）。
#
#   ./tools/package_mobile.sh              # 版本默认 1.0.0
#   VERSION=1.0.1 ./tools/package_mobile.sh
#
# iOS 不出包：App Store 之外要开发者证书签名，源码 zip 让用户自己用 Xcode 打。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
APP="mobile_client"
DIST="$ROOT/dist"

if ! command -v flutter >/dev/null 2>&1; then
  echo "找不到 flutter，先装 SDK 并加进 PATH" >&2
  exit 1
fi

mkdir -p "$DIST"

echo "==> 1/3 依赖"
(cd "$ROOT/$APP" && flutter pub get)

echo "==> 2/3 打 release APK"
(cd "$ROOT/$APP" && flutter build apk --release)

APK="$ROOT/$APP/build/app/outputs/flutter-apk/app-release.apk"
OUT_APK="$DIST/ESP32Keyboard-Mobile-$VERSION.apk"
cp "$APK" "$OUT_APK"
echo "    $OUT_APK ($(du -h "$OUT_APK" | cut -f1))"

echo "==> 3/3 源码包"
OUT_SRC="$DIST/ESP32KeyboardMobile-$VERSION-source.zip"
rm -f "$OUT_SRC"
(cd "$ROOT" && zip -r -X -q "$OUT_SRC" "$APP" \
  -x "$APP/build/*" \
     "$APP/.dart_tool/*" \
     "$APP/.git/*" \
     "$APP/ios/Pods/*" \
     "$APP/ios/.symlinks/*" \
     "$APP/ios/Flutter/ephemeral/*" \
     "$APP/ios/Flutter/Generated.xcconfig" \
     "$APP/android/.gradle/*" \
     "$APP/android/local.properties" \
     "$APP/.idea/*" \
     "$APP/.vscode/*" \
     "*/__pycache__/*" \
     "*.iml" \
     ".DS_Store")
echo "    $OUT_SRC ($(du -h "$OUT_SRC" | cut -f1))"

echo
echo "完成。iOS 用源码包："
echo "  unzip $OUT_SRC && cd $APP && flutter pub get"
echo "  open ios/Runner.xcworkspace   # Xcode 里配签名后 Run / Archive"
