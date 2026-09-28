#!/bin/bash
#
# 一键发版：版本号 → 构建 → GitHub Release → 更新清单 → 提交推送。
#
# ## 为什么需要它
#
# 本项目的「发版」要同时动四个地方，**漏掉任何一处都不会有任何报错**，
# 只会在用户那边表现为"检查更新永远说已是最新"或"下载到的还是旧包"：
#
#   1. `build.sh` 的 `VERSION`
#   2. `UpdateChecker.swift` 的 `AppInfo.bundledFallbackVersion`
#      （build.sh 会校验两者一致，不一致直接构建失败）
#   3. `latest.json` 的 `version` —— **应用读的就是它**，忘了改等于没发新版
#   4. GitHub Release 的 tag 与附件 —— 清单里的 downloadURL 指向
#      `releases/latest/download/AISnap.dmg`，没有对应的 release 就是 404
#
# 这个脚本按固定顺序把这四处一起改掉，并在每一步之后校验结果。
#
# ## 用法
#
#   ./scripts/release.sh 0.1.1                  完整发版（含装到本机）
#   ./scripts/release.sh 0.1.1 --dry-run        只做检查与打印，不改任何东西
#   ./scripts/release.sh 0.1.1 --notes "说明"   自定义 release 说明
#   ./scripts/release.sh 0.1.1 --no-install     不装到本机
#   ./scripts/release.sh 0.1.1 --no-push        只到本地提交为止
#
# 发版前需要：gh 已登录且有 repo 权限（`gh auth status` 里活动账号是仓库所有者的）。
#
set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$PWD"
DMG_NAME="AISnap.dmg"
MANIFEST="latest.json"
BUILD_SCRIPT="build.sh"
VERSION_FILE="Sources/Update/UpdateChecker.swift"

DO_INSTALL=1
DO_PUSH=1
DRY_RUN=0
NOTES=""

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m❌ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '   %s\n' "$1"; }

# ── 0. 参数 ────────────────────────────────────────────────────────────

NEW_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --no-push)    DO_PUSH=0 ;;
    --notes)      shift; NOTES="${1:-}" ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    -*)           die "未知参数：$1（可用：--dry-run / --no-install / --no-push / --notes）" ;;
    *)            NEW_VERSION="$1" ;;
  esac
  shift
done

[ -n "$NEW_VERSION" ] || die "必须给出版本号，例如：./scripts/release.sh 0.1.1"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "版本号格式应为 X.Y.Z（收到「${NEW_VERSION}」）"

# ── 1. 读现状 ──────────────────────────────────────────────────────────

step "读取当前版本"

read_build_version() {
  grep -oE '^VERSION="[^"]+"' "$BUILD_SCRIPT" | head -1 | sed -E 's/.*"([^"]+)"/\1/'
}
read_code_version() {
  grep -oE 'bundledFallbackVersion[[:space:]]*=[[:space:]]*"[^"]+"' "$VERSION_FILE" \
    | head -1 | sed -E 's/.*"([^"]+)"/\1/'
}
read_manifest_version() {
  [ -f "$MANIFEST" ] || { echo ""; return; }
  python3 -c "import json,sys;print(json.load(open('$MANIFEST')).get('version',''))" 2>/dev/null || echo ""
}

BUILD_VERSION="$(read_build_version)"
CODE_VERSION="$(read_code_version)"
MANIFEST_VERSION="$(read_manifest_version)"

info "build.sh VERSION              = $BUILD_VERSION"
info "bundledFallbackVersion        = $CODE_VERSION"
info "latest.json version           = ${MANIFEST_VERSION:-（无清单）}"
info "新版本                        = $NEW_VERSION"

[ "$BUILD_VERSION" = "$CODE_VERSION" ] || die "发版前两个版本号就已经不一致，先修好再来"
[ "$BUILD_VERSION" != "$NEW_VERSION" ] || die "新版本号与当前相同（${NEW_VERSION}），没有东西可发"

# 版本必须**递增**：应用是用 AppVersion 比大小的，降级会让所有人都收不到更新
if ! python3 - "$BUILD_VERSION" "$NEW_VERSION" <<'PY'
import sys
def parse(v): return [int(x) for x in v.split('.')]
sys.exit(0 if parse(sys.argv[2]) > parse(sys.argv[1]) else 1)
PY
then
  die "$NEW_VERSION 不大于当前版本 ${BUILD_VERSION}（必须递增，否则更新检查判不出来）"
fi

# 只检查**本脚本会改的那几个文件**是否干净。工作区其它地方的改动无所谓：
# 提交时是逐个 git add 明确路径的，不会把它们扫进来。
TOUCHED=("$BUILD_SCRIPT" "$VERSION_FILE" "$MANIFEST")
git ls-files --error-unmatch "$DMG_NAME" >/dev/null 2>&1 && TOUCHED+=("$DMG_NAME")
DIRTY="$(git status --porcelain -- "${TOUCHED[@]}")"
if [ "$DRY_RUN" != "1" ] && [ -n "$DIRTY" ]; then
  printf '\033[1;31m❌ 发版要改的文件有未提交改动，先提交或 stash：\033[0m\n%s\n' "$DIRTY" >&2
  exit 1
fi

