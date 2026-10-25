#!/bin/bash
# 从构建 stage 生成可拖拽安装的 DMG；不依赖 Apple Developer/公证。
# 用法：build-dmg.sh <stage-dir> <output.dmg> [version]
set -euo pipefail

STAGE="${1:?usage: build-dmg.sh <stage-dir> <output.dmg> [version]}"
OUT="${2:?usage: build-dmg.sh <stage-dir> <output.dmg> [version]}"
VERSION="${3:-0.6.0}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$STAGE/local-service"
ICON="$STAGE/assets/AppIcon.icns"

[ -d "$PAYLOAD" ] || { echo "missing payload: $PAYLOAD" >&2; exit 1; }
[ -f "$PAYLOAD/server.mjs" ] || { echo "missing server.mjs" >&2; exit 1; }
[ -f "$ICON" ] || { echo "missing AppIcon.icns" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/braintrust-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/智囊.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

/usr/bin/ditto "$ROOT/launcher.sh" "$APP/Contents/MacOS/BraintrustLauncher"
chmod +x "$APP/Contents/MacOS/BraintrustLauncher"
/usr/bin/ditto "$ICON" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$PAYLOAD" "$APP/Contents/Resources/service"

cat > "$APP/Contents/Resources/config.sh" <<CONFIG
INSTALL_ROOT="\$APP_ROOT/Contents/Resources/service"
DATA_DIR="\$HOME/Library/Application Support/Braintrust/data"
VERSION="$VERSION"
CONFIG

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>智囊</string>
  <key>CFBundleDisplayName</key><string>智囊</string>
  <key>CFBundleExecutable</key><string>BraintrustLauncher</string>
  <key>CFBundleIdentifier</key><string>chat.braintrust.local-service</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 智囊 · Braintrust</string>
</dict>
</plist>
PLIST

# ad-hoc 签名；没有 Apple Developer 证书也能在本机运行。
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

DMGROOT="$WORK/dmg"
mkdir -p "$DMGROOT"
/usr/bin/ditto "$APP" "$DMGROOT/智囊.app"
ln -s /Applications "$DMGROOT/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
/usr/bin/hdiutil create -volname "智囊" -srcfolder "$DMGROOT" -ov -format UDZO "$OUT" >/dev/null
/usr/bin/hdiutil verify "$OUT" >/dev/null
echo "created $OUT"
echo "size: $(/usr/bin/du -h "$OUT" | cut -f1)"
echo "sha256: $(/usr/bin/shasum -a 256 "$OUT" | awk '{print $1}')"
