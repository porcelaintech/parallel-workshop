#!/bin/bash
# 生成 Windows 原生应用的 MSIX/商店图标资产（从 build/AppIcon.icns 出发）
# 依赖: python3 + Pillow（本机开发机）；CI 上产物已提交，无需再生成
# 用法: bash scripts/win-logos.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/AppIcon.icns"
OUT="Windows/native/ParallelWorkbench/Assets"
[ -f "$SRC" ] || { echo "❌ 缺少 $SRC（先运行 bash scripts/package-app.sh 生成图标）"; exit 1; }

mkdir -p "$OUT"
python3 - "$SRC" "$OUT" <<'EOF'
import sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]

# ICNS 里取最大尺寸的表示
icon = Image.open(src)
icon.load()
largest = icon
if getattr(icon, "info", {}):
    for size in sorted(icon.info.get("sizes", []), reverse=True):
        icon.size = size
        largest = icon.copy()
        break

# 高质量 LANCZOS 缩放到 1024 基准
base = largest.convert("RGBA")
base = base.resize((1024, 1024), Image.LANCZOS)

def save_square(name, size):
    base.resize((size, size), Image.LANCZOS).save(f"{out}/{name}")

def save_wide(name, w, h, inner):
    # 宽磁贴：图标居中放在透明画布上
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    img = base.resize((inner, inner), Image.LANCZOS)
    canvas.paste(img, ((w - inner) // 2, (h - inner) // 2))
    canvas.save(f"{out}/{name}")

# MSIX 必需 + 推荐尺寸
save_square("StoreLogo.png", 50)
save_square("Square44x44Logo.png", 44)
save_square("Square44x44Logo.targetsize-24_altform-unplated.png", 24)
save_square("Square71x71Logo.png", 71)
save_square("Square150x150Logo.png", 150)
save_square("Square310x310Logo.png", 310)
save_wide("Wide310x150Logo.png", 310, 150, 150)

# 多尺寸 ICO（窗口/任务栏图标备用）
sizes = [16, 24, 32, 48, 64, 128, 256]
base.save(f"{out}/AppIcon.ico", sizes=[(s, s) for s in sizes])

print(f"✅ 已生成商店图标资产到 {out}")
EOF
ls -la "$OUT" | head -20
