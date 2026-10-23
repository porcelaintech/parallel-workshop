#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(node -p "require('./local-service/package.json').version")}"
OUT="${OUT:-build/local-service}"
rm -rf "$OUT"
mkdir -p "$OUT/stage/local-service/data/adapters"

cp -R local-service/config local-service/lib local-service/public local-service/launchers local-service/package.json local-service/server.mjs local-service/README.md "$OUT/stage/local-service/"
cp Sources/WorkbenchCore/Resources/adapters/*.json "$OUT/stage/local-service/data/adapters/"
cp Sources/WorkbenchCore/Resources/injection/*.js "$OUT/stage/local-service/data/"
chmod +x "$OUT/stage/local-service/launchers/macos/"*.sh
mkdir -p "$OUT/stage/local-service/runtime"

RUNTIME_CACHE="${BRAINTRUST_RUNTIME_CACHE:-build/local-service-runtime-cache}"
if [[ "${BRAINTRUST_FETCH_RUNTIME:-0}" == "1" ]]; then
  if [[ ! -d "$RUNTIME_CACHE/node-win-x64" ]]; then bash scripts/fetch-node-runtime.sh "$RUNTIME_CACHE"; fi
  cp -R "$RUNTIME_CACHE"/node-* "$OUT/stage/local-service/runtime/"
elif [[ -n "${BRAINTRUST_NODE_RUNTIME:-}" ]]; then
  mkdir -p "$OUT/stage/local-service/runtime"
  cp -R "$BRAINTRUST_NODE_RUNTIME" "$OUT/stage/local-service/runtime/"
fi
if [[ "${BRAINTRUST_FETCH_BROWSER:-0}" == "1" ]]; then
  if [[ ! -d "$RUNTIME_CACHE/chrome-win64" ]]; then bash scripts/fetch-chromium-runtime.sh "$RUNTIME_CACHE"; fi
  cp -R "$RUNTIME_CACHE"/chrome-* "$OUT/stage/local-service/runtime/"
  cp "$RUNTIME_CACHE/chromium-runtime-sums.txt" "$OUT/stage/local-service/runtime/"
fi

python3 - "$OUT/stage/local-service/config/default.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1:]
d = json.load(open(path))
d['version'] = version
with open(path, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

mkdir -p "$OUT/artifacts"
rm -rf "$OUT/stage-windows" "$OUT/stage-macos"
cp -R "$OUT/stage" "$OUT/stage-windows"
cp -R "$OUT/stage" "$OUT/stage-macos"
rm -rf "$OUT/stage-windows/local-service/runtime/node-macos-arm64" "$OUT/stage-windows/local-service/runtime/node-macos-x64"
rm -rf "$OUT/stage-macos/local-service/runtime/node-win-x64"
rm -rf "$OUT/stage-windows/local-service/runtime/chrome-mac-arm64" "$OUT/stage-windows/local-service/runtime/chrome-mac-x64"
rm -rf "$OUT/stage-macos/local-service/runtime/chrome-win64"
(cd "$OUT/stage-windows" && zip -qr "../artifacts/Braintrust-local-service-windows-$VERSION.zip" local-service)
(cd "$OUT/stage-macos" && zip -qr "../artifacts/Braintrust-local-service-macos-$VERSION.zip" local-service)

for artifact in "$OUT/artifacts"/*.zip; do
  sha256=$(shasum -a 256 "$artifact" | awk '{print $1}')
  size=$(wc -c < "$artifact" | tr -d ' ')
  name=$(basename "$artifact")
  printf '%s %s %s\n' "$name" "$size" "$sha256"
done > "$OUT/artifacts/SHA256SUMS"
if [[ "${BRAINTRUST_FETCH_RUNTIME:-0}" != "1" && "${BRAINTRUST_FETCH_BROWSER:-0}" != "1" ]]; then
  while read -r name size sha; do
    if (( size > 52428800 )); then echo "❌ 轻量包超过 50MB：$name ($size bytes)" >&2; exit 1; fi
  done < "$OUT/artifacts/SHA256SUMS"
fi
cat > "$OUT/artifacts/local-service-update.json.example" <<EOF
{
  "version": "$VERSION",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "notes": "本地服务构建产物",
  "artifacts": {
    "win32-x64": {"url": "https://github.com/porcelaintech/parallel-workshop/releases/latest/download/Braintrust-local-service-windows-$VERSION.zip", "sha256": "REPLACE_WITH_WINDOWS_SHA256"},
    "darwin-universal": {"url": "https://github.com/porcelaintech/parallel-workshop/releases/latest/download/Braintrust-local-service-macos-$VERSION.zip", "sha256": "REPLACE_WITH_MACOS_SHA256"}
  }
}
EOF
WIN_SHA=$(awk '$1 ~ /windows/ {print $3}' "$OUT/artifacts/SHA256SUMS")
MAC_SHA=$(awk '$1 ~ /macos/ {print $3}' "$OUT/artifacts/SHA256SUMS")
cat > "$OUT/artifacts/local-service-update.json" <<EOF
{
  "version": "$VERSION",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "notes": "本地服务构建产物",
  "artifacts": {
    "win32-x64": {"url": "https://github.com/porcelaintech/parallel-workshop/releases/latest/download/Braintrust-local-service-windows-$VERSION.zip", "sha256": "$WIN_SHA"},
    "darwin-universal": {"url": "https://github.com/porcelaintech/parallel-workshop/releases/latest/download/Braintrust-local-service-macos-$VERSION.zip", "sha256": "$MAC_SHA"}
  }
}
EOF
echo "✅ 本地服务包已生成：$OUT/artifacts"
