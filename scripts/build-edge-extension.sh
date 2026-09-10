#!/bin/bash
# 构建 Edge/Chrome 扩展：把共享核心（adapter JSON + inject.js/probe.js）复制进扩展目录
# 单一事实来源：Sources/WorkbenchCore/Resources/
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Windows/edge-extension/lib/adapters Windows/edge-extension/lib/injection
cp Sources/WorkbenchCore/Resources/adapters/*.json Windows/edge-extension/lib/adapters/
cp Sources/WorkbenchCore/Resources/injection/*.js Windows/edge-extension/lib/

# 生成商店图标（16/32/48/128 PNG，商店上架硬性要求）
if [ ! -f Windows/edge-extension/icons/128.png ]; then
  rm -rf /tmp/wb-iconset && swift scripts/icon.swift /tmp/wb-iconset > /dev/null
  mkdir -p Windows/edge-extension/icons
  cp /tmp/wb-iconset/icon_16x16.png        Windows/edge-extension/icons/16.png
  cp /tmp/wb-iconset/icon_32x32.png        Windows/edge-extension/icons/32.png
  cp /tmp/wb-iconset/icon_32x32@2x.png     Windows/edge-extension/icons/48.png
  cp /tmp/wb-iconset/icon_128x128.png      Windows/edge-extension/icons/128.png
  echo "已生成扩展图标 Windows/edge-extension/icons/"
fi

# 生成适配器清单（供扩展页面加载）；必须排除 index.json 自身，否则每次构建自我膨胀
python3 - <<'EOF'
import json, glob
adapters = []
for f in sorted(glob.glob("Windows/edge-extension/lib/adapters/*.json")):
    if f.endswith("index.json"):
        continue
    with open(f) as fp:
        adapters.append(json.load(fp))
with open("Windows/edge-extension/lib/adapters/index.json", "w") as fp:
    json.dump(adapters, fp, ensure_ascii=False, indent=2)
print(f"已生成 index.json（{len(adapters)} 个适配器）")
EOF

# 把共享核心转换为普通函数内嵌生成 content.js（无 eval，绕开宿主页面 CSP 的 unsafe-eval 限制）
python3 - <<'EOF'
import re
inject = open("Windows/edge-extension/lib/inject.js").read()
probe = open("Windows/edge-extension/lib/probe.js").read()

# inject.js：外层是 void(async()=>{ ... window.__wb_result = result; })(); 提取内层 async 函数体
# 内层结束标记用 window.__wb_result 赋值行（内层代码里含内联 IIFE，不能靠 "})();" 定位）
m_start = "const result = await (async () => {"
idx = inject.index(m_start) + len(m_start)
end = inject.index("\n  window.__wb_result = result;")
inner = inject[idx:end]
inner = inner.replace("const cfg = __CFG__;", "")
# 剥掉内层 IIFE 自带的结尾 "})();"：取最后一次出现的位置，
# 其后的代码（如 reqId 附加逻辑）保留在函数体内
pos = inner.rfind("})();")
if pos >= 0:
    inner = inner[:pos].rstrip() + inner[pos + len("})();"):]
inject_fn = "async function __wbInject(cfg) {\n" + inner + "\n}"

# probe.js：去掉注释头后形如 (() => { const cfg = __CFG__; ... })(); 转成同步函数
lines = probe.strip().splitlines()
while lines and lines[0].strip().startswith("//"):
    lines.pop(0)
body = "\n".join(lines).strip()
assert body.startswith("(() => {") and body.endswith("})();"), f"probe.js 结构不符: {body[:60]!r}"
inner2 = body[len("(() => {"):-len("})();")]
inner2 = inner2.replace("const cfg = __CFG__;", "")
probe_fn = "function __wbProbe(cfg) {\n" + inner2 + "\n}"

tpl = open("Windows/edge-extension/content-template.js").read()
out = tpl.replace("// __WB_FUNCTIONS__ 由构建脚本替换为 __wbInject/__wbProbe 两个函数定义",
                  inject_fn + "\n\n" + probe_fn)
open("Windows/edge-extension/content.js", "w").write(out)
print("已生成函数内嵌版 content.js（无 eval）")
EOF

echo "✅ Edge 扩展构建完成：Windows/edge-extension/"
echo "   安装：打开 edge://extensions（或 chrome://extensions）→ 开发者模式 → 加载已解压的扩展 → 选择 Windows/edge-extension/ 目录"

# 生成传输用 zip（拷到 Windows 机器解压后侧载）
mkdir -p build
rm -f build/edge-extension.zip
(cd Windows && zip -rq ../build/edge-extension.zip edge-extension \
  -x "edge-extension/.*" -x "edge-extension/_metadata/*" -x "edge-extension/**/*.DS_Store")
