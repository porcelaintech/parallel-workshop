#!/bin/bash
# 构建可发布的本地服务工作台安装包（macOS/Windows），生成更新索引与 SHA256。
# 用法: bash distribution/scripts/build-release.sh 0.6.0
# 产物: build/local-service-release/<version>/artifacts/
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:-${VERSION:-0.6.0}}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $VERSION"; exit 1; }
SOURCE_VERSION="$(node -p "require('./local-service/package.json').version")"
[ "$SOURCE_VERSION" = "$VERSION" ] || { echo "❌ local-service/package.json 版本是 $SOURCE_VERSION，不是 $VERSION"; exit 1; }

REPO="porcelaintech/parallel-workshop"
ROOT="$(pwd)"
OUT="$ROOT/build/local-service-release/$VERSION"
RAW="$ROOT/build/local-service/artifacts"
RUNTIME_CACHE="${BRAINTRUST_RUNTIME_CACHE:-build/local-service-runtime-cache}"

echo "==> 1/5 构建含 Node 运行时的轻量包（浏览器使用系统 Edge/Chrome）"
BRAINTRUST_FETCH_RUNTIME=1 BRAINTRUST_FETCH_BROWSER=0 BRAINTRUST_RUNTIME_CACHE="$RUNTIME_CACHE" \
  bash scripts/package-local-service.sh >/dev/null

for f in "Braintrust-local-service-macos-$VERSION.zip" "Braintrust-local-service-windows-$VERSION.zip"; do
  [ -f "$RAW/$f" ] || { echo "❌ 缺少原始包: $RAW/$f"; exit 1; }
done

echo "==> 2/5 组装 macOS 发行包（安装器 + 本地生成的 .app 模板 + 图标）"
rm -rf "$OUT"
mkdir -p "$OUT/artifacts" "$OUT/stage/macos" "$OUT/stage/windows"
MAC_DIR="$OUT/stage/macos/Braintrust-local-service-macos-$VERSION"
unzip -q "$RAW/Braintrust-local-service-macos-$VERSION.zip" -d "$MAC_DIR"
cp distribution/macos/install.command distribution/macos/launcher.sh distribution/macos/README.txt "$MAC_DIR/"
mkdir -p "$MAC_DIR/assets"
cp distribution/assets/AppIcon.icns "$MAC_DIR/assets/AppIcon.icns"
chmod +x "$MAC_DIR/install.command" "$MAC_DIR/launcher.sh"
(cd "$OUT/stage/macos" && zip -qr "$OUT/artifacts/Braintrust-local-service-macos-$VERSION.zip" "Braintrust-local-service-macos-$VERSION")
bash distribution/macos/build-dmg.sh "$MAC_DIR" "$OUT/artifacts/Braintrust-$VERSION.dmg" "$VERSION"

echo "==> 3/5 组装 Windows 发行包（install.bat + launcher.ps1 + 图标）"
WIN_DIR="$OUT/stage/windows/Braintrust-local-service-windows-$VERSION"
unzip -q "$RAW/Braintrust-local-service-windows-$VERSION.zip" -d "$WIN_DIR"
cp distribution/windows/install.bat distribution/windows/install.ps1 distribution/windows/launcher.ps1 distribution/windows/README.txt "$WIN_DIR/"
mkdir -p "$WIN_DIR/assets"
cp distribution/assets/AppIcon.ico "$WIN_DIR/assets/AppIcon.ico"
(cd "$OUT/stage/windows" && zip -qr "$OUT/artifacts/Braintrust-local-service-windows-$VERSION.zip" "Braintrust-local-service-windows-$VERSION")

echo "==> 4/5 生成 SHA256SUMS（标准格式）"
(cd "$OUT/artifacts" && shasum -a 256 *.zip *.dmg > SHA256SUMS)

MAC_SHA="$(awk '$2 ~ /\.dmg$/ {print $1}' "$OUT/artifacts/SHA256SUMS")"
WIN_SHA="$(awk '$2 ~ /windows/ {print $1}' "$OUT/artifacts/SHA256SUMS")"
PREFIX="https://github.com/$REPO/releases/download/v$VERSION"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> 5/5 生成更新索引"
python3 - "$OUT/artifacts/local-service-update.json" "$VERSION" "$PUBLISHED_AT" "$PREFIX" "$MAC_SHA" "$WIN_SHA" <<'PY'
import json, sys
path, version, published_at, prefix, mac_sha, win_sha = sys.argv[1:]
manifest = {
    "version": version,
    "publishedAt": published_at,
    "notes": f"智囊本地服务工作台 v{version}",
    "artifacts": {
        "darwin-universal": {"url": f"{prefix}/Braintrust-{version}.dmg", "sha256": mac_sha},
        "win32-x64": {"url": f"{prefix}/Braintrust-local-service-windows-{version}.zip", "sha256": win_sha},
    },
}
open(path, "w", encoding="utf-8").write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY

cat > "$OUT/artifacts/RELEASE_NOTES.md" <<NOTES
# 智囊 · 本地工作台 v$VERSION

这是本地服务工作台的安装包。安装后桌面/开始菜单会出现「智囊」图标，双击即可使用；不需要浏览器扩展，也不需要 Apple 公证或 Windows 代码签名证书。

- macOS（推荐）：打开 `Braintrust-$VERSION.dmg`，把「智囊」拖到 Applications；首次打开如遇 Gatekeeper，右键 → 打开。
- macOS（备用）：解压 zip 后双击 `install.command`。
- Windows：解压后双击 \`install.bat\`；如遇 SmartScreen，更多信息 → 仍要运行。
- 安装包内置 Node 22 运行时；浏览器使用系统 Microsoft Edge / Google Chrome / Chromium。
- 登录态与本地数据保存在用户目录，不上传到我们的服务器。
- 更新索引：https://braintrust.chat/updates/local-service-update.json

SHA256 见同目录 \`SHA256SUMS\`。
NOTES

echo ""
echo "✅ 发布产物：$OUT/artifacts"
ls -lh "$OUT/artifacts"
echo ""
echo "下一步："
echo "  1. 审阅 DMG/zip 与 RELEASE_NOTES.md"
echo "  2. 创建 Draft Release 并上传 $OUT/artifacts/*"
echo "  3. 把 local-service-update.json 部署到 https://braintrust.chat/updates/local-service-update.json"
