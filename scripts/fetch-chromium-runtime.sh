#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-build/local-service/runtime}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/braintrust-chromium.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 --max-time 30 https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json -o "$WORK/versions.json"

python3 - "$WORK/versions.json" > "$WORK/entries" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))['channels']['Stable']['downloads']['chrome']
wanted = {'win64': 'chromium-win64', 'mac-arm64': 'chromium-mac-arm64', 'mac-x64': 'chromium-mac-x64'}
for item in data:
    if item['platform'] in wanted:
        print(wanted[item['platform']] + '\t' + item['url'])
PY
mkdir -p "$DEST"
while IFS="	" read -r target url; do
  archive="$WORK/$target.zip"
  curl -fsSL --retry 3 --max-time 600 "$url" -o "$archive"
  digest=$(shasum -a 256 "$archive" | awk '{print $1}')
  unzip -q "$archive" -d "$DEST"
  printf '%s %s %s\n' "$target" "$digest" "$url"
done < "$WORK/entries" > "$DEST/chromium-runtime-sums.txt"
echo "✅ Chromium for Testing 已下载并校验到 $DEST"
