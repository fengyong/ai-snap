#!/bin/bash
# 探针 11 — 代码签名、图标与 build.sh 可移植性（报告 P3-3）

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BUG=0
APP="AISnap.app"

echo "──── P3-3 签名与分发（检查构建产物 AISnap.app）────"
if [ ! -d "$APP" ]; then
    echo "[INFO] P3-3  尚未构建 ${APP}，先运行 ./build.sh 再复跑本探针"
else
    SIG=$(codesign -dvvv "$APP" 2>&1)
    printf '%s\n' "$SIG" | grep -E 'Identifier|Signature|Authority|TeamIdentifier|flags' | sed 's/^/  /'
    if printf '%s' "$SIG" | grep -q 'adhoc'; then
        echo "[FAIL] P3-3  ${APP} 使用 ad-hoc 签名"
        echo "         实测: $(printf '%s' "$SIG" | grep -o 'flags=[^ ]*([^)]*)' | head -1)"
        echo "         应为: 用稳定身份签名（如 AISnap Local Signing）；ad-hoc 的 cdhash 每次重建都变，会让屏幕录制授权失效"
        BUG=$((BUG + 1))
    else
        echo "[PASS] P3-3  ${APP} 使用稳定身份签名: $(printf '%s' "$SIG" | grep '^Authority=' | head -1 | cut -d= -f2)"
    fi

    if [ -f "${APP}/Contents/Resources/AISnap.icns" ] && grep -q 'CFBundleIconFile' "${APP}/Contents/Info.plist"; then
        echo "[PASS] P3-3  已包含应用图标（CFBundleIconFile + AISnap.icns）"
    else
        echo "[FAIL] P3-3  缺少应用图标（CFBundleIconFile / AISnap.icns）"
        BUG=$((BUG + 1))
    fi
fi

echo
echo "──── P3-3 build.sh 可移植性 ────"
BINDIR_LINE=$(grep -E '^[[:space:]]*BUILD_DIR=' build.sh | head -1)
if printf '%s' "$BINDIR_LINE" | grep -q 'arm64-apple-macosx'; then
    echo "[FAIL] P3-3  build.sh 硬编码了 arm64 产物路径（Intel Mac 上 cp 会失败并被 set -e 终止）"
    echo "         实测: ${BINDIR_LINE}"
    echo "         应为: BUILD_DIR=\$(swift build -c release --show-bin-path)"
    BUG=$((BUG + 1))
else
    echo "[PASS] P3-3  build.sh 未硬编码架构路径: ${BINDIR_LINE}"
fi

echo
echo "========== probe_signing: BUG=${BUG} =========="
[ "$BUG" -eq 0 ] || exit 1
