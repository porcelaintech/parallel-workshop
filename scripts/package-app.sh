#!/bin/bash
# 打包 ParallelWorkbench.app（未签名，本地/信任来源分发用）
# 用法: bash scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PWB_APP_VERSION="${VERSION:-$(python3 -c 'import json; print(json.load(open("Windows/edge-extension/manifest.json"))["version"])')}"
[[ "$PWB_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $PWB_APP_VERSION"; exit 1; }

APP="build/ParallelWorkbench.app"
PACKAGE_SCRATCH="${PWB_PACKAGE_SCRATCH:-.build/package-app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 release 版（Apple 芯片 + Intel 通用）"
swift build --scratch-path "$PACKAGE_SCRATCH" -c release --arch arm64
swift build --scratch-path "$PACKAGE_SCRATCH" -c release --arch x86_64

ARM="$PACKAGE_SCRATCH/arm64-apple-macosx/release/ParallelWorkbench"
X64="$PACKAGE_SCRATCH/x86_64-apple-macosx/release/ParallelWorkbench"
APP_BINARY="$APP/Contents/MacOS/ParallelWorkbench"
if [ ! -f "$ARM" ]; then
  echo "❌ release 二进制缺失: $ARM"
  exit 1
fi
if [ -f "$X64" ]; then
  echo "==> 合并通用二进制（arm64 + x86_64）"
  lipo -create "$ARM" "$X64" -output "$APP_BINARY"
else
  cp "$ARM" "$APP_BINARY"
fi
chmod +x "$APP_BINARY"
lipo -info "$APP_BINARY"

echo "==> 复制资源 bundle"
for b in "$PACKAGE_SCRATCH"/arm64-apple-macosx/release/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

echo "==> 生成图标"
rm -rf build/AppIcon.iconset
rm -f build/AppIcon.icns
swift scripts/icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 渠道：direct（Developer ID/DMG 直发，bundle id 保持历史值以兼容既有登录态）
#       appstore（Mac App Store：反向域名 bundle id + PWBChannel 标记，更新检查自动关闭）
CHANNEL="${PWB_CHANNEL:-direct}"
if [ "$CHANNEL" = "appstore" ]; then
  BUNDLE_ID="com.porcelaintech.braintrust"
  CHANNEL_KEYS="	<key>PWBChannel</key>
	<string>appstore</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>"
else
  BUNDLE_ID="ParallelWorkbench"
  CHANNEL_KEYS="	<key>PWBChannel</key>
	<string>direct</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>智囊</string>
	<key>CFBundleDisplayName</key>
	<string>智囊</string>
	<key>CFBundleExecutable</key>
	<string>ParallelWorkbench</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${PWB_APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>用于将你的语音转成文字并填入提问输入框</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>用于语音输入提问</string>
${CHANNEL_KEYS}
</dict>
</plist>
PLIST

echo ""
echo "✅ 已生成 ${APP}（未签名，仅限本机或信任来源使用）"
echo "   双击运行：open \"${APP}\""
