#!/bin/bash
# AISnap 构建 / 打包 / 安装
#
#   ./build.sh              构建 .app（含图标与本地签名）
#   ./build.sh --install    构建并安装到 /Applications
#   ./build.sh --dmg        构建并额外生成 AISnap.dmg
#   ./build.sh --install --dmg
#
# 与旧版的差别（对应 CODE_REVIEW.md P3-3）：
#   * 不再硬编码 arm64 产物路径 —— 用 `swift build --show-bin-path`，Intel Mac 也能构建；
#   * 补上应用图标、LSApplicationCategoryType、NSHighResolutionCapable 等 Info.plist 键；
#   * 默认使用钥匙串里的 "AISnap Local Signing" 身份签名（稳定身份 = 屏幕录制授权不会每次重建失效），
#     没有该身份时回退到 ad-hoc。

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AISnap"
BUNDLE_ID="com.aisnap.app"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"
APP_BUNDLE="${APP_NAME}.app"
SIGN_IDENTITY="AISnap Local Signing"

DO_INSTALL=0
DO_DMG=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        --dmg)     DO_DMG=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

echo "==> 编译 Release 版本..."
swift build -c release

# 不要硬编码 .build/arm64-apple-macosx/...（Intel Mac 上是 x86_64-apple-macosx）
BUILD_DIR="$(swift build -c release --show-bin-path)"
echo "    产物目录: ${BUILD_DIR}"

echo "==> 创建 .app 结构..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [ -f "Resources/${APP_NAME}.icns" ]; then
    cp "Resources/${APP_NAME}.icns" "${APP_BUNDLE}/Contents/Resources/${APP_NAME}.icns"
else
    echo "    (提示: 未找到 Resources/${APP_NAME}.icns，将使用系统通用图标)"
fi

echo "==> 生成 Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 代码签名..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
    echo "    已使用本地身份签名: ${SIGN_IDENTITY}"
    echo "    （稳定签名身份可避免每次重建后屏幕录制授权失效）"
else
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
    echo "    未找到 \"${SIGN_IDENTITY}\" 身份，已退回 ad-hoc 签名"
    echo "    注意：ad-hoc 的 cdhash 每次重建都会变，屏幕录制授权可能需要重新授予"
fi
codesign --verify --verbose=1 "${APP_BUNDLE}" 2>&1 | tail -1 || true

if [ "${DO_DMG}" -eq 1 ]; then
    DMG_NAME="${APP_NAME}.dmg"
    DMG_TEMP="dmg_temp"
    echo "==> 创建 DMG..."
    rm -rf "${DMG_TEMP}" "${DMG_NAME}"
    mkdir -p "${DMG_TEMP}"
    cp -r "${APP_BUNDLE}" "${DMG_TEMP}/"
    ln -s /Applications "${DMG_TEMP}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TEMP}" -ov -format UDZO "${DMG_NAME}"
    rm -rf "${DMG_TEMP}"
    echo "    ${DMG_NAME}"
fi

if [ "${DO_INSTALL}" -eq 1 ]; then
    echo "==> 安装到 /Applications..."
    if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
        echo "    检测到正在运行的 ${APP_NAME}，先退出"
        pkill -x "${APP_NAME}" || true
        sleep 1
    fi
    rm -rf "/Applications/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
    echo "    已安装: /Applications/${APP_BUNDLE}"
fi

echo ""
echo "==> 完成"
echo "  ${APP_BUNDLE}   — 可直接 open 运行"
[ "${DO_INSTALL}" -eq 1 ] && echo "  /Applications/${APP_BUNDLE} — 已安装"
[ "${DO_DMG}" -eq 1 ] && echo "  ${APP_NAME}.dmg — 可分发的安装包"
exit 0
