import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const source = readFileSync(base + 'Windows/edge-extension/background.js', 'utf8');

async function runCase(tab, { existing = [], pending, installed = false, readySender, readySenders, fastTime = false } = {}) {
  const calls = [];
  let actionListener = null;
  let installedListener;
  let messageListener;
  // onInstalled 自动打开前有 30 秒宽限期（等启动页注册，避免重复弹窗）。
  // 测试用快进时钟让宽限期立即到期，验证「无入口时最终仍会自动打开」。
  const FakeDate = class extends Date { static now() { FakeDate._now += 40000; return FakeDate._now; } };
  FakeDate._now = 1000000;
  const chrome = {
    runtime: {
      id: 'test-extension',
      getURL: path => `chrome-extension://test-extension/${path}`,
      getContexts: async () => existing.filter(tab => String(tab.url || '').startsWith('chrome-extension://test-extension/'))
        .map(tab => ({ tabId: tab.id, windowId: tab.windowId, frameId: 0, documentUrl: tab.url })),
      onMessage: { addListener(listener) { messageListener = listener; } },
      onInstalled: { addListener(listener) { installedListener = listener; } },
      get lastError() { return null; }
    },
    action: { onClicked: { addListener(listener) { actionListener = listener; } } },
    tabs: {
      update: async (id, options) => { calls.push(['tabs.update', id, options]); },
      query: async () => existing,
      get: async id => existing.find(item => item.id === id),
      remove: async id => calls.push(['tabs.remove', id]),
      onRemoved: { addListener() {} }
    },
    windows: {
      update: async (id, options) => { calls.push(['windows.update', id, options]); },
      create: async options => { calls.push(['windows.create', options]); }
    },
    storage: {
      session: { get: async () => ({}), set: async () => {}, remove: async () => {} },
      local: {
        get: async () => pending ? { 'wb-pending-extension-reload': pending } : {},
        remove: async key => calls.push(['storage.remove', key])
      }
    },
    declarativeNetRequest: { updateSessionRules: async () => {} },
    webNavigation: { getAllFrames: async ({ tabId }) => [{ frameId: 0, url: existing.find(tab => tab.id === tabId)?.url }] },
    debugger: { attach() {}, detach() {}, sendCommand() {} }
  };
  runInNewContext(source, { chrome, URL, Set, Number, Promise, setTimeout, clearTimeout, console, ...(fastTime ? { Date: FakeDate } : {}) });
  if (typeof actionListener !== 'function') throw new Error('action listener 未注册');
  if (installed) installedListener({ reason: 'install' });
  else if (readySenders) {
    for (const sender of readySenders) messageListener({ type: 'WB_LAUNCH_READY' }, sender, reply => calls.push(['reply', reply]));
  } else if (readySender) messageListener({ type: 'WB_LAUNCH_READY' }, readySender, reply => calls.push(['reply', reply]));
  else if (!pending) actionListener(tab);
  await new Promise(resolve => setTimeout(resolve, 0));
  await new Promise(resolve => setTimeout(resolve, 0));
  return calls;
}

for (const url of ['about:blank', 'edge://newtab/', 'edge://new-tab-page/', 'chrome://newtab/', 'chrome://new-tab-page/']) {
  const calls = await runCase({ id: 7, windowId: 3, url });
  if (calls.filter(call => call[0] === 'tabs.update').length !== 1 || calls.some(call => call[0] === 'windows.create')) {
    throw new Error(`${url} 未被原地复用：${JSON.stringify(calls)}`);
  }
}

const normalCalls = await runCase({ id: 8, windowId: 4, url: 'https://example.com/' });
if (normalCalls.filter(call => call[0] === 'windows.create').length !== 1 || normalCalls.some(call => call[0] === 'tabs.update')) {
  throw new Error(`普通页面不应被覆盖：${JSON.stringify(normalCalls)}`);
}

console.log('✅ Edge 工具栏启动策略通过（空白页原地复用；普通页面独立打开）');

const existing = [{ id: 20, windowId: 8, url: 'chrome-extension://test-extension/workbench.html' }];
const focused = await runCase({ id: 10, url: 'https://example.com/' }, { existing });
assert.equal(focused.filter(call => call[0] === 'windows.create').length, 0);
assert.equal(focused.find(call => call[0] === 'tabs.update')[1], 20);
assert.equal((await runCase(null, { installed: true, fastTime: true })).filter(call => call[0] === 'windows.create').length, 1,
  '安装事件在宽限期内没有任何入口时，最终必须自动打开工作台');
