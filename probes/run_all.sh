#!/bin/bash
# AISnap 探针总入口
#
#   ./probes/run_all.sh            运行全部探针
#   ./probes/run_all.sh geometry   只运行名字里含 geometry 的探针
#
# 每个探针都会把"实测值"和"应有值"打印出来，最后汇总 PASS/BUG 计数。
# 探针编译的是仓库里真实的 Sources/*.swift，不存在"两份代码"的问题。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
OUT="$(mktemp -d)"
FILTER="${1:-}"

ARCH=$(uname -m)
case "$ARCH" in
    arm64) TARGET="arm64-apple-macosx13.0" ;;
    x86_64) TARGET="x86_64-apple-macosx13.0" ;;
    *) TARGET="$ARCH-apple-macosx13.0" ;;
esac
# 部署目标必须是 13：ScreenCapture.swift 用的 CGWindowListCreateImage 在 macOS 15 起已 obsolete
SWIFT_FLAGS=(-target "$TARGET" -O)

CORE=(Sources/Models.swift Sources/HitTestBuffer.swift Sources/AnnotationView.swift)
WINDOW=("${CORE[@]}" Sources/AnnotationWindow.swift)
CAPTURE=(Sources/ScreenCapture.swift Sources/RegionSelectionWindow.swift)

declare -a NAMES=()
declare -a BUGS=()

# macOS 没有 timeout，自己实现
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited+1))
        if [ "$waited" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
    done
    wait "$pid"
    return $?
}

run_swift_probe() {
    local name="$1"; shift
    local sources=("$@")
    local bin="$OUT/$name"
    # CanvasSupport.swift 依赖 AnnotationView；不含它的探针（screens / region）不链接它
    local extra=(probes/Support.swift)
    for s in "${sources[@]}"; do
        [ "$s" = "Sources/AnnotationView.swift" ] && extra+=(probes/CanvasSupport.swift)
    done
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "  ▶ $name"
    echo "════════════════════════════════════════════════════════════════"
    if ! swiftc "${SWIFT_FLAGS[@]}" -o "$bin" "${extra[@]}" \
            "${sources[@]}" "probes/$name.swift" 2>"$OUT/$name.build.log"; then
        echo "[FAIL] $name  编译失败（探针与源码不同步？）"
        sed 's/^/         /' "$OUT/$name.build.log" | head -20
        NAMES+=("$name"); BUGS+=("?")
        return
    fi
    run_with_timeout 90 "$bin" 2>&1 | tee "$OUT/$name.run.log"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 124 ]; then
        echo "[FAIL] $name  超时（需要可交互的图形会话？）"
        NAMES+=("$name"); BUGS+=("?")
        return
    fi
    NAMES+=("$name"); BUGS+=("$(grep -o 'BUG=[0-9]*' "$OUT/$name.run.log" | tail -1 | cut -d= -f2)")
}

run_shell_probe() {
    local script="$1"
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "  ▶ $script"
    echo "════════════════════════════════════════════════════════════════"
    bash "probes/$script" 2>&1 | tee "$OUT/$script.run.log"
    local rc=${PIPESTATUS[0]}
    local bugs
    bugs=$(grep -o 'BUG=[0-9]*' "$OUT/$script.run.log" | tail -1 | cut -d= -f2)
    [ -n "$bugs" ] || bugs=$([ "$rc" -eq 0 ] && echo 0 || echo "?")
    NAMES+=("$script"); BUGS+=("$bugs")
}

want() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }

want probe_deployment_target && run_shell_probe probe_deployment_target.sh
want probe_layout          && run_swift_probe probe_layout          "${WINDOW[@]}"
want probe_geometry        && run_swift_probe probe_geometry        "${CORE[@]}"
want probe_canvas          && run_swift_probe probe_canvas          "${CORE[@]}"
want probe_spotlight       && run_swift_probe probe_spotlight       "${CORE[@]}"
want probe_perf            && run_swift_probe probe_perf            "${CORE[@]}"
want probe_export_scale    && run_swift_probe probe_export_scale    "${CORE[@]}" Sources/ScreenCapture.swift
want probe_watermark       && run_swift_probe probe_watermark       "${WINDOW[@]}"
want probe_screens         && run_swift_probe probe_screens         "${CAPTURE[@]}"
want probe_region          && run_swift_probe probe_region          "${CAPTURE[@]}"
want probe_signing         && run_shell_probe probe_signing.sh
want probe_post_fix_audit  && run_swift_probe probe_post_fix_audit  "${WINDOW[@]}" Sources/ScreenCapture.swift
want render_arrows        && run_swift_probe render_arrows        "${CORE[@]}"
want probe_colors         && run_swift_probe probe_colors         "${WINDOW[@]}"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  汇总（「复现缺陷数」= 该探针判定为 FAIL 的条目数）"
echo "════════════════════════════════════════════════════════════════"
TOTAL=0
for i in "${!NAMES[@]}"; do
    b="${BUGS[$i]:-?}"
    if [ "$b" = "0" ]; then
        printf "  %-30s 复现缺陷数 = 0    （该项已修复或当前环境未暴露）\n" "${NAMES[$i]}"
    else
        printf "  %-30s 复现缺陷数 = %-4s ← 报告中列出的缺陷仍然存在\n" "${NAMES[$i]}" "$b"
        [ "$b" = "?" ] || TOTAL=$((TOTAL + b))
    fi
done
echo "  ────────────────────────────────────────────────────────────"
printf "  %-30s %s\n" "合计复现" "$TOTAL 条"
echo
echo "探针二进制与编译日志：$OUT"
echo "提示：涉及屏幕/窗口的探针（screens / region）结论会随会话状态变化——"
echo "      请在未锁屏、鼠标停在目标显示器上的正常会话中再跑一次对照。"
