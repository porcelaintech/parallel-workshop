import { readFileSync } from 'node:fs';

const base = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const read = (path) => readFileSync(base + '/' + path, 'utf8');
const fail = [];
const requireText = (condition, message) => { if (!condition) fail.push(message); };

const workbench = read('Windows/edge-extension/workbench.js');
const content = read('Windows/edge-extension/content-template.js');
const background = read('Windows/edge-extension/background.js');
const launcher = read('Windows/edge-extension/launch.bat');
const intercept = read('Windows/edge-extension/intercept.js');
const manifest = JSON.parse(read('Windows/edge-extension/manifest.json'));
const qa = read('scripts/qa.sh');
const delivery = read('scripts/package-delivery.sh');
const release = read('scripts/make-release.sh');
const updaterCaller = read('Sources/WorkbenchCore/UpdateCoordinator.swift');
const updater = read('Sources/WorkbenchCore/Updater.swift');
const installer = read('install.sh');
const workbenchHTML = read('Windows/edge-extension/workbench.html');
const edgeE2E = read('scripts/edge-e2e.mjs');
const edgeAttachMatrix = read('scripts/edge-attach-matrix.mjs');
const edgeTargetHelper = read('scripts/edge-workbench-target.mjs');
const windowsBootstrap = read('install-windows.ps1');
const windowsInstallBat = read('Windows/edge-extension/install.bat');
const windowsInstallPS = read('Windows/edge-extension/install.ps1');
const windowsLaunchPS = read('Windows/edge-extension/launch.ps1');
const distribution = JSON.parse(read('Windows/edge-extension/distribution.json'));

const layoutBody = workbench.match(/function layoutPanes\(\)[\s\S]*?\n  }\n\n  function renderPanes/)?.[0] || '';
const updateAssetSelectorBody = workbench.match(/function selectEdgeUpdateAsset\(assets\) \{\n([\s\S]*?)\n  }/)?.[1] || '';
requireText(layoutBody && !layoutBody.includes('appendChild'), 'layoutPanes 仍会重挂 iframe DOM');
requireText(workbench.includes('allow-storage-access-by-user-activation'),
  'Edge iframe sandbox 未允许用户手势触发 Storage Access API');
requireText(workbench.includes('chrome.tabs.sendMessage'), '工作台未迁移到 chrome.tabs.sendMessage');
requireText(!workbench.includes('paneTokens'), '仍保留页面可见 pane token');
requireText(!content.includes("window.addEventListener('message'"), '问答 content script 仍接收 window.postMessage');
requireText(content.includes('chrome.runtime.onMessage.addListener'), 'content script 未注册 runtime 通道');
requireText(background.includes('WB_AUTH_CALLBACK_CANDIDATE'), '后台缺少认证 callback 校验');
requireText(!background.includes("url: 'about:blank'") && background.includes('isReusableEmptyTab') &&
  background.includes('chrome.tabs.update(tab.id, { url: LAUNCH_URL'),
  '工具栏启动未把已有空白/新标签页原地替换为工作台');
requireText(!manifest.permissions?.includes('debugger') && !manifest.permissions?.includes('activeTab') &&
  manifest.permissions?.includes('declarativeNetRequest') && manifest.permissions?.includes('storage'),
  '扩展必须最小化权限：去掉 debugger/activeTab，保留 DNR 与 storage');
requireText(!launcher.includes('--no-startup-window') && !windowsLaunchPS.includes('--no-startup-window') &&
  !/timeout\s+\/t/i.test(launcher) && windowsLaunchPS.includes('--load-extension') &&
  windowsLaunchPS.includes('--no-first-run'),
  'Windows 启动器仍包含 blank 预热、固定延迟，或未用命令行加载扩展');
requireText(!edgeE2E.includes('about:blank') && edgeE2E.includes('ensureSingleWorkbenchPage') &&
  !edgeE2E.includes('/json/new?'), 'Edge E2E 仍会从 about:blank 或直接反复新建工作台标签');
requireText(edgeAttachMatrix.includes('ensureSingleWorkbenchPage') && !edgeAttachMatrix.includes('/json/new?'),
  '附件矩阵仍会绕过单 target 启动策略');
requireText((edgeTargetHelper.match(/\/json\/new\?/g) || []).length === 1 &&
  edgeTargetHelper.includes("'Page.navigate'") && edgeTargetHelper.includes('assertCleanWorkbenchTargets'),
  'Edge target helper 未保证只创建一次、原 target 重试和最终零 blank 审计');
requireText(workbenchHTML.includes('startup-overlay') && workbench.includes("startupOverlay?.classList.add('done')"),
  '工作台缺少可见加载状态或初始化完成收口');
requireText(intercept.includes('DEEPSEEK_WECHAT_CALLBACK'), '微信 MAIN world 缺少 callback 捕获');

const authBridge = manifest.content_scripts?.find(item => item.js?.includes('auth-bridge.js'));
requireText(!!authBridge && authBridge.world === 'ISOLATED', 'auth-bridge.js 未以隔离世界注册');
requireText(!manifest.declarative_net_request, 'manifest 仍启用了依赖固定扩展 ID 的静态 DNR');
requireText(background.includes('updateSessionRules') && background.includes('tabIds'),
  'DNR 未迁移到按工作台 tabId 限定的 session rule');