const installedWithEntry = await runCase(null, { installed: true, fastTime: true, existing: [{ id: 30, windowId: 8, url: 'chrome-extension://test-extension/launch.html' }] });
assert.equal(installedWithEntry.filter(call => call[0] === 'windows.create').length, 0, '已存在启动页时安装事件不得重复弹窗');
const recovered = await runCase(null, { existing, pending: { tabId: 20, version: '0.4.0', createdAt: Date.now() } });
assert.equal(recovered.filter(call => call[0] === 'windows.create').length, 0);
assert.equal(recovered.find(call => call[0] === 'tabs.update')[2].url, 'chrome-extension://test-extension/launch.html');
const expired = await runCase(null, { pending: { tabId: 20, createdAt: Date.now() - 130000 } });
assert.equal(expired.filter(call => call[0] === 'windows.create').length, 0);
const forged = await runCase(null, { readySender: { id: 'test-extension', url: 'https://example.com/', tab: { id: 20 } } });
assert.equal(forged.find(call => call[0] === 'reply')[1].ok, false);
const ready = await runCase(null, { readySender: { id: 'test-extension', frameId: 0, url: 'chrome-extension://test-extension/launch.html', tab: { id: 20 } } });
assert.equal(ready.find(call => call[0] === 'tabs.update')[2].url, 'chrome-extension://test-extension/workbench.html');
const ntpRecovery = await runCase(null, { existing: [{ id: 20, url: 'https://ntp.msn.cn/edge/ntp?locale=zh-CN' }],
  pending: { tabId: 20, createdAt: Date.now() } });
assert.equal(ntpRecovery.find(call => call[0] === 'tabs.update')[1], 20, '重载产生的 Edge 新标签应在原位置恢复');
assert.equal(ntpRecovery.filter(call => call[0] === 'windows.create').length, 0);
const userNavigated = await runCase(null, { existing: [{ id: 20, url: 'https://example.com/work' }],
  pending: { tabId: 20, createdAt: Date.now() } });
assert.equal(userNavigated.filter(call => call[0] === 'tabs.update').length, 0, '不能覆盖用户新打开的其他网站');
const concurrentTabs = [20, 21].map(id => ({ id, windowId: id, url: 'chrome-extension://test-extension/launch.html' }));
const concurrent = await runCase(null, { existing: concurrentTabs, readySenders: concurrentTabs.map(tab => ({
  id: 'test-extension', frameId: 0, url: tab.url, tab
})) });
assert.equal(concurrent.filter(call => call[0] === 'tabs.update' && call[2].url?.endsWith('/workbench.html')).length, 1,
  '同时到达的两个启动页只能产生一个工作台');
assert.equal(concurrent.filter(call => call[0] === 'tabs.remove').length, 1, '另一启动页应聚焦已有工作台并收起');
const embedded = await runCase(null, { readySender: { id: 'test-extension', frameId: 5,
  url: 'chrome-extension://test-extension/launch.html', tab: { id: 20 } } });
assert.equal(embedded.find(call => call[0] === 'reply')[1].ok, false, '外部网页嵌入的启动页不可导航父标签');
assert.equal(embedded.filter(call => ['tabs.update', 'tabs.remove', 'windows.create'].includes(call[0])).length, 0);
// A navigation request can complete while getContexts still omits the restored
// workbench and Edge still reports its temporary new-tab document.
const delayedContext = await runCase(null, {
  existing: [{ id: 20, windowId: 1, url: 'edge://newtab/' },
    { id: 21, windowId: 2, url: 'chrome-extension://test-extension/launch.html' }],
  pending: { tabId: 21, tabIds: [21, 20], workbenchTabIds: [20], version: '0.4.0', createdAt: Date.now() },
  readySender: { id: 'test-extension', frameId: 0, url: 'chrome-extension://test-extension/launch.html', tab: { id: 21 } }
});
const delayedNavigations = delayedContext.filter(call => call[0] === 'tabs.update' && call[2].url);
assert.equal(delayedNavigations[0][1], 20, '必须先恢复原工作台，再恢复启动页');
assert.equal(delayedNavigations.filter(call => call[2].url.endsWith('/workbench.html')).length, 1,
  '原工作台context尚未出现时，不得把启动页提升为第二工作台');
assert.equal(delayedContext.find(call => call[0] === 'tabs.remove')[1], 21, '仅收起重复启动页，保留原工作台');
console.log('✅ Edge 首次打开、已有窗口复用、更新恢复、超期恢复拒绝与启动发送者校验通过');
