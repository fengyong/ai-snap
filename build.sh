#!/bin/bash
#
# 打包成可安装的 AISnap.app 与 AISnap.dmg。
#
#   ./build.sh                完整打包
#   ./build.sh --skip-dmg     只出 .app（开发时快一些）
#   ./build.sh --install      打包并安装到 /Applications
#   ./build.sh --skip-dmg --install    常用组合：快出包 + 直接装上
#
# 环境变量：
#   BUILD_NUMBER   构建号（默认时间戳）
#   SWIFT_FLAGS    透传给 swift build 的额外参数。默认空。
#                  在**已经被沙箱包裹**的环境里（CI 容器、自动化工具）SwiftPM 给清单
#                  编译套的那层 sandbox-exec 会以 "sandbox_apply: Operation not permitted"
#                  失败，此时用 SWIFT_FLAGS=--disable-sandbox 绕过。默认不关 ——
#                  那层沙箱是为了防止恶意 Package.swift 在构建期乱来，能留就留。
#
# 与原脚本相比修掉的几处（都会在安装后暴露，编译期看不出来）：
#   · BUILD_DIR 写死成 arm64 路径 —— 换机器 / Intel 上直接找不到产物
#   · Info.plist 里版本写 1.0.0，而代码里 AppInfo.bundledFallbackVersion 是 0.1.0，
#     更新检查会拿这两个数比大小（现在脚本会强制校验两者一致）
#   · 完全不签名 —— 没有签名的 .app 在屏幕录制权限上会被系统当成"每次都是新应用"
#   · 没有图标、没声明 NSHighResolutionCapable
#
set -euo pipefail

APP_NAME="AISnap"
BUNDLE_ID="com.aisnap.app"
# ★ 版本号单一来源。与 Sources/Update/UpdateChecker.swift 里的
#   AppInfo.bundledFallbackVersion 必须一致（下面会校验，不一致直接失败）。
VERSION="0.1.0"
# 构建号：默认用时间戳，便于区分两次构建出来的包
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"

SKIP_DMG=0
DO_INSTALL=0
# 安装目标目录。做成可覆盖的，是为了让「删除旧版本」这段破坏性逻辑
# 能对着临时目录离屏验证，而不用拿真的 /Applications 去试。
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# 选项可任意顺序组合
for arg in "$@"; do
  case "$arg" in
    --skip-dmg) SKIP_DMG=1 ;;
    --install)  DO_INSTALL=1 ;;
    # ${arg} 的花括号不能省：后面紧跟的是中文全角括号，bash 会把那几个多字节
    # 字节当成变量名的一部分，在 set -u 下报 "unbound variable"（实测踩到）
    *) echo "未知参数：${arg}（可用：--skip-dmg / --install）" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ── 0. 版本号一致性校验 ────────────────────────────────────────────────
step "校验版本号一致"
CODE_VERSION=$(grep -oE 'bundledFallbackVersion[[:space:]]*=[[:space:]]*"[^"]+"' \
                 Sources/Update/UpdateChecker.swift | head -1 | sed -E 's/.*"([^"]+)"/\1/')
if [ -z "$CODE_VERSION" ]; then
  echo "❌ 没能从 UpdateChecker.swift 读到 bundledFallbackVersion" >&2
  exit 1
fi
if [ "$CODE_VERSION" != "$VERSION" ]; then
  cat >&2 <<EOF
❌ 版本号不一致：
     本脚本 VERSION          = $VERSION
     AppInfo.bundledFallback = $CODE_VERSION

   两处必须相同。否则「检查更新」会拿打包进去的版本号与代码里的兜底值互相比大小，
   得出"有新版本"或"已是最新"的错误结论，而且不会有任何报错。
EOF
  exit 1
fi
# 注意：变量后面紧跟中文（或任何非 ASCII）字符时必须写成 ${VAR} ——
# bash 解析变量名时会一直吃到非标识符字节，而多字节汉字的第一个字节会被它吞进去，
# 于是报出 "VERSION\xef: unbound variable" 这种看不懂的错。
echo "版本 ${VERSION}（构建号 ${BUILD_NUMBER}），两处一致"

# ── 1. 编译 ───────────────────────────────────────────────────────────
step "编译 Release"
SWIFT_FLAGS="${SWIFT_FLAGS:-}"
# shellcheck disable=SC2086  # 这里就是要让 SWIFT_FLAGS 按空格拆成多个参数
swift build -c release $SWIFT_FLAGS
BIN_DIR="$(swift build -c release --show-bin-path $SWIFT_FLAGS)"
BIN_PATH="$BIN_DIR/$APP_NAME"
[ -x "$BIN_PATH" ] || { echo "❌ 找不到可执行文件：$BIN_PATH" >&2; exit 1; }

