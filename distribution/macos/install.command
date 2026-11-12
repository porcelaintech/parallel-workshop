#!/bin/bash
# 智囊本地服务 macOS 安装器：复制服务、生成未签名的 智囊.app、创建桌面入口。
# 不使用 sudo；不写入 /Applications；不需要 Apple Developer 会员或公证。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$SCRIPT_DIR/local-service"
ASSETS="$SCRIPT_DIR/assets"
INSTALL_ROOT="${BRAINTRUST_INSTALL_ROOT:-$HOME/Library/Application Support/Braintrust/service}"
DATA_DIR="${BRAINTRUST_DATA_DIR:-$HOME/Library/Application Support/Braintrust/data}"
APPS_DIR="${BRAINTRUST_APPS_DIR:-$HOME/Applications}"
APP="$APPS_DIR/智囊.app"

show_error() {
  /usr/bin/osascript -e 'on run argv' -e 'display dialog (item 1 of argv) buttons {"好"} default button 1 with icon caution' -e 'end run' "$1" >/dev/null 2>&1 || true
}

fail() {
  echo "❌ $1" >&2
  show_error "$1"
  exit 1
}

trap 'fail "安装失败（install.command 第 $LINENO 行）。请把终端里的错误信息发给开发者。"' ERR

[ "$(id -u)" != "0" ] || fail "不要用 sudo 安装智囊。请用当前用户双击 install.command。"
[ -d "$PAYLOAD" ] || fail "安装包不完整：找不到 local-service 目录。请重新下载完整 zip。"
[ -f "$PAYLOAD/server.mjs" ] || fail "安装包不完整：local-service/server.mjs 缺失。"
[ -f "$SCRIPT_DIR/launcher.sh" ] || fail "安装包不完整：launcher.sh 缺失。"
[ -f "$ASSETS/AppIcon.icns" ] || fail "安装包不完整：assets/AppIcon.icns 缺失。"

VERSION="$(/usr/bin/grep -m1 '"version"' "$PAYLOAD/package.json" 2>/dev/null | /usr/bin/sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || VERSION="0.6.0"

echo "==> 安装智囊 v$VERSION"
echo "    服务：$INSTALL_ROOT"
echo "    数据：$DATA_DIR"

# 停掉旧服务，避免覆盖正在运行的 server.mjs。
if /usr/bin/pgrep -f "$INSTALL_ROOT/server.mjs" >/dev/null 2>&1; then
  echo "==> 停止旧服务"
  /usr/bin/pkill -TERM -f "$INSTALL_ROOT/server.mjs" 2>/dev/null || true
  sleep 1
  /usr/bin/pkill -KILL -f "$INSTALL_ROOT/server.mjs" 2>/dev/null || true
fi

# 先写到临时目录，再原子替换；data 目录不在 service 内，不会被覆盖。
TMP="$INSTALL_ROOT.new.$$"
OLD="$INSTALL_ROOT.old.$$"
rm -rf "$TMP" "$OLD"
mkdir -p "$(dirname "$INSTALL_ROOT")"
/usr/bin/ditto "$PAYLOAD" "$TMP"
if [ -d "$INSTALL_ROOT" ]; then mv "$INSTALL_ROOT" "$OLD"; fi
if ! mv "$TMP" "$INSTALL_ROOT"; then
  if [ -d "$OLD" ]; then mv "$OLD" "$INSTALL_ROOT" || true; fi
  fail "无法写入 $INSTALL_ROOT。请检查目录权限。"
fi
rm -rf "$OLD"
mkdir -p "$DATA_DIR"

echo "==> 生成本地 智囊.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$SCRIPT_DIR/launcher.sh" "$APP/Contents/MacOS/BraintrustLauncher"
chmod +x "$APP/Contents/MacOS/BraintrustLauncher"
/usr/bin/ditto "$ASSETS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

{
  printf 'INSTALL_ROOT=%q\n' "$INSTALL_ROOT"
  printf 'DATA_DIR=%q\n' "$DATA_DIR"
  printf 'VERSION=%q\n' "$VERSION"
} > "$APP/Contents/Resources/config.sh"

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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 智囊 · Braintrust</string>
</dict>
</plist>
PLIST

# 本地生成的 .app 不需要 Apple 证书；ad-hoc 签名让它成为合法的本机应用。
if /usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
  echo "    已做 ad-hoc 签名（无需 Apple Developer）"
else
  echo "    ⚠️ ad-hoc 签名失败；应用仍可本机运行"
fi
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ -d "$HOME/Desktop" ]; then
  /bin/ln -sfn "$APP" "$HOME/Desktop/智囊.app"
fi

echo "✅ 智囊已安装：$APP"
echo "   以后双击 Applications 或桌面上的「智囊」即可打开。"
echo "   日志：$HOME/Library/Logs/Braintrust/service.log"

if [ "${BRAINTRUST_NO_LAUNCH:-0}" != "1" ]; then
  if ! /usr/bin/open "$APP"; then
    show_error "智囊已安装，但自动启动失败。请到 ~/Applications 双击「智囊」。"
  fi
fi
