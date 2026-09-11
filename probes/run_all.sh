#!/bin/bash
#
# 跑全部探针。每个探针都在临时目录里编译（顶层代码那份必须叫 main.swift），
# 因此互不干扰、可以并行改。
#
#   ./probes/run_all.sh             跑全部
#   ./probes/run_all.sh redaction   只跑名字里含 redaction 的
#
set -u
cd "$(dirname "$0")/.." || exit 1

FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_NAMES=()

# 整模块源码。有三个探针要构造真实的 AnnotationView 并合成鼠标事件，
# 得把整个模块链进来（除了 Sources/main.swift —— 顶层代码那份由探针自己提供）。
# 用 while read 而不是 mapfile：macOS 自带的是 bash 3.2，没有 mapfile。
ALL_SOURCES=()
while IFS= read -r f; do
  ALL_SOURCES+=("$f")
done < <(ls Sources/*.swift Sources/*/*.swift | grep -v '^Sources/main.swift$')

# 每个探针：名字 + 需要链接的源文件（相对仓库根）
# 只列真实需要的源文件，不图省事全链 —— 这样「这个探针依赖哪些模块」在脚本里看得见。
run_probe() {
  local name="$1"; shift
  local sources=("$@")

  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then return; fi
  if [ ! -f "probes/$name.swift" ]; then
    echo "  ⚠️  找不到 probes/$name.swift，跳过"; return
  fi

  local tmp
  tmp="$(mktemp -d)"
  cp "probes/$name.swift" "$tmp/main.swift"

  # 拼成数组再执行：空数组直接展开在 bash 3.2 + set -u 下会报 unbound variable
  local cmd=(swiftc -O -target arm64-apple-macos14.0 -o "$tmp/run")
  if [ ${#sources[@]} -gt 0 ]; then cmd+=("${sources[@]}"); fi
  cmd+=("$tmp/main.swift")

  local out
  if ! out=$("${cmd[@]}" 2>&1); then
    echo "❌ $name —— 编译失败"
    echo "$out" | grep -E "error:" | head -5
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name(编译)")
    rm -rf "$tmp"; return
  fi

  out=$("$tmp/run" 2>&1)
  local code=$?
  # 新探针以「通过 N 项，失败 M 项」收尾，早期探针以「全部通过」收尾 —— 两种都接住
  local summary
  summary=$(echo "$out" | grep -E "^通过 " | tail -1)
  if [ -z "$summary" ]; then
    summary=$(echo "$out" | grep -vE "^[[:space:]]*$" | tail -1)
  fi
  # 对比型探针没有断言（它只给出实测数字让人判断），说明一下免得看着像漏了汇总
  case "$summary" in
    *通过*|*失败*|*✅*|*❌*) ;;
    *) summary="（对比探针，无断言：以退出码为准）" ;;
  esac
  if [ $code -eq 0 ]; then
    echo "✅ $name  $summary"
    PASS=$((PASS + 1))
  else
    echo "❌ $name  $summary"
    echo "$out" | grep -E "^  ❌" | head -8
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
  fi
  rm -rf "$tmp"
}

echo "=== 探针（链接真实源码）==="
# Preferences 现在依赖 HotkeyConfig，所以 prefs_probe 也得链上 HotkeyManager
run_probe prefs_probe            Sources/Models.swift Sources/Preferences.swift \
                                 Sources/HotkeyManager.swift
run_probe hotkey_probe           Sources/Models.swift Sources/Preferences.swift Sources/HotkeyManager.swift
run_probe cyclic_index_probe     Sources/Models.swift
run_probe text_shape_probe       Sources/Models.swift
run_probe screen_geometry_probe  Sources/Capture/ScreenGeometry.swift
run_probe anchored_placement_probe Sources/AnchoredPlacement.swift
run_probe overlay_style_probe    Sources/OverlayWindowStyle.swift
run_probe redaction_probe        Sources/Models.swift Sources/Capture/ScreenGeometry.swift \
                                 Sources/Redaction/ImageRedaction.swift \
                                 Sources/Redaction/RedactionShape.swift
run_probe downscale_probe        # 自带全部实现，不依赖仓库源码
run_probe history_probe          Sources/History/CaptureHistory.swift
run_probe update_probe           Sources/Models.swift Sources/Preferences.swift \
                                 Sources/HotkeyManager.swift Sources/Update/UpdateChecker.swift
# 这三个要整模块编译：它们构造真实的画布并合成鼠标事件
run_probe eraser_probe           "${ALL_SOURCES[@]}"
run_probe picker_probe           "${ALL_SOURCES[@]}"
run_probe ocr_probe              "${ALL_SOURCES[@]}"

echo
echo "========================================"
echo "通过 $PASS 个探针，失败 $FAIL 个"
if [ $FAIL -gt 0 ]; then
  printf '失败的：%s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
