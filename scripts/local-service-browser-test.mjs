import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { BrowserManager } from '../local-service/lib/browser.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const browserPath = process.env.BRAINTRUST_TEST_BROWSER || [
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/microsoft-edge', '/usr/bin/google-chrome', '/usr/bin/chromium'
].find(existsSync);
if (!browserPath) {
  console.error('SKIP: real Chromium/Edge unavailable; browser acceptance was not executed.');
  process.exit(77);
}
const work = mkdtempSync(join(tmpdir(), 'braintrust-browser-test-'));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(check, message, ms = 10000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    try { const value = await check(); if (value) return value; } catch {}
    await sleep(50);
  }
  throw new Error(message);
}
async function cdp(target, method, params = {}) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  let timer;
  try {
    await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('test CDP connect timeout')), 5000);
      socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true });
    });
    clearTimeout(timer);
    return await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('test CDP request timeout')), 10000);
      socket.addEventListener('message', event => {
        const response = JSON.parse(event.data);
        if (response.id !== 1) return;
        if (response.error) reject(new Error(response.error.message)); else resolve(response.result);
      });
      socket.send(JSON.stringify({ id: 1, method, params }));
    });
  } finally { clearTimeout(timer); socket.close(); }
}
const evaluate = async (target, expression) => (await cdp(target, 'Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })).result?.value;
const fixture = createServer((request, response) => {
  const missing = request.url.startsWith('/missing');
  const attachment = !request.url.startsWith('/no-attachment');
  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  response.end(`<!doctype html><meta charset="utf-8"><title>Local deterministic fixture</title>
    ${missing ? '<p>Sign in to continue</p>' : `<textarea id="input"></textarea><button id="send" disabled>Send</button>${attachment ? '<input type="file" id="file">' : ''}`}
    <pre id="answer"></pre><script>
    window.received = null;
    const input = document.querySelector('#input');
    if (input) {
      input.addEventListener('input', () => { setTimeout(() => { document.querySelector('#send').disabled = false; }, 150); });
      document.querySelector('#send').addEventListener('click', () => {
        const file = document.querySelector('#file')?.files[0];
        window.received = { text: input.value, filename: file?.name || null, size: file?.size || 0 };
        document.querySelector('#answer').textContent = 'fixture answer: ' + input.value;
      });
    }
    </script>`);
});
await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
const fixtureURL = `http://localhost:${fixture.address().port}`;
const adapter = { id: 'chatgpt', name: 'Local fixture', origin: fixtureURL + '/delayed', homeHosts: ['localhost'], input: { selectors: ['#input'] }, send: { type: 'button', selectors: ['#send'] }, attachment: { selectors: ['#file'] }, probe: {} };
const oldHeadless = process.env.BRAINTRUST_BROWSER_HEADLESS;
process.env.BRAINTRUST_BROWSER_HEADLESS = '1';
let manager;
let service;
let serviceOutput = '';
const logs = [];
try {
  manager = new BrowserManager({ dataDir: join(work, 'browser-data'), browser: browserPath, serviceURL: 'about:blank', log: text => logs.push(text) });
  const concurrent = await Promise.all(Array.from({ length: 6 }, () => manager.ensureRunning()));
  assert.equal(new Set(concurrent.map(item => item.port)).size, 1, 'concurrent startup must share one debug port');
  assert.ok(concurrent.every(item => item.running && item.version), 'all concurrent callers must await a usable browser');
  console.log('PASS: six concurrent starts share one ready browser');

  let target = await manager.openPlatform(adapter);
  await waitFor(() => evaluate(target, 'Boolean(document.querySelector("#input"))'), 'fixture input not ready');
  const result = await manager.send(adapter, 'delayed button test', [{ name: 'tiny.txt', mime: 'text/plain', data: Buffer.from('fixture').toString('base64') }]);
  assert.equal(result.ok, true, JSON.stringify(result));
  const received = await waitFor(() => evaluate(target, 'window.received'), 'fixture did not receive injected message');
  assert.deepEqual(received, { text: 'delayed button test', filename: 'tiny.txt', size: 7 });
  console.log('PASS: delayed button enables before send; file reaches fixture');
  await fetch(`http://127.0.0.1:${manager.port}/json/close/${target.id}`);

  target = await manager.openPlatform({ ...adapter, origin: fixtureURL + '/missing' });
  await waitFor(() => evaluate(target, 'document.readyState === "complete"'), 'missing-input fixture not ready');
  const missing = await manager.send(adapter, 'must not succeed');
  assert.equal(missing.ok, false, 'missing input must fail');
  assert.equal(missing.error, 'NO_INPUT');
  console.log('PASS: missing input reports failure');
  await fetch(`http://127.0.0.1:${manager.port}/json/close/${target.id}`);

  target = await manager.openPlatform({ ...adapter, origin: fixtureURL + '/no-attachment' });
  await waitFor(() => evaluate(target, 'Boolean(document.querySelector("#input"))'), 'attachment fixture not ready');
  const unattached = await manager.send(adapter, 'must keep attachment honest', [{ name: 'tiny.txt', mime: 'text/plain', data: Buffer.from('fixture').toString('base64') }]);
  assert.equal(unattached.ok, false, 'unavailable attachment upload must not report success');
  assert.equal(await evaluate(target, 'window.received'), null, 'must not send text after attachment failure');
  console.log('PASS: unavailable attachment rejects before sending text');

  let bridgeStopped = false;
  manager.frameBridge = { stop: async () => { bridgeStopped = true; } };
  const oldChild = manager.child;
  const exited = new Promise(resolve => oldChild.once('exit', resolve));
  oldChild.kill();
  await exited;
  await manager.ensureRunning();
  assert.equal(bridgeStopped, true, 'stale bridge must close after browser exits');
  assert.equal(manager.frameBridge, null, 'new browser must not inherit stale bridge');
  assert.notEqual(manager.child.pid, oldChild.pid);
  console.log('PASS: browser restart discards stale iframe bridge');
  await manager.stop();
  manager = null;

  const stage = join(work, 'service');
  cpSync(join(root, 'local-service'), stage, { recursive: true });
  mkdirSync(join(stage, 'data', 'adapters'), { recursive: true });
  writeFileSync(join(stage, 'data', 'adapters', 'chatgpt.json'), JSON.stringify({ ...adapter, origin: fixtureURL + '/missing' }));
  const data = join(work, 'service-data');
  const env = { ...process.env, HOME: join(work, 'home'), USERPROFILE: join(work, 'home'), LOCALAPPDATA: join(work, 'local'), APPDATA: join(work, 'roaming'), BRAINTRUST_BROWSER_PATH: browserPath, BRAINTRUST_BROWSER_HEADLESS: '1' };
  service = spawn(process.execPath, [join(stage, 'server.mjs'), '--no-browser', '--print-ready', '--data-dir', data], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  service.stdout.on('data', chunk => { serviceOutput += chunk; });
  service.stderr.on('data', chunk => { serviceOutput += chunk; });
  const ready = await waitFor(() => {
    const line = serviceOutput.split(/\r?\n/).find(line => line.startsWith('{"ok":true'));
    return line && JSON.parse(line);
  }, 'staged service did not start');
  const headers = { authorization: `Bearer ${ready.token}`, 'content-type': 'application/json' };
  const api = async (path, body) => {
    const response = await fetch(ready.url + path, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30000) });
    assert.equal(response.status, 200);
    return response.json();
  };
  await api('api/platforms/chatgpt/open', {});
  await sleep(400);
  const failedSend = await api('api/send', { text: 'should fail honestly', platforms: ['chatgpt'] });
  assert.equal(failedSend.ok, false, 'top-level API must propagate injection failure');
  assert.equal(failedSend.results[0].ok, false, 'per-platform API must propagate injection failure');
  assert.equal(failedSend.results[0].result.error, 'NO_INPUT');
  console.log('PASS: API exposes injection failure at platform and top level');
  await api('api/quit', {});
  await waitFor(() => service.exitCode !== null, 'service did not quit');
  service = null;
  console.log('PASS: isolated real-browser reliability acceptance completed');
} catch (error) {
  console.error(logs.slice(-10).join('\n'));
  if (serviceOutput) console.error(serviceOutput.replace(/"token":"[^"]+"/g, '"token":"REDACTED"'));
  throw error;
} finally {
  if (manager) await manager.stop().catch(() => {});
  if (service && service.exitCode === null) service.kill();
  fixture.closeAllConnections();
  await new Promise(resolve => fixture.close(resolve));
  if (oldHeadless === undefined) delete process.env.BRAINTRUST_BROWSER_HEADLESS; else process.env.BRAINTRUST_BROWSER_HEADLESS = oldHeadless;
  await sleep(300);
  rmSync(work, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
