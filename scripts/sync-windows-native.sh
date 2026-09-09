#!/bin/bash
# 同步共享注入核心 → Windows 原生应用（唯一事实源：Sources/WorkbenchCore/Resources）
# 用法: bash scripts/sync-windows-native.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/WorkbenchCore/Resources"
DST="Windows/native/ParallelWorkbench/Resources"

rm -rf "$DST/adapters" "$DST/injection"
mkdir -p "$DST"
cp -R "$SRC/adapters" "$DST/adapters"
cp -R "$SRC/injection" "$DST/injection"

echo "✅ 已同步 $SRC → $DST"
echo "   适配器: $(ls "$DST/adapters" | tr '\n' ' ')"
echo "   注入:   $(ls "$DST/injection" | tr '\n' ' ')"
