#!/bin/bash
# 统一版本号：Edge manifest / npm-launcher / Homebrew cask；macOS Info.plist 构建时读取 manifest 版本
# 用法：bash scripts/bump-version.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?用法: bash scripts/bump-version.sh X.Y.Z}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $V"; exit 1; }

python3 - "$V" <<'EOF'
import json, sys, re
v = sys.argv[1]

p = "Windows/edge-extension/manifest.json"
d = json.load(open(p)); d["version"] = v
with open(p, "w") as fp:
    json.dump(d, fp, ensure_ascii=False, indent=2)
    fp.write("\n")

p = "npm-launcher/package.json"
d = json.load(open(p)); d["version"] = v
with open(p, "w") as fp:
    json.dump(d, fp, ensure_ascii=False, indent=2)
    fp.write("\n")

p = "homebrew/Casks/parallel-workbench.rb"
s = open(p).read()
s = re.sub(r'version "\d+\.\d+\.\d+"', f'version "{v}"', s, count=1)
open(p, "w").write(s)

# Windows 原生 MSIX：x.y.z → x.y.z.0（Store 版本号必须是四段）
p = "Windows/native/ParallelWorkbench/Package.appxmanifest"
s = open(p).read()
s = re.sub(r'(Version=")\d+\.\d+\.\d+(?:\.\d+)?(")', rf'\g<1>{v}.0\g<2>', s, count=1)
open(p, "w").write(s)

print(f"✅ 版本统一为 {v}")
EOF