echo "✅ 传输包已生成：build/edge-extension.zip"

# 商店包只包含运行时文件，manifest 位于根目录且移除侧载固定 ID key。
STORE_STAGE="$(mktemp -d /tmp/pwb-edge-store.XXXXXX)"
STORE_ZIP="$(pwd)/build/edge-extension-store.zip"
trap 'rm -rf "$STORE_STAGE"' EXIT
cp Windows/edge-extension/{background.js,auth-bridge.js,intercept.js,content.js,workbench.html,workbench.js,workbench.css,launch.html,launch.js,launch.css} "$STORE_STAGE/"
printf '%s\n' '{"channel":"edge-addons"}' > "$STORE_STAGE/distribution.json"
mkdir -p "$STORE_STAGE/icons" "$STORE_STAGE/lib/adapters"
cp Windows/edge-extension/icons/{16.png,32.png,48.png,128.png} "$STORE_STAGE/icons/"
cp Windows/edge-extension/lib/adapters/index.json "$STORE_STAGE/lib/adapters/"
cp Windows/edge-extension/lib/model-preference.js "$STORE_STAGE/lib/"
python3 - "$STORE_STAGE/manifest.json" <<'PY'
import json, sys
source = json.load(open('Windows/edge-extension/manifest.json'))
source.pop('key', None)
source['host_permissions'] = [
    item for item in source.get('host_permissions', [])
    if 'github.com' not in item and 'githubusercontent.com' not in item
]
with open(sys.argv[1], 'w') as handle:
    json.dump(source, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY
rm -f build/edge-extension-store.zip
(cd "$STORE_STAGE" && zip -rq "$STORE_ZIP" .)
rm -rf "$STORE_STAGE"
trap - EXIT
echo "✅ Edge 商店包已生成：build/edge-extension-store.zip"

# 自托管 CRX（企业策略安装 + 自动更新用）：运行时文件 + sideload 渠道 + 无 manifest key（ID 来自签名）。
# 私钥在 keys/edge-extension.pem（gitignore，绝不入库）；CI 无密钥时跳过。
CRX_KEY="${PWB_CRX_KEY:-keys/edge-extension.pem}"
if [ -f "$CRX_KEY" ]; then
  VERSION="$(python3 -c 'import json; print(json.load(open("Windows/edge-extension/manifest.json"))["version"])')"
  CRX_STAGE="$(mktemp -d /tmp/pwb-edge-crx.XXXXXX)"
  trap 'rm -rf "$CRX_STAGE"' EXIT
  cp Windows/edge-extension/{background.js,auth-bridge.js,intercept.js,content.js,workbench.html,workbench.js,workbench.css,launch.html,launch.js,launch.css} "$CRX_STAGE/"
  printf '%s\n' '{"channel":"sideload"}' > "$CRX_STAGE/distribution.json"
  mkdir -p "$CRX_STAGE/icons" "$CRX_STAGE/lib/adapters"
  cp Windows/edge-extension/icons/{16.png,32.png,48.png,128.png} "$CRX_STAGE/icons/"
  cp Windows/edge-extension/lib/adapters/index.json "$CRX_STAGE/lib/adapters/"
  cp Windows/edge-extension/lib/model-preference.js "$CRX_STAGE/lib/"
  python3 - "$CRX_STAGE/manifest.json" <<'PY'
import json, sys
source = json.load(open('Windows/edge-extension/manifest.json'))
source.pop('key', None)
with open(sys.argv[1], 'w') as handle:
    json.dump(source, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY
  CRX_OUT="build/edge-extension-crx.crx"
  PACK_OUTPUT="$(node scripts/pack-crx.mjs "$CRX_STAGE" "$CRX_KEY" "$CRX_OUT")"
  echo "$PACK_OUTPUT"
  CRX_ID="$(echo "$PACK_OUTPUT" | awk '/extension id/{print $4}')"
  mv "$CRX_OUT" "build/edge-extension-${CRX_ID}.crx"
  node scripts/generate-updates-xml.mjs "$VERSION" "build/edge-extension-${CRX_ID}.crx" porcelaintech/parallel-workshop build/updates.xml
  rm -rf "$CRX_STAGE"
  trap - EXIT
  echo "✅ 自托管 CRX 与 updates.xml 已生成：build/edge-extension-${CRX_ID}.crx"
else
  echo "⚠️ 未找到扩展签名私钥（$CRX_KEY），跳过 CRX 打包（企业策略模式需要）"
fi
