import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const { JSDOM } = require(process.env.PWB_JSDOM_MODULE || 'jsdom');

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const html = readFileSync(base + 'Windows/edge-extension/workbench.html', 'utf8');
const workbenchSource = readFileSync(base + 'Windows/edge-extension/workbench.js', 'utf8');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const VALID_DIGEST = 'aa'.repeat(32);

async function waitFor(predicate, label, timeout = 1500) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate()) return;
    await delay(5);
  }
  throw new Error(`等待超时：${label}`);
}

function makeRelease(assets, version = '1.1.0') {
  return { tag_name: `v${version}`, assets };
}

async function boot({ storeBuild, release, requestUpdateCheck, assetFetchFailures = 0,
  assetBodyFailures = 0, releaseFetch, fallbackManifest, online = true, installedVersion = '1.0.0', initialDraft = '' }) {
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    url: 'chrome-extension://test/workbench.html'
  });
  const { window } = dom;
  window.document.getElementById('question').value = initialDraft;
  if (!window.crypto.randomUUID) {
    window.crypto.randomUUID = () => '00000000-0000-4000-8000-000000000000';
  }
  Object.defineProperty(window.crypto, 'subtle', {
    configurable: true,
    value: { digest: async () => new Uint8Array(32).fill(0xaa).buffer }
  });

  const timers = [];
  const intervals = [];
  const downloads = [];
  const fetchedURLs = [];
  let updateListener;
  let storageWrites = 0;
  let reloadReceipt;
  let updateChecks = 0;
  let reloads = 0;
  let objectURLs = 0;
  let releaseChecks = 0;
  let now = Date.now();
  window.Date.now = () => now;
  Object.defineProperty(window.navigator, 'onLine', { configurable: true, get: () => online });

  window.setTimeout = (fn, ms, ...args) => {
    const timer = { active: true, ms, run: () => fn(...args) };
    timers.push(timer);
    return timers.length;
  };
  window.clearTimeout = id => {
    if (timers[id - 1]) timers[id - 1].active = false;
  };
  window.setInterval = (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; };
  window.requestAnimationFrame = fn => { fn(0); return 1; };
  window.URL.createObjectURL = () => {
    objectURLs += 1;
    return `blob:edge-update-test-${objectURLs}`;
  };
  window.HTMLAnchorElement.prototype.click = function click() {
    downloads.push({ download: this.download, href: this.href });
  };

  window.fetch = async (input, options) => {
    const url = String(input);
    fetchedURLs.push(url);
    if (url === 'chrome-extension://test/lib/adapters/index.json') {
      return { ok: true, json: async () => [] };
    }
    if (url === 'chrome-extension://test/distribution.json') {
      return { ok: true, json: async () => ({ channel: storeBuild ? 'edge-addons' : 'sideload' }) };
    }
    if (url === 'chrome-extension://test/manifest.json') {
      assert.equal(options?.cache, 'no-store', '磁盘版本检查不能使用旧 HTTP 缓存');
      return { ok: true, json: async () => ({ version: installedVersion }) };
    }
    if (url === 'https://api.github.com/repos/porcelaintech/parallel-workshop/releases/latest') {
      releaseChecks += 1;
      if (releaseFetch) return releaseFetch(releaseChecks, options);
      return { ok: true, json: async () => structuredClone(release) };
    }
    if (url === 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/update.json') {
      return fallbackManifest
        ? { ok: true, json: async () => structuredClone(fallbackManifest) }
        : { ok: false, status: 404 };
    }
    const asset = release.assets.find(item => item.browser_download_url === url);
    if (asset) {
      if (assetFetchFailures > 0) {
        assetFetchFailures -= 1;
        throw new Error('simulated transient asset failure');
      }
      return {
        ok: true,
        blob: async () => {
          if (assetBodyFailures > 0) {
            assetBodyFailures -= 1;
            throw new Error('simulated half-open asset body failure');
          }
          return { arrayBuffer: async () => new TextEncoder().encode(asset.name).buffer };
        }
      };
    }
    throw new Error(`测试中出现未声明的网络请求：${url}`);
  };

  window.chrome = {
    runtime: {
      id: 'test',
      getURL: path => `chrome-extension://test/${path}`,
      getContexts: async () => [{ tabId: 7, frameId: 0, documentUrl: 'chrome-extension://test/workbench.html' }],
      getManifest: () => storeBuild
        ? { version: '1.0.0' }
        : { version: '1.0.0', key: 'fixed-side-load-id-key' },
      onMessage: { addListener() {} },
      onUpdateAvailable: { addListener(listener) { updateListener = listener; } },
      sendMessage: async message => message?.type === 'WB_REGISTER_WORKBENCH'
        ? { ok: true, tabId: 7 }
        : { ok: false },
      requestUpdateCheck: async () => {
        updateChecks += 1;
        if (!requestUpdateCheck) throw new Error('侧载版不应请求 Edge 商店更新');
        return requestUpdateCheck();
      },
      reload: () => { reloads += 1; }
    },
    storage: {
      local: {
        get: async () => ({}),
        set: async value => {
          storageWrites += 1;
          if (value['wb-pending-extension-reload']) reloadReceipt = value['wb-pending-extension-reload'];
        }
      }
    },
    tabs: {
      getCurrent: async () => ({ id: 7 }),
      sendMessage: async () => ({ result: null })
    },
    webNavigation: { getAllFrames: async () => [] },
    scripting: { executeScript(_options, callback) { callback?.([]); } }
  };

  window.eval(workbenchSource);
  await waitFor(
    () => storageWrites > 0 && timers.some(timer => timer.active && timer.ms === 5000),
    '工作台初始化并安排更新检查'
  );

  return {
    dom,
    window,
    downloads,
    fetchedURLs,
    fireUpdateAvailable(details) {
      if (!updateListener) throw new Error('未注册 onUpdateAvailable 监听器');
      updateListener(details);
    },
    get updateChecks() { return updateChecks; },
    get reloads() { return reloads; },
    get reloadReceipt() { return reloadReceipt; },
    get objectURLs() { return objectURLs; },
    get releaseChecks() { return releaseChecks; },
    get state() { return window.document.getElementById('update-banner').dataset.state; },
    get button() { return window.document.getElementById('update-btn'); },
    get status() { return window.document.getElementById('update-status').textContent; },
    setOnline(value) { online = value; },
    advanceTime(ms) { now += ms; },
    async runInterval(ms) {
      const interval = intervals.find(item => item.ms === ms);
      if (!interval) throw new Error(`未找到 ${ms}ms 周期检查`);
      await interval.fn();
      await delay(0);
    },
    async runTimer(ms) {
      const timer = timers.find(item => item.active && item.ms === ms);
      if (!timer) throw new Error(`未找到 ${ms}ms 定时器`);
      timer.active = false;
      await timer.run();
      await delay(0);
    },
    timerCount(ms) {
      return timers.filter(item => item.active && item.ms === ms).length;
    }
  };
}

