#!/bin/bash
# 生成分发包 DMG（用户下载 → 拖入 Applications → 双击即用）
# 依赖：scripts/package-app.sh 产物 build/ParallelWorkbench.app
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?请通过 VERSION=X.Y.Z 指定 DMG 版本}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $VERSION"; exit 1; }
APP="build/ParallelWorkbench.app"
[ -d "$APP" ] || VERSION="$VERSION" bash scripts/package-app.sh > /dev/null
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || {
  echo "❌ App 版本与 DMG 文件名不一致：App=$APP_VERSION DMG=$VERSION"
  exit 1
}

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# DMG 内醒目安装说明（无开发者账号分发模式下，把首次打开的指引放到用户眼前）
cat > "$STAGE/请先读我 - 安装说明.txt" <<'TXT'
智囊 · Braintrust 安装说明

【推荐 · 完全无弹窗】在「终端」粘贴下面一条命令即可完成安装并启动：

curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash

【手动安装】把「智囊」拖进 Applications 后双击打开：
首次打开若提示「无法验证开发者」，请右键点击应用 → 选择「打开」→ 再点「打开」。
只需要这样做一次，之后双击即可正常打开。

提示：本应用为开源未签名分发（ad-hoc 签名）。若希望完全消除提示，
请通过上面的一键安装命令安装（该路径会自动移除隔离属性）。
TXT

DMG="build/ParallelWorkbench-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "智囊" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

echo "✅ DMG 已生成：$DMG"
echo "   用户安装：打开 DMG → 阅读「请先读我」→ 一键命令（无弹窗）或拖入 Applications 后右键打开一次"
