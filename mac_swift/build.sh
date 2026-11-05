#!/usr/bin/env bash
# 编译 SwiftUI 版客户端，产出一个可直接双击的 .app
#
#   用法：
#     ./mac_swift/build.sh                  # 只编当前架构（默认）
#     ./mac_swift/build.sh --universal      # arm64 + x86_64，能跑在 Intel Mac 上
#     ./mac_swift/build.sh --run            # 编译完直接启动
#     ./mac_swift/build.sh --install        # 编完复制到 /Applications 并启动
#     SIGN_IDENTITY="Apple Development: xxx" ./mac_swift/build.sh   # 指定证书
#
#   签名策略（跟「每次重编都要重新授权」直接相关）：
#     1) 有 $SIGN_IDENTITY 就用它
#     2) 否则自动找专用钥匙串里名为 ESP32KeyboardLocal 的自签证书
#        （~/Library/Keychains/esp32-signing.keychain-db，没有就先跑一次 make_cert.sh）
#     3) 都没有才退回 ad-hoc，并在结尾明确警告
#
#   为什么用专用钥匙串：login 钥匙串的密码是用户密码，脚本不知道，codesign 读私钥时
#   会弹授权框等人输密码；无图形界面时这个框不显示，签名就永久卡住。专用钥匙串密码固定，
#   脚本能自己 unlock，于是签名全自动。
#
#   为什么非要固定证书：macOS 的 TCC（辅助功能 / 蓝牙授权）是按「代码签名身份」
#   记账的。ad-hoc 签名（codesign -s -）里唯一能标识它的是 cdhash，而 cdhash 每次
#   重编都会变，系统就当成另一个 App，于是授权失效。用固定证书后，指定要求变成
#     identifier "local.esp32keyboard.swift" and certificate leaf = H"5966ab…"
#   ——只认证书，不认 cdhash，重编多少次都是同一个 App。
set -euo pipefail
cd "$(dirname "$0")"

NAME="ESP32KeyboardSwift"
APP="../${NAME}.app"
MIN_MACOS="${MIN_MACOS:-14.0}"
# 自签证书的默认名字，和 make_cert.sh 里的 CERT_NAME 保持一致
CERT_DEFAULT="${CERT_DEFAULT:-ESP32KeyboardLocal}"
# 专用签名钥匙串：里面只放那张本地自签证书，密码固定，
# 所以脚本能自己 unlock，签名时不会弹「codesign 想要访问密钥」的授权框
# （无图形界面时那个框根本不显示，codesign 会永久卡住）
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/esp32-signing.keychain-db}"
KC_PASS="${KC_PASS:-esp32local}"
# 记住上次用的签名身份，用来判断「这次要不要重新授权」
STAMP=".sign-identity"

UNIVERSAL=0
RUN=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --run)       RUN=1 ;;
        --install)   INSTALL=1; RUN=1 ;;
        *) echo "未知参数：${arg}（可用 --universal / --run / --install）"; exit 1 ;;
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
# 选身份：显式指定 > 专用钥匙串里的自签证书 > ad-hoc
IDENTITY=""
USE_KEYCHAIN=""
if [ -n "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
        | grep -Fq "\"$CERT_DEFAULT\""; then
    IDENTITY="$CERT_DEFAULT"
    USE_KEYCHAIN="$SIGN_KEYCHAIN"
fi

if [ -n "$IDENTITY" ]; then
    echo "   使用证书：$IDENTITY"
    if [ -n "$USE_KEYCHAIN" ]; then
        echo "   钥匙串：${USE_KEYCHAIN}（已解锁，签名不会弹授权框）"
        # 钥匙串可能因为闲置锁上了；解锁后 codesign 才能静默读私钥。
        # 没有这一步，在无图形界面的环境里 codesign 会卡在等授权框，永远不返回。
        security unlock-keychain -p "$KC_PASS" "$USE_KEYCHAIN"
        # 不加 --options runtime（硬化运行时）：那是给要做公证的 App 用的，
        # 本地自签证书开它只会平白限制自己，对 TCC 授权也没有帮助。
        codesign --force --timestamp=none --keychain "$USE_KEYCHAIN" \
            --sign "$IDENTITY" "$APP"
    else
        codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
    fi
    CUR="$IDENTITY"
else
    echo "   ad-hoc（没有找到固定证书）"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || {
        echo "   签名失败，重试一次"
        codesign --force --sign - "$APP"
    }
    CUR="ad-hoc"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2
# 把指定要求打出来：只要它里面是 certificate leaf（而不是 cdhash），
# 就说明签名身份已经固定，以后重编不会再丢授权
echo "   指定要求：$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

# 签名身份变了、或者一直没固定，都要把「接下来会发生什么」讲清楚
PREV="$(cat "$STAMP" 2>/dev/null || true)"
if [ "$CUR" != "$PREV" ]; then
    if [ "$CUR" = "ad-hoc" ]; then
        cat <<'MSG'

   ⚠ 本次是 ad-hoc 签名：每次重编指纹都会变，系统会把它当成另一个 App，
     辅助功能（键盘接管）和蓝牙授权都得重新点一遍。
     一次性解决（只需跑一次）：
         ./mac_swift/make_cert.sh
     然后重新执行本脚本，之后就固定用这个证书签名了。

MSG
    else
        cat <<MSG

   ✔ 签名身份已固定为「${CUR}」（原来是「${PREV:-未固定}」）。
     这次换身份，需要在 系统设置 → 隐私与安全性 → 辅助功能 里重新勾选一次，
     蓝牙也要重新允许一次。**此后重编、重新打包都不必再授权。**
     如果开关还勾着却不生效：点界面权限胶囊右边的圆形箭头（重置授权），
     再点「去授权」重新添加本 App 即可。

MSG
    fi
    printf '%s' "$CUR" > "$STAMP"
fi

echo "== 完成：$APP =="
lipo -info "${APP}/Contents/MacOS/${NAME}"
du -sh "$APP"

if [ "$INSTALL" = "1" ]; then
    echo "== 安装到 /Applications =="
    # 先删再拷：ditto 对已存在的 bundle 增量覆盖会留下旧资源
    rm -rf "/Applications/${NAME}.app"
    ditto "$APP" "/Applications/${NAME}.app"
    echo "   /Applications/${NAME}.app"
    echo "   以后就固定从这一个位置启动。TCC 是按「bundle id + 路径」记账的，"
    echo "   仓库根目录那份和 /Applications 那份会各存一条记录，混着用就会反复要授权。"
    APP="/Applications/${NAME}.app"
fi

if [ "$RUN" = "1" ]; then
    open "$APP"
fi
