#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${NODE_RUNTIME_VERSION:-22.23.4}"
DEST="${1:-build/local-service/runtime}"
BASE="https://nodejs.org/dist/v${VERSION}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/braintrust-node.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 --max-time 120 "$BASE/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"

fetch_archive() {
  local archive="$1"; local target="$2"; local file="$WORK/$archive"
  curl -fsSL --retry 3 --max-time 300 "$BASE/$archive" -o "$file"
  local expected; expected=$(awk -v name="$archive" '$2 == name {print $1}' "$WORK/SHASUMS256.txt")
  test -n "$expected"
  local actual; actual=$(shasum -a 256 "$file" | awk '{print $1}')
  test "$expected" = "$actual"
  mkdir -p "$DEST"
  case "$archive" in
    *.zip) unzip -q "$file" -d "$WORK"; rm -rf "$DEST/$target"; mv "$WORK"/node-v${VERSION}-win-x64 "$DEST/$target";;
    *darwin-arm64.tar.gz) tar -xzf "$file" -C "$WORK"; rm -rf "$DEST/$target"; mv "$WORK"/node-v${VERSION}-darwin-arm64 "$DEST/$target";;
    *darwin-x64.tar.gz) tar -xzf "$file" -C "$WORK"; rm -rf "$DEST/$target"; mv "$WORK"/node-v${VERSION}-darwin-x64 "$DEST/$target";;
    *) echo "不支持的 Node 运行时包：$archive" >&2; exit 1;;
  esac
}

fetch_archive "node-v${VERSION}-win-x64.zip" node-win-x64
fetch_archive "node-v${VERSION}-darwin-arm64.tar.gz" node-macos-arm64
fetch_archive "node-v${VERSION}-darwin-x64.tar.gz" node-macos-x64
echo "✅ Node $VERSION 运行时已下载并校验到 $DEST"
