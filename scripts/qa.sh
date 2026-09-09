#!/bin/bash
# 一键质量门禁：构建 + 注入核心自检 + 扩展构建校验 + 胶水层冒烟测试
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
PWB_QA_ARCH="${PWB_QA_ARCH:-$(uname -m)}"
if [ "$PWB_QA_ARCH" = "x86_64" ]; then PWB_BUILD_TRIPLE="x86_64-apple-macosx"; else PWB_QA_ARCH="arm64"; PWB_BUILD_TRIPLE="arm64-apple-macosx"; fi

echo "==> 1/4 Swift 构建"
swift build --arch "$PWB_QA_ARCH" 2>&1 | tail -1 || { echo "❌ 构建失败"; exit 1; }
swift test --arch "$PWB_QA_ARCH" || { echo "❌ Swift 单元测试失败"; exit 1; }

# 刷新测试器副本（SelfTest 等 Swift 代码编译进二进制，必须同步；inject.js 运行时从资源加载。
# 注意目标可执行名是 WorkbenchTester；改名保持单实例守护的进程名约定）
mkdir -p .tester-bin
cp -f ".build/${PWB_BUILD_TRIPLE}/debug/WorkbenchTester" .tester-bin/ParallelWorkbench

echo "==> 2/4 注入核心自检（本地夹具，不触网）"
.tester-bin/ParallelWorkbench --selftest || FAIL=1

echo "==> 3/4 Edge 扩展构建与校验"
bash scripts/build-edge-extension.sh > /dev/null || FAIL=1
for f in Windows/edge-extension/*.js Windows/edge-extension/lib/*.js; do
  node --check "$f" || FAIL=1
done
for f in scripts/*.mjs; do
  node --input-type=module --check < "$f" || FAIL=1
done
for f in Windows/edge-extension/manifest.json Windows/edge-extension/lib/adapters/index.json; do
  python3 -m json.tool "$f" > /dev/null || FAIL=1
done
python3 - <<'PY' || FAIL=1
import json, zipfile

with zipfile.ZipFile('build/edge-extension.zip') as archive:
    names = archive.namelist()
    assert names and all(name == 'edge-extension/' or name.startswith('edge-extension/') for name in names)
    assert 'edge-extension/manifest.json' in names
    assert 'edge-extension/install.bat' in names
    assert 'edge-extension/launch.bat' in names
    assert 'edge-extension/distribution.json' in names
    assert 'edge-extension/lib/model-preference.js' in names

with zipfile.ZipFile('build/edge-extension-store.zip') as archive:
    names = archive.namelist()
    assert 'manifest.json' in names
    assert not any(name.startswith('edge-extension/') for name in names)
    store_manifest = json.loads(archive.read('manifest.json'))
    assert 'key' not in store_manifest
    assert not any('github.com' in item or 'githubusercontent.com' in item
                   for item in store_manifest.get('host_permissions', []))
    files = {name for name in names if not name.endswith('/')}
    expected = {
        'manifest.json', 'distribution.json', 'background.js', 'auth-bridge.js', 'intercept.js', 'content.js',
        'workbench.html', 'workbench.js', 'workbench.css', 'lib/model-preference.js',
        'launch.html', 'launch.js', 'launch.css',
        'lib/adapters/index.json',
        'icons/16.png', 'icons/32.png', 'icons/48.png', 'icons/128.png'
    }
    assert files == expected, (files - expected, expected - files)
    assert json.loads(archive.read('distribution.json')) == {'channel': 'edge-addons'}
PY
node scripts/security-regression-test.mjs || FAIL=1
node scripts/background-launch-test.mjs || FAIL=1
node scripts/edge-launch-flow-test.mjs || FAIL=1
node scripts/palette-regression-test.mjs || FAIL=1
node scripts/edge-preferences-test.mjs || FAIL=1
node scripts/edge-update-test.mjs || FAIL=1
node scripts/doubao-adapter-test.mjs || FAIL=1
node scripts/deepseek-model-preference-test.mjs || FAIL=1
node scripts/windows-installer-contract-test.mjs || FAIL=1
node scripts/windows-device-harness-contract-test.mjs || FAIL=1
node scripts/release-pipeline-contract-test.mjs || FAIL=1
node scripts/update-manifest-test.mjs || FAIL=1
echo "    语法与 JSON 校验通过"

echo "==> 4/4 扩展胶水层 jsdom 冒烟测试"
if (cd scripts && node -e "require.resolve('jsdom')" > /dev/null 2>&1); then
  node scripts/ext-glue-test.mjs || FAIL=1
else
  echo "❌ jsdom 未安装（cd scripts && npm i jsdom）——胶水层验证为必测项"
  FAIL=1
fi

echo "==> 5/5 Windows 原生资源同步校验（唯一事实源：Sources/WorkbenchCore/Resources）"
bash scripts/sync-windows-native.sh > /dev/null
if git diff --quiet -- Windows/native/ParallelWorkbench/Resources; then
  echo "    已同步，无差异"
else
  echo "❌ Windows/native/ParallelWorkbench/Resources 与共享核心不同步，请提交同步后的资源"
  FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✅ QA 门禁全部通过"
else
  echo "❌ QA 门禁存在失败项"
fi
exit $FAIL