for (const [name, source] of [['qa.sh', qa], ['package-delivery.sh', delivery], ['make-release.sh', release]]) {
  requireText(!source.includes('build-Windows/edge-extension.sh'), `${name} 仍引用错误脚本路径`);
}
requireText(qa.includes('build-edge-extension.sh > /dev/null || FAIL=1'), 'QA 未记录扩展构建失败');
requireText(qa.includes('background-launch-test.mjs || FAIL=1'), 'QA 未执行工具栏空白页复用回归');
requireText(qa.includes('palette-regression-test.mjs || FAIL=1'), 'QA 未执行双端三色与 logo 回归');
requireText(!/\bpause\b/i.test(windowsInstallBat) && !/\bxcopy\b/i.test(windowsInstallBat) &&
  windowsInstallBat.includes('install.ps1'), 'Windows install.bat 仍会阻塞或使用脆弱复制流程');
requireText(windowsBootstrap.includes("name -eq 'edge-extension.zip'") &&
  windowsBootstrap.includes('Get-FileHash') && windowsBootstrap.includes('Invoke-WithRetry'),
  'Windows 固定入口缺少精确资产、SHA-256 或网络重试');
requireText(windowsInstallPS.includes('.edge-extension.new-') && windowsInstallPS.includes('.edge-extension.old-') &&
  windowsInstallPS.includes('NoLaunch') && windowsInstallPS.includes('NoShortcuts'),
  'Windows 本地安装器缺少原子替换或无人值守参数');
requireText(windowsLaunchPS.includes('--user-data-dir'), 'Windows 启动器必须使用独立 Edge 配置档（保证已运行 Edge 时命令行参数生效）');
requireText(updaterCaller.includes('expectedSHA256: rel.dmgSHA256'), 'macOS 更新调用未传递 SHA-256');
requireText(installer.includes('SHA-256 校验通过') && installer.includes('shasum -a 256'),
  'install.sh 未强制校验 SHA-256');
requireText(installer.includes('当前没有可安装的稳定 Release'), 'install.sh 缺少无稳定版本的明确错误提示');
requireText(workbench.includes("const UPDATE_REPO = 'porcelaintech/parallel-workshop'"),
  'Edge 更新通道未迁移到 porcelaintech/parallel-workshop');
requireText(updater.includes('"porcelaintech/parallel-workshop"'),
  'macOS 更新通道未迁移到 porcelaintech/parallel-workshop');
requireText(installer.includes('porcelaintech/parallel-workshop'),
  'macOS 安装脚本未迁移到 porcelaintech/parallel-workshop');
requireText(release.includes('REPO="porcelaintech/parallel-workshop"'),
  '发布脚本未迁移到 porcelaintech/parallel-workshop');

if (!updateAssetSelectorBody) {
  fail.push('Edge 更新器缺少可验证的精确资产选择器');
} else {
  try {
    const selectEdgeUpdateAsset = new Function('assets', updateAssetSelectorBody);
    const storeAsset = { name: 'edge-extension-store.zip', browser_download_url: 'store' };
    const userAsset = { name: 'edge-extension.zip', browser_download_url: 'user' };
    requireText(selectEdgeUpdateAsset([storeAsset, userAsset]) === userAsset,
      'Edge 更新器会在商店包排在前面时误选 edge-extension-store.zip');
    requireText(selectEdgeUpdateAsset([storeAsset]) === undefined,
      'Edge 更新器在缺少 edge-extension.zip 时未失败关闭');
  } catch (error) {
    fail.push(`Edge 更新资产选择器无法执行：${error}`);
  }
}
requireText(!workbench.includes("endsWith('.zip')"), 'Edge 更新器仍按任意 .zip 后缀选择资产');
requireText(workbench.includes('chrome.runtime.requestUpdateCheck()') &&
  workbench.includes('chrome.runtime.onUpdateAvailable?.addListener') &&
  workbench.includes('chrome.runtime.reload()'),
  'Edge 商店版缺少原生检查、就绪事件或一键重载更新链路');
requireText(distribution.channel === 'sideload' &&
  workbench.includes("distributionChannel === 'edge-addons'") &&
  /["']install-windows\.ps1["']/.test(release),
  'Edge 分发渠道标记或与 Release 同步的 Windows 引导器缺失');
requireText(manifest.host_permissions?.includes('https://github.com/*') &&
  workbench.includes("crypto.subtle.digest('SHA-256'") &&
  workbench.includes('expectedEdgeAssetSHA256') && workbench.includes('new AbortController()') &&
  workbench.includes('timeoutMs: 60000') && workbench.includes("return await response.blob()"),
  'Edge 侧载更新缺少 GitHub 下载权限或 SHA-256 强校验');

if (fail.length) {
  console.error('❌ 安全回归失败：\n- ' + fail.join('\n- '));
  process.exit(1);
}
console.log('✅ 安全回归通过（认证桥/runtime 通道/DNR/iframe/更新器/流水线）');