async function exposeUpdateBanner(app) {
  await app.runTimer(5000);
  await waitFor(
    () => app.state === 'available' && app.button.textContent === 'Update · v1.1.0',
    '显示有新版的 Update 按钮'
  );
  return app.window.document.getElementById('update-btn');
}

// The entry exists before any request, and remains visible on a current version.
const current = await boot({ storeBuild: false, release: makeRelease([], '1.0.0') });
assert.equal(current.state, 'idle');
assert.equal(current.button.textContent, '检查更新 / Check updates');
assert.equal(current.window.document.getElementById('update-version').textContent, 'v1.0.0');
assert.notEqual(current.window.getComputedStyle(current.window.document.getElementById('update-banner')).display, 'none');
await current.runTimer(5000);
assert.equal(current.state, 'current');
assert.equal(current.status, '已是最新版');
assert.equal(current.fetchedURLs.some(url => url.endsWith('/update.json')), false, '无新版是正常成功，不应改走备用源');
assert.equal(current.button.disabled, false);
current.button.click();
await waitFor(() => current.releaseChecks === 2 && current.state === 'current', '用户可再次检查最新版本');
// Window focus/visibility can fire together. Neither should bypass the 15 minute throttle.
current.window.dispatchEvent(new current.window.Event('focus'));
current.window.document.dispatchEvent(new current.window.Event('visibilitychange'));
await delay(0);
assert.equal(current.releaseChecks, 2);
current.advanceTime(15 * 60 * 1000 + 1);
current.window.dispatchEvent(new current.window.Event('focus'));
current.window.document.dispatchEvent(new current.window.Event('visibilitychange'));
await waitFor(() => current.releaseChecks === 3 && current.state === 'current', '回到前台后进行单次检查');
current.advanceTime(6 * 3600 * 1000);
await current.runInterval(6 * 3600 * 1000);
assert.equal(current.releaseChecks, 4);
current.dom.window.close();

