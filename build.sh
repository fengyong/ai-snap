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

echo "==> 打包完成: ${APP_BUNDLE}"
echo ""
echo "运行方式:"
echo "  open ${APP_BUNDLE}          # 双击打开"
echo "  ./${APP_BUNDLE}/Contents/MacOS/${APP_NAME}  # 命令行运行"
echo ""
echo "安装到应用程序文件夹:"
echo "  cp -r ${APP_BUNDLE} /Applications/"
