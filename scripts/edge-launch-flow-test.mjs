import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const root = decodeURIComponent(new URL('..', import.meta.url).pathname);
const launch = readFileSync(root + 'Windows/edge-extension/launch.js', 'utf8');
const workbench = readFileSync(root + 'Windows/edge-extension/workbench.js', 'utf8');
const start = readFileSync(root + 'Windows/edge-extension/start.js', 'utf8');

async function boot({ running = '0.3.1', installed = running, previous, embedded = false, readError = false, firstRun = false } = {}) {
  const calls = [];
  const elements = new Map();
  const document = { getElementById: id => {
    if (!elements.has(id)) elements.set(id, {
      hidden: true, textContent: '', value: 0,
      addEventListener(type, fn) { (this._listeners ||= {})[type] = fn; },
      click() { const fn = this._listeners?.click; if (fn) fn(); }
    });
    return elements.get(id);
  } };
  const window = {};
  window.self = window;
  window.top = embedded ? {} : window;
  const chrome = {
    runtime: {
      getManifest: () => ({ version: running }),
      getURL: path => 'chrome-extension://test/' + path,
      getContexts: async () => [{ tabId: 9, frameId: 0, documentUrl: 'chrome-extension://test/launch.html' }],
      reload: () => calls.push(['reload']),
      sendMessage: async message => { calls.push(['ready', message]); return { ok: true }; }
    },
    tabs: { getCurrent: async () => ({ id: 9 }) },
    storage: { local: {
      get: async () => firstRun
        ? { 'wb-pending-extension-reload': previous }
        : { 'wb-onboarded': true, 'wb-pending-extension-reload': previous },
      set: async value => calls.push(['set', value])
    } }
  };
  const fetch = async (_url, options) => {
    calls.push(['fetch', options.cache]);
    if (readError) throw new Error('read failed');
    return { ok: true, json: async () => ({ version: installed }) };
  };
  runInNewContext(launch, { window, document, chrome, fetch, AbortController, setTimeout, clearTimeout, console });
  await new Promise(resolve => setTimeout(resolve, 0));
  await new Promise(resolve => setTimeout(resolve, 0));
  let onboardingWasVisible = false;
  if (firstRun) {
    const done = elements.get('launch-onboarding-done');
    onboardingWasVisible = !elements.get('launch-onboarding').hidden;
    if (done) done.click?.();
    await new Promise(resolve => setTimeout(resolve, 0));
    await new Promise(resolve => setTimeout(resolve, 0));
  }
  return { calls, elements, onboardingWasVisible };
}

const current = await boot();
assert.equal(current.calls.filter(call => call[0] === 'reload').length, 0);
assert.equal(current.calls.filter(call => call[0] === 'ready').length, 1);
assert.equal(current.calls.find(call => call[0] === 'fetch')[1], 'no-store');
const updated = await boot({ installed: '0.4.0' });
assert.equal(updated.calls.filter(call => call[0] === 'reload').length, 1);
assert.equal(updated.calls.filter(call => call[0] === 'ready').length, 0);
assert.deepEqual(JSON.parse(JSON.stringify(updated.calls.find(call => call[0] === 'set')[1]['wb-pending-extension-reload'].tabIds)), [9]);
const repeated = await boot({ installed: '0.4.0', previous: { version: '0.4.0', createdAt: Date.now() } });
assert.equal(repeated.calls.filter(call => call[0] === 'reload').length, 0, '相同版本不得进入无限reload循环');
assert.equal(repeated.elements.get('launch-retry').hidden, false);
assert.equal((await boot({ readError: true })).calls.filter(call => call[0] === 'reload').length, 0);
assert.equal((await boot({ embedded: true, installed: '0.4.0' })).calls.length, 0, '嵌入的launch不可读取版本、发消息或reload');
// 首次运行：引导页出现、点击「开始使用」后进入启动流程并写入完成标记
const first = await boot({ firstRun: true });
assert.equal(first.onboardingWasVisible, true, '首次运行必须展示引导页');
assert.equal(first.calls.filter(call => call[0] === 'ready').length, 1, '点击开始使用后必须进入启动流程');
assert.equal(first.calls.find(call => call[0] === 'set')[1]['wb-onboarded'], true, '必须持久化引导完成标记');
runInNewContext(workbench, { window: { self: {}, top: {} }, chrome: new Proxy({}, { get() { throw new Error('嵌入workbench调用了扩展API'); } }) });
assert.match(start, /launch\.html/, '本地入口必须导航到统一启动页');
assert.match(start, /Date\.now\(\) \+ 15000/, '未安装时必须有限等待');
assert.match(start, /location\.replace\(launchURL\)/, '轮询未果时必须有兜底导航');
console.log('✅ 启动页：版本一致直达、旧运行版单次reload、回环保护、读取失败、外部iframe拒绝、首次引导、本地入口兼容');
