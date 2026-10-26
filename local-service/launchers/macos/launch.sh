#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
DATA_DIR="${BRAINTRUST_DATA_DIR:-$HOME/Library/Application Support/Braintrust/data}"
APP_DATA="$(dirname -- "$DATA_DIR")"
RUNTIME_ROOT="$APP_DATA/runtime"
mkdir -p "$RUNTIME_ROOT"
if [ "$(uname -m)" = "arm64" ]; then
  NODE_DEFAULT="$ROOT/runtime/node-macos-arm64/bin/node"
  NODE_ARCH="arm64"
  NODE_SHA="c9e1dbc748b33ed2d14f42445191ecaf14c56259c7a9a26d0042c49ec2b66428"
  CHROME_ARCH="mac-arm64"
  CHROME_SHA="ad7f2b49a4dc679af286b1b1b386670d93ca7868079f69012d21ba0ac8293df3"
else
  NODE_DEFAULT="$ROOT/runtime/node-macos-x64/bin/node"
  NODE_ARCH="x64"
  NODE_SHA="efcc2b0db6f94bf53eddb038fe2b370277a042bd29e4f19b8f8e23598795b819"
  CHROME_ARCH="mac-x64"
  CHROME_SHA="5a38b8e3d621514fff0775dcae678a152ce378890188c88eef79fc97aa59fccd"
fi
NODE_BIN="${BRAINTRUST_NODE:-$NODE_DEFAULT}"
if [ ! -x "$NODE_BIN" ]; then NODE_BIN="$(command -v node || true)"; fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  NODE_VERSION="22.23.4"
  NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
  NODE_ARCHIVE_PATH="$RUNTIME_ROOT/$NODE_ARCHIVE"
  if [ ! -f "$NODE_ARCHIVE_PATH" ]; then curl -fsSL --retry 3 --max-time 180 "https://nodejs.org/dist/v${NODE_VERSION}/$NODE_ARCHIVE" -o "$NODE_ARCHIVE_PATH"; fi
  if [ "$(shasum -a 256 "$NODE_ARCHIVE_PATH" | awk '{print $1}')" != "$NODE_SHA" ]; then echo "Node 运行时校验失败" >&2; exit 1; fi
  NODE_DIR="$RUNTIME_ROOT/node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
  if [ ! -x "$NODE_DIR/bin/node" ]; then tar -xzf "$NODE_ARCHIVE_PATH" -C "$RUNTIME_ROOT"; fi
  NODE_BIN="$NODE_DIR/bin/node"
fi
if [ ! -x "$NODE_BIN" ]; then echo "无法准备 Node 运行时，请检查网络或设置 BRAINTRUST_NODE。" >&2; exit 1; fi
if [ -z "${BRAINTRUST_BROWSER_PATH:-}" ]; then
  for candidate in "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then BRAINTRUST_BROWSER_PATH="$candidate"; export BRAINTRUST_BROWSER_PATH; break; fi
  done
fi
if [ -z "${BRAINTRUST_BROWSER_PATH:-}" ]; then
  CHROME_VERSION="156.0.8078.47"
  CHROME_ARCHIVE="chrome-${CHROME_ARCH}.zip"
  CHROME_ARCHIVE_PATH="$RUNTIME_ROOT/$CHROME_ARCHIVE"
  if [ ! -f "$CHROME_ARCHIVE_PATH" ]; then curl -fsSL --retry 3 --max-time 600 "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/${CHROME_ARCH}/${CHROME_ARCHIVE}" -o "$CHROME_ARCHIVE_PATH"; fi
  if [ "$(shasum -a 256 "$CHROME_ARCHIVE_PATH" | awk '{print $1}')" != "$CHROME_SHA" ]; then echo "Chromium 运行时校验失败" >&2; exit 1; fi
  CHROME_DIR="$RUNTIME_ROOT/chrome-${CHROME_ARCH}"
  if [ ! -x "$CHROME_DIR/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ]; then mkdir -p "$CHROME_DIR"; unzip -q "$CHROME_ARCHIVE_PATH" -d "$CHROME_DIR"; fi
  BRAINTRUST_BROWSER_PATH="$CHROME_DIR/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
  export BRAINTRUST_BROWSER_PATH
fi
mkdir -p "$DATA_DIR"
exec "$NODE_BIN" "$ROOT/server.mjs" --data-dir "$DATA_DIR" --port "${BRAINTRUST_PORT:-0}" "$@"
