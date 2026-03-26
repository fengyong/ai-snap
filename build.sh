#!/bin/bash
set -e

APP_NAME="AISnap"
BUNDLE_ID="com.aisnap.app"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> 编译 Release 版本..."
swift build -c release

echo "==> 创建 .app 结构..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 复制可执行文件
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# 生成 Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AISnap</string>
    <key>CFBundleDisplayName</key>
    <string>AISnap</string>
    <key>CFBundleIdentifier</key>
    <string>com.aisnap.app</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>AISnap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AISnap 需要屏幕录制权限来进行截图</string>
</dict>
</plist>
PLIST

echo "==> .app 打包完成"

# 创建 DMG
DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="dmg_temp"
VOLUME_NAME="${APP_NAME}"

echo "==> 创建 DMG..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

# 复制 .app 到临时目录
cp -r "${APP_BUNDLE}" "${DMG_TEMP}/"

# 创建指向 /Applications 的快捷方式
ln -s /Applications "${DMG_TEMP}/Applications"

# 生成 DMG
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

rm -rf "${DMG_TEMP}"

echo ""
echo "==> 全部完成"
echo "  ${APP_BUNDLE}  — 可直接 open 运行"
echo "  ${DMG_NAME}    — 可分发的安装包"
