#!/bin/bash
# 从构建 stage 生成单文件 Windows 安装程序（NSIS，无需代码签名）。
# 用法：build-installer.sh <stage-dir> <output.exe> [version]
set -euo pipefail

STAGE="${1:?usage: build-installer.sh <stage-dir> <output.exe> [version]}"
OUT="${2:?usage: build-installer.sh <stage-dir> <output.exe> [version]}"
VERSION="${3:-0.6.0}"
if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.[1-9][0-9]*(\.[A-Z]+)?)?$ ]]; then
  VERSION_PARTS=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
else
  echo "invalid version: $VERSION (expected X.Y.Z or X.Y.Z-rc.N[.A])" >&2
  exit 1
fi
for part in "${VERSION_PARTS[@]}"; do
  if [ "${#part}" -gt 5 ] || [ "$((10#$part))" -gt 65535 ]; then
    echo "version component exceeds Windows metadata limit: $part" >&2
    exit 1
  fi
done
NUMERIC_VERSION="$((10#${VERSION_PARTS[0]})).$((10#${VERSION_PARTS[1]})).$((10#${VERSION_PARTS[2]})).0"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/distribution/windows"
BUILD="$ROOT/build/local-service-installer/windows"
PAYLOAD="$STAGE/local-service"

[ -d "$PAYLOAD" ] || { echo "missing payload: $PAYLOAD" >&2; exit 1; }
[ -f "$PAYLOAD/server.mjs" ] || { echo "missing server.mjs" >&2; exit 1; }
[ -f "$STAGE/assets/AppIcon.ico" ] || { echo "missing AppIcon.ico" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$BUILD/payload/assets" "$BUILD/assets" "$BUILD/payload/service"
cp -R "$PAYLOAD/." "$BUILD/payload/service/"
cp "$STAGE/launcher.ps1" "$BUILD/payload/launcher.ps1"
cp "$DIST/launcher.vbs" "$BUILD/payload/launcher.vbs"
cp "$DIST/stop.ps1" "$BUILD/payload/stop.ps1"
cp "$STAGE/assets/AppIcon.ico" "$BUILD/payload/assets/AppIcon.ico"
cp "$STAGE/assets/AppIcon.ico" "$BUILD/assets/AppIcon.ico"
cp "$DIST/installer.nsi" "$BUILD/installer.nsi"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

if command -v makensis >/dev/null 2>&1; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Preserve NSIS's Windows /D switches when invoked from Git Bash.
      (cd "$BUILD" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$VERSION" "/DNUMERIC_VERSION=$NUMERIC_VERSION" installer.nsi)
      ;;
    *)
      (cd "$BUILD" && makensis -V2 -INPUTCHARSET UTF8 "-DVERSION=$VERSION" "-DNUMERIC_VERSION=$NUMERIC_VERSION" installer.nsi)
      ;;
  esac
else
  docker run --rm -e NSIS_VERSION="$VERSION" -e NSIS_NUMERIC_VERSION="$NUMERIC_VERSION" \
    -v "$ROOT:/work" -w "/work/build/local-service-installer/windows" debian:bookworm-slim \
    bash -c 'apt-get update -qq && apt-get install -y -qq nsis >/dev/null 2>&1 && makensis -V2 -INPUTCHARSET UTF8 "-DVERSION=$NSIS_VERSION" "-DNUMERIC_VERSION=$NSIS_NUMERIC_VERSION" installer.nsi'
fi

cp "$BUILD/Braintrust-Setup-$VERSION.exe" "$OUT"
echo "created $OUT"
echo "size: $(wc -c < "$OUT" | tr -d '[:space:]') bytes"
if command -v sha256sum >/dev/null 2>&1; then
  echo "sha256: $(sha256sum "$OUT" | awk '{print $1}')"
else
  echo "sha256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
fi
