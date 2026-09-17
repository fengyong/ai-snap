#!/bin/bash
# 探针 01 — CGWindowListCreateImage 的可用性（报告 P0-1）
#
# 结论：该 API 在 macOS 14 被弃用、15 起 obsolete。工程之所以还能编译，
#       是因为 Package.swift 把部署目标钉在 macOS 13。提高部署目标会直接编译失败。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC="Sources/ScreenCapture.swift"
PASS=0; BUG=0

echo "──── P0-1 不同部署目标下编译 ScreenCapture.swift ────"
for target in 13.0 14.0 15.0; do
    out=$(swiftc -typecheck -target "arm64-apple-macosx$target" "$SRC" 2>&1)
    rc=$?
    warn=$(printf '%s' "$out" | grep -c "was deprecated" || true)
    err=$(printf '%s' "$out" | grep -c "is unavailable" || true)
    if [ "$rc" -eq 0 ] && [ "$warn" -eq 0 ]; then
        echo "[PASS] P0-1  macOS $target 编译干净（无警告无错误）"
        PASS=$((PASS+1))
    elif [ "$rc" -eq 0 ]; then
        echo "[INFO] P0-1  macOS $target 编译通过，但有 $warn 条弃用警告"
    else
        echo "[FAIL] P0-1  macOS $target 编译失败（$err 处 'is unavailable'）"
        echo "         实测: $(printf '%s' "$out" | grep 'is unavailable' | head -1 | sed 's/^ *//')"
        echo "         应为: 该 API 在 macOS 15 起不可用，需迁移到 ScreenCaptureKit 才能提高部署目标"
        BUG=$((BUG+1))
    fi
done

echo
echo "参考：SDK 头文件的可用性标注"
SDK=$(xcrun --show-sdk-path 2>/dev/null)
HDR="$SDK/System/Library/Frameworks/CoreGraphics.framework/Headers/CGWindow.h"
if [ -f "$HDR" ]; then
    grep -A3 'CGImageRef __nullable CGWindowListCreateImage' "$HDR" | grep -E 'SCREEN_CAPTURE_OBSOLETE|CG_EXTERN' | sed 's/^/  /'
    echo "  （SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0) = 10.5 引入 / 14.0 弃用 / 15.0 起不可用）"
fi

echo
echo "========== probe_deployment_target: PASS=$PASS  BUG=$BUG =========="
[ "$BUG" -eq 0 ] || exit 1
