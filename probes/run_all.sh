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
run_probe hotkey_ignore_probe    Sources/Models.swift Sources/Preferences.swift Sources/HotkeyManager.swift
run_probe cyclic_index_probe     Sources/Models.swift
run_probe text_shape_probe       Sources/Models.swift
run_probe screen_geometry_probe  Sources/Capture/ScreenGeometry.swift
run_probe anchored_placement_probe Sources/AnchoredPlacement.swift
run_probe overlay_style_probe    Sources/OverlayWindowStyle.swift
run_probe toolbar_layout_probe   Sources/ToolbarLayout.swift
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
run_probe toolbar_width_probe    "${ALL_SOURCES[@]}"
# 本轮修复的回归探针：整模块（要构造真实画布与标注窗口）
run_probe postfix_probe          "${ALL_SOURCES[@]}"
# A 区分叉里那些 master 仍然缺失的修复：重新实现后的对齐验证
run_probe master_parity_probe    "${ALL_SOURCES[@]}"

# ── 清理测试偏好域 ─────────────────────────────────────────────────────
#
# prefs_probe / hotkey_probe 会用 UserDefaults(suiteName:) 建一个隔离的测试域。
# 早期 suite 名带 UUID()，于是**每跑一次就往 ~/Library/Preferences 里多一个 plist**
# （实测在用户机器上累积了 24 个）。
#
# 现在 suite 名固定了（不会累积），但探针**自己删不干净**：removePersistentDomain
# 清的是进程视角的域，而持久化由 cfprefsd 负责 —— 实测 prefs_probe 删掉之后
# 文件又被写了回来。
#
# 所以放到这里、探针**退出之后**删：那时 cfprefsd 已经没有客户端，
# 不会再把它写回来。名字限定 com.aisnap.probe.*，不会误删别的东西。
#
# 而且要「等一下再删、删完复查」：cfprefsd 是**异步落盘**的，探针刚退出时
# 写入可能还没到磁盘 —— 立刻删等于删了个空气，文件随后才出现（实测踩到）。
for _attempt in 1 2 3 4 5; do
  removed=0
  for f in "$HOME"/Library/Preferences/com.aisnap.probe.*.plist; do
    if [ -e "$f" ]; then rm -f "$f"; removed=1; fi
  done
  [ "$removed" = "0" ] && break
  sleep 0.3
done

echo
echo "========================================"
echo "通过 $PASS 个探针，失败 $FAIL 个"
if [ $FAIL -gt 0 ]; then
  printf '失败的：%s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