# ── 2. 组装 .app ──────────────────────────────────────────────────────
step "组装 $APP_NAME.app"
APP_BUNDLE="$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 图标（.icns 不存在时自动生成）
if [ ! -f "Assets/$APP_NAME.icns" ]; then
  echo "生成图标…"
  swift scripts/make_icon.swift Assets/AppIcon-1024.png
  ICONSET="$(mktemp -d)/$APP_NAME.iconset"
  mkdir -p "$ICONSET"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
              "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
              "512 512x512" "1024 512x512@2x"; do
    px="${spec%% *}"; name="${spec##* }"
    sips -z "$px" "$px" Assets/AppIcon-1024.png \
         --out "$ICONSET/icon_$name.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "Assets/$APP_NAME.icns"
  rm -rf "$(dirname "$ICONSET")"
fi
cp "Assets/$APP_NAME.icns" "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <!-- 常驻状态栏、不占 Dock（代码里也设了 .accessory，两处一致） -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
echo "已写入 Info.plist（${VERSION} / ${BUILD_NUMBER}）"

# ── 3. 签名 ───────────────────────────────────────────────────────────
#
# 没有 Apple Developer 账号，所以只能 ad-hoc 签名（-s -）。
# 这不是"正式签名"，但比完全不签强：
#   · 系统会把应用当成一个有身份的包，而不是"来历不明的可执行文件"
#   · 屏幕录制权限的授权对象是 AISnap 自己，而不是启动它的终端
# ⚠️ 没有证书时回退 ad-hoc：TCC 按 cdhash 认应用，**每次重新编译安装，
#    屏幕录制权限都要重新勾一次**。配一张自签名证书即可根治（见下方说明）。
# 两种签名方式的区别，直接决定「屏幕录制权限会不会反复失效」：
#
#   ad-hoc（--sign -）
#     没有证书标识，TCC 只能按 **cdhash** 关联授权 —— 而 cdhash 是二进制内容的
#     哈希，于是**每重新编译一次，授权就失效一次**，用户得再去系统设置里勾一遍。
#
#   自签名证书
#     有稳定的签名标识，TCC 按 **证书 + bundle ID** 关联，
#     重新编译、重新安装都不会让授权失效。
#
# 所以优先用证书；没有证书才回退 ad-hoc，并把代价明确说出来。
SIGN_IDENTITY="${SIGN_IDENTITY:-AISnap Local Signing}"
step "签名"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# 三种状态必须分开报，否则会误导：
#   ① 身份有效           → 用证书签名
#   ② 证书在、但不受信任  → 用户会以为"没建成功"而重新生成一遍，其实只差设信任
#   ③ 完全没有证书        → 让他去跑生成脚本
# ②是实际踩到的：脚本跑完、证书进了钥匙串，但 security 报 CSSMERR_TP_NOT_TRUSTED，
# `find-identity -v`（只列有效身份）看不到它，于是笼统地报"未找到"。
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  codesign --verify --strict --verbose=1 "$APP_BUNDLE"
  echo "✅ 用自签名证书「${SIGN_IDENTITY}」签名"
  echo "   重新编译不会让屏幕录制权限失效"
elif security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  codesign --verify --strict --verbose=1 "$APP_BUNDLE"
  cat <<EOF
⚠️  证书「${SIGN_IDENTITY}」**已经在钥匙串里了**，但还不受信任
    （security 报 CSSMERR_TP_NOT_TRUSTED），所以 codesign 用不了它。
    本次已回退 ad-hoc 签名。

    设信任是一次性操作，约 30 秒：
      1. 打开「钥匙串访问」→ 左侧选「登录」→ 选「我的证书」
      2. 找到「${SIGN_IDENTITY}」，双击
      3. 展开「信任」→ 把「代码签名」设为「始终信任」
      4. 关闭窗口（会要求输入登录密码）

    完成后重新运行 ./build.sh，就会自动改用它签名。
EOF
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  codesign --verify --strict --verbose=1 "$APP_BUNDLE"
  cat <<EOF
⚠️  没有找到代码签名证书「${SIGN_IDENTITY}」，已回退 ad-hoc 签名。

    ad-hoc 下 TCC 按 cdhash 认应用，而 cdhash 随二进制变化 ——
    每重新编译安装一次，屏幕录制权限就要在系统设置里**重新勾一次**。

    一次性配置（不需要 Apple Developer 账号）：
      ./scripts/make_signing_cert.sh
EOF
fi
echo "签名校验通过"
codesign -dv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Signature|Authority|TeamIdentifier" | sed 's/^/   /'