// An offline/error result is visible and retryable, rather than silently hiding the button.
const offline = await boot({
  storeBuild: false, online: false, release: makeRelease([], '1.0.0'),
  releaseFetch: async attempt => {
    if (attempt <= 2) throw new TypeError('Failed to fetch');
    return { ok: true, json: async () => makeRelease([], '1.0.0') };
  }
});
await offline.runTimer(5000);
assert.equal(offline.state, 'error');
assert.match(offline.status, /网络已断开/);
assert.equal(offline.button.textContent, '重试 / Retry');
offline.setOnline(true);
offline.button.click();
await waitFor(() => offline.state === 'current', '重新联网后重试成功');
assert.equal(offline.releaseChecks, 3);
offline.dom.window.close();

const httpFailure = await boot({
  storeBuild: false, release: makeRelease([]),
  releaseFetch: async () => ({ ok: false, status: 503 })
});
await httpFailure.runTimer(5000);
assert.equal(httpFailure.state, 'error');
assert.match(httpFailure.status, /更新服务.*HTTP 503/);
httpFailure.dom.window.close();

const fallbackManifest = {
  schemaVersion: 1, version: '1.1.0',
  edgeURL: 'https://github.com/porcelaintech/parallel-workshop/releases/download/v1.1.0/edge-extension.zip',
  edgeSHA256: VALID_DIGEST, notes: '更新说明'
};
const apiRateLimit = await boot({
  storeBuild: false, release: makeRelease([]), fallbackManifest,
  releaseFetch: async () => ({ ok: false, status: 403 })
});
await exposeUpdateBanner(apiRateLimit);
assert.equal(apiRateLimit.state, 'available', 'API 限流应使用官方 Release 更新清单恢复检查');
assert.equal(apiRateLimit.fetchedURLs.filter(url => url.endsWith('/update.json')).length, 1);
apiRateLimit.dom.window.close();

for (const corruptManifest of [
  { ...fallbackManifest, schemaVersion: 2 },
  { ...fallbackManifest, edgeURL: 'https://evil.example/edge-extension.zip' },
  { ...fallbackManifest, edgeURL: fallbackManifest.edgeURL.replace('/v1.1.0/', '/v1.0.0/') },
  { ...fallbackManifest, edgeSHA256: 'not-a-sha256' }
]) {
  const invalidFallback = await boot({
    storeBuild: false, release: makeRelease([]), fallbackManifest: corruptManifest,
    releaseFetch: async () => ({ ok: false, status: 403 })
  });
  await invalidFallback.runTimer(5000);
  assert.equal(invalidFallback.state, 'error', '备用清单必须绑定版本、官方仓库、精确资产名与摘要');
  assert.equal(invalidFallback.downloads.length, 0);
  invalidFallback.dom.window.close();
}

const timeout = await boot({
  storeBuild: false, release: makeRelease([]),
  releaseFetch: async (_attempt, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new Error('network aborted')));
  })
});
timeout.button.click();
timeout.button.click();
await waitFor(() => timeout.releaseChecks === 1, '开始有界的检查请求');
assert.equal(timeout.state, 'checking');
assert.equal(timeout.button.disabled, true);
await timeout.runTimer(15000);
await waitFor(() => timeout.releaseChecks === 2, '超时后进行一次重试');
await timeout.runTimer(15000);
await waitFor(() => timeout.state === 'error', '超时失败可恢复');
assert.match(timeout.status, /检查更新超时/);
assert.equal(timeout.releaseChecks, 2, '重复点击不应启动平行请求');
timeout.dom.window.close();

