#!/usr/bin/env bash
# 创建本机自签「代码签名」证书，把 App 的签名身份固定下来。
#
# ---------------------------------------------------------------------------
# 为什么需要它
#
#   不建这张证书时，build.sh 只能退回 ad-hoc 签名（codesign -s -）。
#   ad-hoc 签名里唯一能标识 App 的是 cdhash，而 macOS 的 TCC（辅助功能 / 蓝牙授权）
#   就是靠它认程序的。每重新编译一次 cdhash 就变一次，于是：
#
#     - 系统设置 → 辅助功能 里那条开关看起来还是勾着的
#     - 但系统认为「这不是同一个程序」，AXIsProcessTrusted() 一直返回 false
#     - 点「重新检测」永远不会变绿，看起来像「明明授权了却不生效」
#
#   换成固定的自签名证书后，签名指定要求变成
#       identifier "local.esp32keyboard.swift" and certificate leaf = H"…"
#   ——只认 bundle id + 证书指纹，不含 cdhash，于是重编译不再影响已有授权。
#
# ---------------------------------------------------------------------------
# 为什么单独建一个钥匙串，而不是装进 login 钥匙串
#
#   codesign 读私钥时，若私钥的 ACL 没预放行，macOS 会弹「codesign 想要访问钥匙串
#   中的密钥」授权框并等用户输密码。没有图形界面时（CI、远程会话、脚本里跑），
#   这个框根本不出现，codesign 就一直卡在 "replacing existing signature" 不动——
#   等五分钟也不会自己好。
#
#   login 钥匙串的密码是用户登录密码，脚本无从得知，也就没法自动放行。
#   所以这里单开一个 esp32-signing.keychain-db，密码固定（它只保护这张本地自签证书，
#   不含任何别的凭据），脚本就能 unlock + set-key-partition-list，签名全自动不弹框。
#
# ---------------------------------------------------------------------------
# 用法（只需做一次）
#
#   ./mac_swift/make_cert.sh
#   ./mac_swift/build.sh                  # 之后自动认这张证书，不用再传参数
#
#   build.sh 会先看 $SIGN_IDENTITY，没有就找专用钥匙串里叫 ESP32KeyboardLocal 的证书，
#   找到就用；都没有才退回 ad-hoc 并在结尾打印警告。
# ---------------------------------------------------------------------------
set -euo pipefail

CERT_NAME="${CERT_NAME:-ESP32KeyboardLocal}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/esp32-signing.keychain-db}"
# 只保护这张本地自签证书，不是用户密码；可以在环境变量里改
KC_PASS="${KC_PASS:-esp32local}"
P12_PASS="${P12_PASS:-esp32local}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 目标证书：$CERT_NAME =="
echo "   钥匙串：$SIGN_KEYCHAIN"

if security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
        | grep -Fq "\"$CERT_NAME\""; then
    echo
    echo "已存在可用的同名证书，跳过创建。直接构建即可："
    echo "  ./mac_swift/build.sh"
    exit 0
fi

# 1. 新建（或解锁）专用钥匙串
if [ ! -f "$SIGN_KEYCHAIN" ]; then
    echo "== 1/4 创建专用钥匙串 =="
    security create-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN"
else
    echo "== 1/4 复用已有钥匙串 =="
fi
# -l 不自动锁 / -u 一段时间无操作后锁 / -t 21600 秒 = 6 小时
security set-keychain-settings -lut 21600 "$SIGN_KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$SIGN_KEYCHAIN"

# 2. 生成自签名证书
echo "== 2/4 生成自签名证书 =="
cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $CERT_NAME

[ v3 ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/openssl.cnf" 2>/dev/null

# 为什么给 p12 设密码而不是用空密码：OpenSSL 3 生成「空密码 PKCS#12」时默认用
# AES-256 + SHA-256，macOS 的 Security 框架不认，import 会报
#   SecKeychainItemImport: MAC verification failed (wrong password?)
# 显式指定老式 PBE-SHA1-3DES + SHA1 MAC 再配一个非空密码，两代 OpenSSL 都能读。
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" \
    -out "$TMP/cert.p12" \
    -passout pass:"$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# 3. 导入 + 免弹框
echo "== 3/4 导入钥匙串 =="
security import "$TMP/cert.p12" -k "$SIGN_KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# 这一行是「不弹授权框」的关键：把 codesign / security 加进私钥的 partition list，
# 之后它们读私钥不再需要用户点「允许」。少了它，签名在无界面环境下会永久卡住。
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KC_PASS" "$SIGN_KEYCHAIN" >/dev/null

# 4. 设为受信任根（不影响能否签名，只是让 find-identity 显示为有效、验证链过得去）
echo "== 4/4 标记为受信任根证书 =="
if security add-trusted-cert -r trustRoot -k "$SIGN_KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
    echo "   已设为受信任根证书"
else
    echo "   跳过（不影响本机签名，只是 find-identity 可能显示为未信任）"
fi

echo
echo "== 完成 =="
security find-identity -v -p codesigning "$SIGN_KEYCHAIN" | tail -3
echo
echo "搞定。之后直接构建即可，build.sh 会自动认这张证书："
echo "  ./mac_swift/build.sh            # 或 --universal / --install"
echo "  ./mac_swift/package.sh"
echo
echo "换签名身份后的第一次构建仍要重新授权一次（旧记录是上一个签名留下的），"
echo "此后重编、重新打包都不用再授权。"
