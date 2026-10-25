#!/bin/bash
# 智囊.app 的启动器：确保本地服务在跑，然后把工作台窗口带到前台。
# 由 install.command 复制到 智囊.app/Contents/MacOS/BraintrustLauncher。
set -uo pipefail

APP_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$APP_ROOT/Contents/Resources/config.sh"
if [ -f "$CONFIG" ]; then . "$CONFIG"; fi

INSTALL_ROOT="${INSTALL_ROOT:-$HOME/Library/Application Support/Braintrust/service}"
DATA_DIR="${DATA_DIR:-$HOME/Library/Application Support/Braintrust/data}"
SERVICE_JSON="$DATA_DIR/service.json"
LOG_DIR="$HOME/Library/Logs/Braintrust"
LOG="$LOG_DIR/service.log"
mkdir -p "$LOG_DIR" "$DATA_DIR"

show_error() {
  /usr/bin/osascript -e 'on run argv' -e 'display dialog (item 1 of argv) buttons {"好"} default button 1 with icon caution' -e 'end run' "$1" >/dev/null 2>&1 || true
}

read_json() {
  /usr/bin/plutil -extract "$1" raw -o - "$SERVICE_JSON" 2>/dev/null || true
}

http_code() {
  /usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-1}" "$1" 2>/dev/null || true
}

[ -f "$INSTALL_ROOT/server.mjs" ] || { show_error "智囊程序文件缺失：$INSTALL_ROOT。请重新运行安装器。"; exit 1; }

NODE=""
for candidate in \
  "$INSTALL_ROOT/runtime/node-macos-arm64/bin/node" \
  "$INSTALL_ROOT/runtime/node-macos-x64/bin/node"; do
  if [ -x "$candidate" ]; then NODE="$candidate"; break; fi
done
if [ -z "$NODE" ]; then NODE="$(command -v node 2>/dev/null || true)"; fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  show_error "没有找到 Node 运行时。请重新安装智囊，或安装 Node.js 22+ 后重试。"
  exit 1
fi

BROWSER=""
if [ -n "${BRAINTRUST_BROWSER_PATH:-}" ] && [ -x "$BRAINTRUST_BROWSER_PATH" ]; then
  BROWSER="$BRAINTRUST_BROWSER_PATH"
else
  for candidate in \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then BROWSER="$candidate"; break; fi
  done
fi
if [ -z "$BROWSER" ]; then
  show_error "没有找到 Microsoft Edge、Google Chrome 或 Chromium。请先安装其中一个浏览器，再打开智囊。"
  exit 1
fi
export BRAINTRUST_BROWSER_PATH="$BROWSER"

# 1) 已有服务：直接让它把工作台窗口带到前台。
if [ -f "$SERVICE_JSON" ]; then
  PORT="$(read_json port)"
  TOKEN="$(read_json token)"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && [ -n "$TOKEN" ]; then
    CODE="$(http_code "http://127.0.0.1:$PORT/api/health")"
    if [ "$CODE" = "200" ] || [ "$CODE" = "401" ]; then
      RESULT="$(/usr/bin/curl -sS --max-time 45 -X POST \
        -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
        -d '{}' "http://127.0.0.1:$PORT/api/browser/open" 2>/dev/null || true)"
      if printf '%s' "$RESULT" | /usr/bin/grep -q '"ok":true'; then exit 0; fi
      show_error "智囊服务在运行，但无法把窗口带到前台。请查看日志：$LOG"
      exit 1
    fi
  fi
fi

# 2) 没有服务：选一个空闲本地端口，启动服务，再打开工作台。
PORT="${BRAINTRUST_PORT:-47821}"
for p in 47821 47822 47823 47824 47825 47826 47827 47828 47829 47830; do
  if ! /usr/sbin/lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then PORT="$p"; break; fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动智囊服务 port=$PORT" >> "$LOG"
/usr/bin/nohup "$NODE" "$INSTALL_ROOT/server.mjs" --data-dir "$DATA_DIR" --no-browser --port "$PORT" >> "$LOG" 2>&1 &
SERVER_PID=$!

CODE=""
for _ in $(seq 1 100); do
  if [ -f "$SERVICE_JSON" ]; then
    P="$(read_json port)"
    T="$(read_json token)"
    if [[ "$P" =~ ^[0-9]+$ ]] && [ -n "$T" ]; then
      CODE="$(http_code "http://127.0.0.1:$P/api/health")"
      if [ "$CODE" = "200" ] || [ "$CODE" = "401" ]; then PORT="$P"; TOKEN="$T"; break; fi
    fi
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
  sleep 0.2
done

if [ -z "${TOKEN:-}" ] || [ -z "${CODE:-}" ]; then
  show_error "智囊服务没有启动成功。请查看日志：$LOG"
  exit 1
fi

RESULT="$(/usr/bin/curl -sS --max-time 45 -X POST \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{}' "http://127.0.0.1:$PORT/api/browser/open" 2>/dev/null || true)"
if printf '%s' "$RESULT" | /usr/bin/grep -q '"ok":true'; then
  exit 0
fi

show_error "服务已启动，但工作台窗口没有打开。请查看日志：$LOG"
exit 1