// Store build: a user click starts Edge's native check. The ready event is allowed to
// race with the Promise result, but the extension must schedule exactly one reload.
let resolveStoreCheck;
const storeCheckResult = new Promise(resolve => { resolveStoreCheck = resolve; });
const store = await boot({
  storeBuild: true,
  release: makeRelease([]),
  requestUpdateCheck: () => storeCheckResult
});
const storeButton = await exposeUpdateBanner(store);
storeButton.click();
storeButton.click();
await waitFor(() => store.updateChecks === 1, '商店版发起 requestUpdateCheck');
if (!store.window.document.getElementById('update-banner').textContent.includes('正在通过 Edge')) {
  throw new Error('商店版没有向用户显示更新进度');
}
store.fireUpdateAvailable({ version: '1.1.0' });
resolveStoreCheck({ status: 'update_available', version: '1.1.0' });
await delay(0);
if (store.timerCount(250) !== 1) {
  throw new Error('onUpdateAvailable 与 requestUpdateCheck 竞态导致重复安排重载');
}
await store.runTimer(250);
if (store.reloads !== 1) throw new Error('商店版没有通过 runtime.reload 完成一键更新');
assert.equal(store.reloadReceipt?.tabId, 7, '商店重载前必须记录可恢复的原工作台');
assert.deepEqual(JSON.parse(JSON.stringify(store.reloadReceipt?.tabIds)), [7]);
if (store.downloads.length || store.objectURLs) {
  throw new Error('商店版错误地走了 ZIP 下载路径');
}
store.dom.window.close();

// Store fallback: even if the event is delayed, an update_available result completes
// the same one-click path instead of leaving the UI waiting indefinitely.
const storeResultOnly = await boot({
  storeBuild: true,
  release: makeRelease([]),
  requestUpdateCheck: async () => ({ status: 'update_available', version: '1.1.0' })
});
(await exposeUpdateBanner(storeResultOnly)).click();
await waitFor(() => storeResultOnly.timerCount(250) === 1, '商店检查结果安排重载');
await storeResultOnly.runTimer(250);
if (storeResultOnly.updateChecks !== 1 || storeResultOnly.reloads !== 1) {
  throw new Error('商店版 update_available 结果未完成单次重载');
}
storeResultOnly.dom.window.close();

// A native-ready event can arrive while GitHub is still pending. It must remain
// actionable immediately, and a later GitHub result must not erase that state.
let finishGithubCheck;
const githubCheck = new Promise(resolve => { finishGithubCheck = resolve; });
const storeReadyDuringCheck = await boot({
  storeBuild: true, release: makeRelease([]),
  releaseFetch: () => githubCheck
});
storeReadyDuringCheck.button.click();
await waitFor(() => storeReadyDuringCheck.state === 'checking', '检查正在等待 GitHub');
storeReadyDuringCheck.fireUpdateAvailable({ version: '1.1.0' });
assert.equal(storeReadyDuringCheck.state, 'ready');
storeReadyDuringCheck.button.click();
assert.equal(storeReadyDuringCheck.timerCount(250), 1);
finishGithubCheck({ ok: true, json: async () => makeRelease([], '1.0.0') });
await delay(0);
assert.equal(storeReadyDuringCheck.state, 'reloading');
await storeReadyDuringCheck.runTimer(250);
assert.equal(storeReadyDuringCheck.reloads, 1);
storeReadyDuringCheck.dom.window.close();

// Edge may leave a native request unresolved. The button must recover and a
// deliberate retry must be able to finish; a stale Promise cannot restart twice.
let storeAttempts = 0;
const storeTimeout = await boot({
  storeBuild: true, release: makeRelease([]),
  requestUpdateCheck: () => ++storeAttempts === 1
    ? new Promise(() => {})
    : Promise.resolve({ status: 'update_available', version: '1.1.0' })
});
(await exposeUpdateBanner(storeTimeout)).click();
await waitFor(() => storeTimeout.state === 'installing', 'Edge 原生检查开始');
await storeTimeout.runTimer(15000);
await waitFor(() => storeTimeout.state === 'error', 'Edge 原生检查超时后恢复');
storeTimeout.button.click();
await waitFor(() => storeTimeout.timerCount(250) === 1, '重试完成商店更新');
await storeTimeout.runTimer(250);
assert.equal(storeTimeout.reloads, 1);
storeTimeout.dom.window.close();

