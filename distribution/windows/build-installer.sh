#!/bin/bash
# 从构建 stage 生成单文件 Windows 安装程序（NSIS，无需代码签名）。
# 用法：build-installer.sh <stage-dir> <output.exe> [version]
set -euo pipefail

STAGE="${1:?usage: build-installer.sh <stage-dir> <output.exe> [version]}"
OUT="${2:?usage: build-installer.sh <stage-dir> <output.exe> [version]}"
VERSION="${3:-0.6.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/distribution/windows"
BUILD="$ROOT/build/local-service-installer/windows"
PAYLOAD="$STAGE/local-service"

[ -d "$PAYLOAD" ] || { echo "missing payload: $PAYLOAD" >&2; exit 1; }
[ -f "$PAYLOAD/server.mjs" ] || { echo "missing server.mjs" >&2; exit 1; }
[ -f "$STAGE/assets/AppIcon.ico" ] || { echo "missing AppIcon.ico" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$BUILD/payload/assets" "$BUILD/assets" "$BUILD/payload/service"
/usr/bin/ditto "$PAYLOAD" "$BUILD/payload/service"
cp "$STAGE/launcher.ps1" "$BUILD/payload/launcher.ps1"
cp "$DIST/launcher.vbs" "$BUILD/payload/launcher.vbs"
cp "$DIST/stop.ps1" "$BUILD/payload/stop.ps1"
cp "$STAGE/assets/AppIcon.ico" "$BUILD/payload/assets/AppIcon.ico"
cp "$STAGE/assets/AppIcon.ico" "$BUILD/assets/AppIcon.ico"
cp "$DIST/installer.nsi" "$BUILD/installer.nsi"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

if command -v makensis >/dev/null 2>&1; then
  (cd "$BUILD" && makensis -V2 -INPUTCHARSET UTF8 -DVERSION="$VERSION" installer.nsi)
else
  docker run --rm -v "$ROOT:/work" -w "/work/build/local-service-installer/windows" debian:bookworm-slim \
    bash -c "apt-get update -qq && apt-get install -y -qq nsis >/dev/null 2>&1 && makensis -V2 -INPUTCHARSET UTF8 -DVERSION='$VERSION' installer.nsi"
fi

cp "$BUILD/Braintrust-Setup-$VERSION.exe" "$OUT"
echo "created $OUT"
echo "size: $(/usr/bin/du -h "$OUT" | cut -f1)"
echo "sha256: $(/usr/bin/shasum -a 256 "$OUT" | awk '{print $1}')"
