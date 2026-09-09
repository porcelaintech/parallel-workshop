#!/bin/bash
# Mac App Store 打包：沙盒 entitlements 签名 + productbuild 生成安装包
# 前置：
#   1. Apple Developer Program 账号，Xcode 已登录并生成
#      「3rd Party Mac Developer Application」与「3rd Party Mac Developer Installer」证书
#   2. App Store Connect 已创建 App 记录，Bundle ID = com.porcelaintech.braintrust
# 用法：
#   APPSTORE_APP_IDENTITY="3rd Party Mac Developer Application: 你的名字 (TEAMID)" \
#   APPSTORE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 你的名字 (TEAMID)" \
#   bash scripts/package-appstore.sh
# 产物：build/ParallelWorkbench-appstore.pkg → 用 Transporter 上传提审
# 注意：App Store 审核对该类内嵌第三方站点 + 注入脚本的应用有拒绝风险（4.2），
#       提审材料见 RELEASE.md「路线 C」。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APPSTORE_APP_IDENTITY:?请设置 APPSTORE_APP_IDENTITY（3rd Party Mac Developer Application 证书名）}"
: "${APPSTORE_INSTALLER_IDENTITY:?请设置 APPSTORE_INSTALLER_IDENTITY（3rd Party Mac Developer Installer 证书名）}"

APP="build/ParallelWorkbench.app"
PKG="build/ParallelWorkbench-appstore.pkg"

echo "==> 构建 App Store 渠道 .app（沙盒 bundle id + PWBChannel=appstore）"
PWB_CHANNEL=appstore bash scripts/package-app.sh > /dev/null

echo "==> 校验渠道标记"
/usr/libexec/PlistBuddy -c "Print :PWBChannel" "$APP/Contents/Info.plist" | grep -q appstore || {
  echo "❌ Info.plist 缺少 PWBChannel=appstore"; exit 1; }

echo "==> 签名 .app（App Store 证书 + 沙盒 entitlements）"
codesign --force --options runtime \
  --entitlements macOS/ParallelWorkbench.entitlements \
  --sign "$APPSTORE_APP_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 生成并签名 .pkg（App Store 提审用）"
rm -f "$PKG"
productbuild --component "$APP" /Applications "$PKG"
productsign --sign "$APPSTORE_INSTALLER_IDENTITY" "$PKG" "$PKG.signed"
mv "$PKG.signed" "$PKG"

echo ""
echo "✅ App Store 安装包已生成：$PKG"
echo "   下一步：用 Transporter 上传（App Store Connect → 我的 App → 智囊）"
echo "   提审注意事项见 RELEASE.md「路线 C：Mac App Store」"