// Side-loaded build: the store ZIP and arbitrary ZIPs deliberately precede the user
// ZIP. Fetch and verify only the exact user ZIP before delivering the file.
const storeAssetURL = 'https://downloads.example/edge-extension-store.zip';
const otherAssetURL = 'https://downloads.example/source.zip';
const userAssetURL = 'https://downloads.example/edge-extension.zip';
const sideLoaded = await boot({
  storeBuild: false,
  release: makeRelease([
    { name: 'edge-extension-store.zip', browser_download_url: storeAssetURL },
    { name: 'source.zip', browser_download_url: otherAssetURL },
    { name: 'edge-extension.zip', browser_download_url: userAssetURL, digest: `sha256:${VALID_DIGEST}` }
  ]),
  assetFetchFailures: 1,
  assetBodyFailures: 1
});
(await exposeUpdateBanner(sideLoaded)).click();
sideLoaded.button.click();
await waitFor(() => sideLoaded.downloads.length === 1, '侧载版下载用户包');
if (sideLoaded.downloads[0].download !== 'edge-extension.zip' ||
    !sideLoaded.downloads[0].href.startsWith('blob:edge-update-test-') ||
    sideLoaded.fetchedURLs.filter(url => url === userAssetURL).length !== 3 ||
    sideLoaded.fetchedURLs.includes(storeAssetURL) ||
    sideLoaded.fetchedURLs.includes(otherAssetURL)) {
  throw new Error('侧载版没有精确选择 edge-extension.zip');
}
if (sideLoaded.updateChecks !== 0 || sideLoaded.reloads !== 0 || sideLoaded.objectURLs !== 1) {
  throw new Error('侧载版与商店更新路径发生了串路');
}
assert.equal(sideLoaded.state, 'downloaded');
assert.match(sideLoaded.status, /install\.bat.*自动完成更新/, '侧载版必须说明实际安装步骤（运行 install.bat 或重启智囊自动更新）');
assert.notEqual(sideLoaded.window.document.getElementById('update-banner').style.display, 'none');
sideLoaded.dom.window.close();

// Fail closed if a release contains only the store package.
const missingUserAsset = await boot({
  storeBuild: false,
  release: makeRelease([{ name: 'edge-extension-store.zip', browser_download_url: storeAssetURL }])
});
(await exposeUpdateBanner(missingUserAsset)).click();
await waitFor(
  () => missingUserAsset.window.document.getElementById('update-banner').textContent.includes('下载失败'),
  '缺少用户包时失败关闭'
);
if (missingUserAsset.downloads.length || missingUserAsset.fetchedURLs.includes(storeAssetURL)) {
  throw new Error('缺少用户包时错误下载了商店包');
}
missingUserAsset.dom.window.close();

// A mismatched release digest must fail closed before handing any file to Edge.
const badDigest = await boot({
  storeBuild: false,
  release: makeRelease([
    { name: 'edge-extension.zip', browser_download_url: userAssetURL, digest: `sha256:${'bb'.repeat(32)}` }
  ])
});
(await exposeUpdateBanner(badDigest)).click();
await waitFor(
  () => badDigest.window.document.getElementById('update-banner').textContent.includes('下载失败'),
  'SHA-256 不匹配时失败关闭'
);
if (badDigest.downloads.length || badDigest.objectURLs) {
  throw new Error('SHA-256 不匹配时仍交付了更新包');
}
badDigest.dom.window.close();

// Browser-restored text must keep the workbench usable while activation waits.
const pendingDraft = await boot({ storeBuild: false, release: makeRelease([], '1.0.0'),
  installedVersion: '1.1.0', initialDraft: 'Keep my unsent question' });
assert.equal(pendingDraft.state, 'installed-pending');
assert.equal(pendingDraft.window.document.getElementById('question').value, 'Keep my unsent question');
assert.equal(pendingDraft.window.document.getElementById('startup-overlay').classList.contains('done'), true,
  '等待草稿完成时也必须正常结束启动遮罩');
assert.equal(pendingDraft.reloads, 0);
pendingDraft.button.click();
await delay(10);
assert.equal(pendingDraft.state, 'installed-pending');
assert.equal(pendingDraft.releaseChecks, 0, '本地新版待启用时不应覆盖为远程检查结果');
pendingDraft.dom.window.close();

console.log('✅ Edge 更新：永久入口、无新版、离线/HTTP/超时重试、官方备用源、前台节流、商店单次重载、侧载精确资产/SHA-256 全部通过');