# ── 4. 安装到 /Applications（可选）────────────────────────────────────
#
# 必须放在 SKIP_DMG 的提前 return **之前**，否则 `--skip-dmg --install` 会直接退出、装不上。
if [ "$DO_INSTALL" = "1" ]; then
  step "安装到 $INSTALL_DIR"
  TARGET="$INSTALL_DIR/$APP_BUNDLE"

  if [ ! -d "$INSTALL_DIR" ]; then
    echo "❌ 目标目录不存在：$INSTALL_DIR" >&2
    exit 1
  fi

  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    # 用 rm -rf **删除**旧版本，而不是移到废纸篓。
    #
    # 移到废纸篓会一直堆：实测用户废纸篓里堆了 8 个旧 AISnap（Finder 还会给重名的
    # 加时间戳后缀），而且 LaunchServices 会保留那些失效路径的注册 ——
    # 结果是「打开方式」和 Spotlight 里冒出一堆重复的 AISnap，用户以为装了多个。
    rm -rf "$TARGET"
    echo "  已删除旧版本：$TARGET"
  fi
  cp -R "$APP_BUNDLE" "$TARGET"
  echo "  已安装：$TARGET"

  # 立刻把这份注册给 LaunchServices，别留着旧路径的注册指向已经不存在的包
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1; then
    echo "  已刷新 LaunchServices 注册"
  fi
fi

if [ "$SKIP_DMG" = "1" ]; then
  step "完成（已跳过 DMG）"
  echo "  $(pwd)/$APP_BUNDLE"
  [ "$DO_INSTALL" = "1" ] && echo "  已安装：$INSTALL_DIR/$APP_BUNDLE"
  exit 0
fi

# ── 4. DMG ────────────────────────────────────────────────────────────
step "创建 DMG"
DMG_NAME="$APP_NAME.dmg"
DMG_TEMP="$(mktemp -d)/dmg"
mkdir -p "$DMG_TEMP"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
# 拖进「应用程序」的快捷方式 —— 安装流程就靠它
ln -s /Applications "$DMG_TEMP/Applications"
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" \
               -ov -format UDZO -quiet "$DMG_NAME"
rm -rf "$DMG_TEMP"

# ── 5. 验证 DMG（这一步才是"能不能装"的真正判据）────────────────────
step "验证 DMG"
# 挂载点必须在**任何**退出路径上卸载。
#
# 原先只在验证末尾 detach：脚本开头是 `set -euo pipefail`，中间任何一步失败
# （或脚本被 Ctrl-C / 被中断）都会**跳过**那一行，DMG 就永久挂在 /Volumes 下。
# 后果不只是"桌面上多出一个盘"：
#   下一次挂载占不到原名，会变成 "AISnap 1"；
#   而用户很可能直接从残留卷里运行应用 —— 那跑的是**另一个 cdhash 的副本**。
#   ad-hoc 签名下 TCC 是按 cdhash 认应用的，于是系统又要求授权一次。
# 这是「反复要求屏幕录制权限」的来源之一。
DMG_MOUNT=""
detach_dmg() {
  if [ -n "$DMG_MOUNT" ]; then
    hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true
    DMG_MOUNT=""
  fi
}
trap detach_dmg EXIT

ATTACH_OUT=$(hdiutil attach "$DMG_NAME" -nobrowse -readonly)
MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -oE '/Volumes/.*' | head -1)
DMG_MOUNT="$MOUNT_POINT"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/$APP_NAME.app" ]; then
  echo "❌ 挂载后找不到 $APP_NAME.app" >&2
  exit 1
fi
echo "挂载点：$MOUNT_POINT"
echo "  内含：$(ls "$MOUNT_POINT" | tr '\n' ' ')"
codesign --verify --strict "$MOUNT_POINT/$APP_NAME.app" && echo "  包内签名校验通过"
[ -L "$MOUNT_POINT/Applications" ] && echo "  存在指向 /Applications 的快捷方式"
detach_dmg

step "全部完成"
printf '  %s/%s\n     可直接 open 运行\n' "$(pwd)" "$APP_BUNDLE"
printf '  %s/%s  (%s)\n     安装包\n' "$(pwd)" "$DMG_NAME" "$(du -h "$DMG_NAME" | cut -f1)"
cat <<'EOF'

安装：双击 dmg → 把 AISnap 拖进「应用程序」→ 从「应用程序」启动。
首次启动会请求「屏幕录制」权限，到 系统设置 → 隐私与安全性 → 屏幕录制
里勾上 AISnap，然后重启一次 AISnap（权限生效需要重启应用）。
EOF
