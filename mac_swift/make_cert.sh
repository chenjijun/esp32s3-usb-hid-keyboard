#!/usr/bin/env bash
# 创建本机自签名「代码签名」证书，把 App 的签名身份固定下来。
#
# ---------------------------------------------------------------------------
# 为什么需要它
#
#   默认构建用 ad-hoc 签名（codesign -s -），macOS 的 TCC 是按「代码签名指纹
#   (cdhash)」认程序的。每重新编译一次，cdhash 就变一次，于是：
#
#     - 系统设置 → 辅助功能 里那条开关看起来还是勾着的
#     - 但系统认为「这不是同一个程序」，AXIsProcessTrusted() 一直返回 false
#     - 点「重新检测」永远不会变绿，看起来像「明明授权了却不生效」
#
#   换成固定的自签名证书后，签名身份不再变化，重编译也不会影响已有授权。
#
# ---------------------------------------------------------------------------
# 用法（只需做一次）
#
#   ./mac_swift/make_cert.sh
#   SIGN_IDENTITY="ESP32KeyboardLocal" ./mac_swift/build.sh --universal
#
#   之后重新编译都带上 SIGN_IDENTITY，授权一次即可长期有效。
# ---------------------------------------------------------------------------
set -euo pipefail

CERT_NAME="${CERT_NAME:-ESP32KeyboardLocal}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 目标证书：$CERT_NAME =="

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "已存在同名证书，跳过创建。"
    echo
    echo "直接构建："
    echo "  SIGN_IDENTITY=\"$CERT_NAME\" ./mac_swift/build.sh --universal"
    exit 0
fi

echo "== 1/3 生成自签名证书 =="
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

openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass: 2>/dev/null \
  || openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:

echo "== 2/3 导入钥匙串 =="
# -T 预先放行 codesign，减少签名时反复弹「是否允许访问密钥」
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "== 3/3 标记为受信任（可能要求输入登录密码）=="
if security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
    echo "   已设为受信任根证书"
else
    echo "   跳过（不影响本机签名，只是 find-identity 可能显示为未信任）"
fi

echo
echo "== 完成 =="
security find-identity -v -p codesigning | tail -3
echo
echo "用这个身份构建："
echo "  SIGN_IDENTITY=\"$CERT_NAME\" ./mac_swift/build.sh --universal"
echo "  SIGN_IDENTITY=\"$CERT_NAME\" ./mac_swift/package.sh"
