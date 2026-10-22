#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
DATA_DIR="${BRAINTRUST_DATA_DIR:-$HOME/Library/Application Support/Braintrust/data}"
if [ "$(uname -m)" = "arm64" ]; then NODE_DEFAULT="$ROOT/runtime/node-macos-arm64/bin/node"; else NODE_DEFAULT="$ROOT/runtime/node-macos-x64/bin/node"; fi
NODE_BIN="${BRAINTRUST_NODE:-$NODE_DEFAULT}"
if [ ! -x "$NODE_BIN" ]; then NODE_BIN="$(command -v node || true)"; fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "未找到随包 Node 运行时。请重新安装智囊服务包，或设置 BRAINTRUST_NODE。" >&2
  exit 1
fi
mkdir -p "$DATA_DIR"
exec "$NODE_BIN" "$ROOT/server.mjs" --data-dir "$DATA_DIR" --port "${BRAINTRUST_PORT:-0}" "$@"
