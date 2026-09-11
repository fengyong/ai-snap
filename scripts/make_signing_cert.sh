#!/bin/bash
#
# 生成并导入一张自签名代码签名证书，供本机构建使用。
#
# ## 为什么需要它
#
# ad-hoc 签名（`codesign --sign -`）没有证书标识，TCC 只能按 **cdhash** 关联授权。
# 而 cdhash 是二进制内容的哈希 —— **每重新编译一次就变**，于是授权失效，
# 用户得再去「系统设置 → 隐私与安全性 → 屏幕录制」里勾一遍。
#
# 有了稳定的证书标识，TCC 改为按「证书 + bundle ID」关联，重新编译、重新安装
# 都不再影响授权。`build.sh` 检测到这张证书就会自动改用它。
#
# ## 不需要 Apple Developer 账号
#
# 自签名证书是本地生成的，免费。但它只解决**本机**的权限稳定性 ——
# 要把 DMG 发给别人的 Mac，仍然需要 Developer ID 证书 + 公证（M5-1）。
#
# 用法：
#   ./scripts/make_signing_cert.sh              # 用默认名 AISnap Local Signing
#   ./scripts/make_signing_cert.sh "自定义名"
#
set -euo pipefail

IDENTITY="${1:-AISnap Local Signing}"

echo "==> 检查是否已存在「${IDENTITY}」"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
  echo "✅ 已存在，无需重复创建。"
  echo "   之后 ./build.sh 会自动用它签名。"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 生成自签名证书"
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = ${IDENTITY}
O = AISnap

[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

# 用**系统自带的 LibreSSL**（/usr/bin/openssl）而不是 PATH 里可能存在的
# Homebrew OpenSSL 3：后者的 PKCS#12 默认用 AES-256 + SHA-256 做 MAC，
# 而 macOS 的 `security import` 不认，会报 "MAC verification failed"。
# 这个坑踩过一次，所以这里显式指定路径。
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" 2>/dev/null
echo "   有效期 10 年"

CERT_PASS="$(/usr/bin/openssl rand -hex 20)"
/usr/bin/openssl pkcs12 -export -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$CERT_PASS" -name "${IDENTITY}"

echo "==> 导入登录钥匙串（并授权 codesign 使用）"
security import "$TMP/cert.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$CERT_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> 验证"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY}"; then
  echo "✅ 完成。"
  echo "   之后 ./build.sh 会自动用「${IDENTITY}」签名，"
  echo "   屏幕录制权限不会再因为重新编译而失效。"
else
  cat <<EOF
⚠️  证书已导入，但没出现在「代码签名身份」列表里。

    这通常是证书的信任设置问题。请打开「钥匙串访问」：
      1. 选「登录」钥匙串 → 「我的证书」
      2. 找到「${IDENTITY}」，双击
      3. 展开「信任」→ 把「代码签名」设为「始终信任」
      4. 关闭窗口（会要求输入密码）

    然后重新运行本脚本确认。
EOF
  exit 1
fi