step "检查前置条件"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
info "分支：$BRANCH"
[ "$BRANCH" = "master" ] || die "只在 master 上发版（当前：${BRANCH}）"
command -v gh >/dev/null || die "找不到 gh（GitHub CLI）"
if [ "$DO_PUSH" = "1" ]; then
  gh auth status >/dev/null 2>&1 || die "gh 未登录，先跑 gh auth login"
  GH_USER="$(gh api user --jq .login 2>/dev/null || echo '?')"
  info "gh 活动账号：$GH_USER"
fi
git rev-parse "v$NEW_VERSION" >/dev/null 2>&1 && die "tag v$NEW_VERSION 已存在"
info "tag v$NEW_VERSION 可用"

if [ "$DRY_RUN" = "1" ]; then
  step "dry-run：以上检查都通过，未改动任何文件"
  info "将执行：改 $BUILD_SCRIPT / $VERSION_FILE / $MANIFEST → 构建 → 提交 → push → gh release create"
  exit 0
fi

# ── 2. 改版本号（三处）────────────────────────────────────────────────

step "把版本号改成 $NEW_VERSION"
python3 - "$BUILD_SCRIPT" "$VERSION_FILE" "$MANIFEST" "$NEW_VERSION" <<'PY'
import json, re, sys
build_sh, version_file, manifest, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

p = open(build_sh).read()
p2 = re.sub(r'^VERSION="[^"]+"', f'VERSION="{new}"', p, count=1, flags=re.M)
assert p2 != p, 'build.sh 的 VERSION 没被替换'
open(build_sh, 'w').write(p2)

p = open(version_file).read()
p2 = re.sub(r'(bundledFallbackVersion\s*=\s*")[^"]+(")', rf'\g<1>{new}\g<2>', p, count=1)
assert p2 != p, 'bundledFallbackVersion 没被替换'
open(version_file, 'w').write(p2)

try:
    data = json.load(open(manifest))
except Exception:
    data = {"downloadURL": "", "notes": ""}
data['version'] = new
json.dump(data, open(manifest, 'w'), ensure_ascii=False, indent=2)
open(manifest, 'a').write('\n')
PY
info "build.sh            → $NEW_VERSION"
info "UpdateChecker.swift → $NEW_VERSION"
info "latest.json         → $NEW_VERSION"

# ── 3. 构建（build.sh 自己会再校验一次两处版本一致）─────────────────────

step "构建"
if [ "$DO_INSTALL" = "1" ]; then
  ./build.sh --install
else
  ./build.sh
fi

[ -f "$DMG_NAME" ] || die "构建结束但没有 $DMG_NAME"
info "DMG：$(du -h "$DMG_NAME" | cut -f1)"

# 校验打进包里的版本确实是新版本（构建脚本读的就是 build.sh 的 VERSION，这里复核一遍）
MOUNT="$(hdiutil attach "$DMG_NAME" -nobrowse -readonly | grep -oE '/Volumes/.*' | head -1)"
trap '[ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$MOUNT/AISnap.app/Contents/Info.plist")"
[ "$APP_VERSION" = "$NEW_VERSION" ] || die "包内版本是 ${APP_VERSION}，不是 $NEW_VERSION"
APP_BUILD="$(plutil -extract CFBundleVersion raw "$MOUNT/AISnap.app/Contents/Info.plist")"
info "包内版本：$APP_VERSION / $APP_BUILD"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# ── 4. 提交（代码 + 清单 + DMG 一起，保证 tag 指向的内容自洽）────────────

step "提交并推送"
git add "$BUILD_SCRIPT" "$VERSION_FILE" "$MANIFEST"
# DMG 只有本来就被跟踪时才一起提交；没跟踪就只作为 release 附件（不进 git 历史）
if git ls-files --error-unmatch "$DMG_NAME" >/dev/null 2>&1; then
  git add "$DMG_NAME"
  info "已暂存 ${DMG_NAME}（仓库本来就在跟踪它）"
else
  info "$DMG_NAME 未被跟踪，只作为 release 附件"
fi

[ -z "$NOTES" ] && NOTES="$(git log --oneline "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~1)"..HEAD 2>/dev/null | sed 's/^[0-9a-f]* //' | head -20 || true)"
[ -n "$NOTES" ] || NOTES="AISnap $NEW_VERSION"

git commit -F - <<EOF
release: $NEW_VERSION

版本号三处同步（build.sh / UpdateChecker.swift / latest.json），
并重新打包 DMG。发版说明：

$NOTES
EOF

if [ "$DO_PUSH" = "1" ]; then
  git push origin master
else
  info "--no-push：已本地提交，未推送"
fi

# ── 5. 建 release（tag 落在刚推的那个提交上）──────────────────────────

step "创建 GitHub Release v$NEW_VERSION"
if [ "$DO_PUSH" = "1" ]; then
  gh release create "v$NEW_VERSION" "$DMG_NAME" \
    --title "AISnap $NEW_VERSION" \
    --notes "$NOTES"
else
  info "--no-push：跳过（release 需要先把 tag 推上去）"
fi

# ── 6. 收尾 ────────────────────────────────────────────────────────────

step "完成"
SLUG="$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')"
printf '  版本     : %s\n' "$NEW_VERSION"
printf '  Release  : https://github.com/%s/releases/tag/v%s\n' "$SLUG" "$NEW_VERSION"
printf '  固定下载 : https://github.com/%s/releases/latest/download/%s\n' "$SLUG" "$DMG_NAME"
printf '  清单     : %s（version=%s）\n' "$MANIFEST" "$(read_manifest_version)"
cat <<'EOF'

下次发版前记得：应用只有在 latest.json 里的 version **大于**已装版本时才会提示更新。
EOF
