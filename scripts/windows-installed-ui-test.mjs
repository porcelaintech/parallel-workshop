#!/usr/bin/env node
// Runs against the installed product, not a second copy of its web frontend.
// Fixtures only replace AI documents; they do not replace product scripts or APIs.
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const { values: args } = parseArgs({ options: {
  'service-info': { type: 'string' }, evidence: { type: 'string' },
  'verify-persistence': { type: 'boolean' }, 'live-probe': { type: 'boolean' },
  download: { type: 'boolean' }, browser: { type: 'string' }, output: { type: 'string' }, url: { type: 'string', default: 'https://braintrust.chat/' }
}});
if (!args.evidence || (!args.download && !args['service-info']) || (args.download && (!args.browser || !args.output))) throw new Error('Usage: node windows-installed-ui-test.mjs --service-info PATH --evidence DIR [--verify-persistence|--live-probe]');
const evidence = resolve(args.evidence);
mkdirSync(evidence, { recursive: true });
const service = args.download ? null : JSON.parse(readFileSync(args['service-info'], 'utf8').replace(/^\uFEFF/, ''));
const base = service ? `http://127.0.0.1:${service.port}` : null;
const report = { mode: args.download ? 'public-browser-download' : args['live-probe'] ? 'unauthenticated-live-probe' : args['verify-persistence'] ? 'persistence' : 'deterministic-installed-ui', startedAt: new Date().toISOString(), checks: [], limitations: ['Automated browser interaction does not validate Windows SmartScreen or a physical desktop.', 'Fixture responses do not validate third-party AI accounts or real AI answers.'] };
const connections = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, description, timeout = 30000) {
  const deadline = Date.now() + timeout;
  let last;
  do {
    try { const result = await fn(); if (result) return result; } catch (error) { last = error; }
    await delay(150);
  } while (Date.now() < deadline);
  throw new Error(`Timed out: ${description}${last ? ` (${last.message})` : ''}`);
}
async function api(path, body) {
  const response = await fetch(`${base}${path}`, { headers: { authorization: `Bearer ${service.token}`, 'content-type': 'application/json' }, method: body === undefined ? 'GET' : 'POST', body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(45000) });
  const json = await response.json();
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status} ${json.error || ''}`);
  return json;
}
class CDP {
  constructor(ws) { this.ws = ws; this.next = 0; this.pending = new Map(); this.events = new Map(); }
  static async open(url) {
    const client = new CDP(new WebSocket(url));
    connections.push(client);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP connection timeout')), 10000);
      client.ws.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      client.ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('CDP connection failed')); }, { once: true });
    });
    client.ws.addEventListener('message', ({ data }) => {
      const msg = JSON.parse(data);
      if (msg.id) {
        const entry = client.pending.get(msg.id);
        if (!entry) return;
        clearTimeout(entry.timer); client.pending.delete(msg.id);
        if (msg.error) entry.reject(new Error(`${entry.method}: ${msg.error.message}`));
        else entry.resolve(msg.result);
      } else for (const handler of client.events.get(msg.method) || []) Promise.resolve(handler(msg.params, msg.sessionId)).catch(error => { report.eventError = error.message; });
    });
    return client;
  }
  on(method, fn) { this.events.set(method, [...(this.events.get(method) || []), fn]); }
  send(method, params = {}, sessionId) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timeout`)); }, 20000);
      this.pending.set(id, { resolve, reject, timer, method });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'Browser JavaScript exception');
    return result.result?.value;
  }
  close() { for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(new Error('CDP closed')); } this.pending.clear(); this.ws.close(); }
}
const record = (name, detail = {}) => { report.checks.push({ name, passed: true, ...detail }); console.log(`PASS ${name}`); };
let page, browser, downloadProcess;
try {
  if (args.download) {
    const profile = mkdtempSync(join(tmpdir(), 'braintrust-download-browser-'));
    let endpoint = '';
    downloadProcess = spawn(args.browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    downloadProcess.stderr.on('data', chunk => { const match = String(chunk).match(/DevTools listening on (ws:\/\/[^\s]+)/); if(match) endpoint=match[1]; });
    downloadProcess.on('error', error => { report.launchError = error.message; });
    await until(() => endpoint, 'download browser remote endpoint', 20000);
    browser = await CDP.open(endpoint);
    const { targetInfos } = await browser.send('Target.getTargets');
    const tab = targetInfos.find(t=>t.type==='page');
    assert(tab, 'download browser page');
    const version = new URL(endpoint);
    const targets = await (await fetch(`http://${version.host}/json/list`)).json();
    page = await CDP.open(targets.find(t=>t.id===tab.targetId).webSocketDebuggerUrl);
    await page.send('Page.enable');
    await page.send('Network.enable');
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
    page.on('Network.responseReceived', ({type,response})=>{if(type==='Document'&&response.url.startsWith(args.url))report.httpStatus=response.status;});
    const downloadDir = join(profile, 'downloads');mkdirSync(downloadDir);
    await browser.send('Browser.setDownloadBehavior', { behavior: 'allowAndName', downloadPath: downloadDir, eventsEnabled: true });
    let downloaded;
    browser.on('Browser.downloadWillBegin', p=>{report.download={guid:p.guid,suggestedFilename:p.suggestedFilename,url:p.url};});
    browser.on('Browser.downloadProgress', p=>{if(p.state==='completed')downloaded=p;if(p.state==='canceled')report.downloadCanceled=true;});
    await page.send('Page.navigate', { url: args.url });
    await until(()=>page.evaluate(`document.readyState==='complete'`), 'official download page loaded');
    await page.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }).then(result=>writeFileSync(join(evidence,'public-download-page.png'),Buffer.from(result.data,'base64')));
    const link = await page.evaluate(`(() => {const a=[...document.querySelectorAll('a[href]')].find(a=>/\\.exe(?:$|[?#])/i.test(a.href)&&/Windows/i.test(a.textContent));return a?{href:a.href,label:a.textContent.trim()}:null;})()`);
    report.page={title:await page.evaluate('document.title'),text:await page.evaluate('document.body.innerText.slice(0,1000)')};
    if(!link)throw new Error(`Official Windows download link unavailable (HTTP ${report.httpStatus||'unknown'})`);
    report.link=link;
    record('Windows download link discovered from live official page');
    await page.evaluate(`(() => {const a=[...document.querySelectorAll('a[href]')].find(a=>a.href===${JSON.stringify(link.href)});a.click();})()`);
    await until(()=>downloaded, 'browser click downloads Windows installer', 90000);
    copyFileSync(join(downloadDir,downloaded.guid),args.output);
    record('browser click downloaded complete installer', {bytes:downloaded.receivedBytes});
  } else {
  const health = await api('/api/health');
  report.version = health.version;
  report.browser = health.browser?.version?.Browser;
  assert(health.browser?.running, 'Installed browser is running');
  const port = health.browser.port;
  const getTargets = async () => (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(5000) })).json();
  const target = await until(async () => (await getTargets()).find(item => item.type === 'page' && item.url.startsWith(`${base}/`)), 'installed workbench target');
  page = await CDP.open(target.webSocketDebuggerUrl);
  await page.send('Page.enable');
  await page.send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  const { platforms } = await api('/api/platforms');
  assert.equal(platforms.length, 6);
  const ids = platforms.map(item => item.id);
  const storedKey = 'braintrust.acceptance.persistence';
  if (args['verify-persistence']) {
    const persisted = await until(() => page.evaluate(`(() => { const expected=JSON.parse(localStorage.getItem('${storedKey}')||'null'); if(!expected)return null; const selected=JSON.parse(localStorage.getItem('braintrust.local.selected')||'null'); if(document.querySelectorAll('#checks input').length!==6||!document.querySelector('#startup-overlay')?.classList.contains('done'))return null; const checked=[...document.querySelectorAll('#checks input')].map((x,i)=>x.checked?${JSON.stringify(ids)}[i]:null).filter(Boolean);return {expected,selected,checked,count:document.querySelectorAll('#checks input').length};})()`), 'stored preferences restored');
    assert.deepEqual(persisted.selected, persisted.expected);
    assert.deepEqual(persisted.checked, persisted.expected);
    assert.equal(persisted.count, 6);
    record('platform selection survives process restart', { selected: persisted.checked });
  } else if (args['live-probe']) {
    await until(() => page.evaluate(`document.querySelector('#startup-overlay')?.classList.contains('done')`), 'startup completion');
    report.platforms = [];
    for (const platform of platforms) {
      const started = Date.now();
      try {
        const result = await api(`/api/platforms/${platform.id}/probe`);
        report.platforms.push({ id: platform.id, state: result.state, ok: result.ok, elapsedMs: Date.now() - started, hostname: result.url ? new URL(result.url).hostname : null });
      } catch (error) { report.platforms.push({ id: platform.id, error: error.message, elapsedMs: Date.now() - started }); }
    }
    record('unauthenticated platform probes recorded; no messages sent');
    await page.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }).then(result => writeFileSync(join(evidence, 'live-workbench.png'), Buffer.from(result.data, 'base64')));
  } else {
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    browser = await CDP.open(version.webSocketDebuggerUrl);
    const patterns = [...new Set(platforms.flatMap(adapter => [new URL(adapter.origin).hostname, ...(adapter.homeHosts || [])]))].map(host => ({ urlPattern: `*://${host}/*`, resourceType: 'Document', requestStage: 'Request' }));
    const fixture = `<!doctype html><meta charset="utf-8"><title>Braintrust local acceptance fixture</title><style>body{font:18px system-ui;padding:24px;background:#f7f7f5}textarea{width:90%;height:90px}button{padding:12px;margin:8px}.reply{margin-top:20px}</style><h2>Local test fixture</h2><p>This document replaces the remote AI site only during this test.</p><textarea id="chat-input" placeholder="Message"></textarea><input class="hidden-input wm-composer-srOnly" type="file" multiple><button aria-label="Send message" id="flow-end-msg-send" class="send-button-container">Send</button><button aria-label="发送消息">Send</button><div class="reply"></div><script>window.__fixture={messages:[]};function send(){const input=document.querySelector('textarea');if(!input.value)return;const msg={text:input.value,files:[...document.querySelector('input[type=file]').files].map(f=>({name:f.name,size:f.size,type:f.type}))};window.__fixture.messages.push(msg);document.querySelector('.reply').textContent='Fixture reply: '+msg.text;input.value='';}document.querySelectorAll('button').forEach(b=>b.onclick=send);document.querySelector('textarea').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();send();}};<\/script>`;
    const fulfill = async (client, params, sessionId) => {
      await client.send('Fetch.fulfillRequest', { requestId: params.requestId, responseCode: 200, responseHeaders: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }, { name: 'Cache-Control', value: 'no-store' }], body: Buffer.from(fixture).toString('base64') }, sessionId);
    };
    page.on('Fetch.requestPaused', params => fulfill(page, params));
    await page.send('Fetch.enable', { patterns });
    browser.on('Fetch.requestPaused', (params, sessionId) => fulfill(browser, params, sessionId));
    browser.on('Target.attachedToTarget', async ({ sessionId, targetInfo }) => {
      if (['page', 'iframe'].includes(targetInfo.type)) {
        await browser.send('Fetch.enable', { patterns }, sessionId);
        await browser.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
      }
    });
    await browser.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
    await page.evaluate(`localStorage.removeItem('braintrust.local.selected')`);
    await page.send('Page.reload', { ignoreCache: true });
    const ready = await until(() => page.evaluate(`(() => {const checks=document.querySelectorAll('#checks input');return document.querySelector('#startup-overlay')?.classList.contains('done')&&checks.length===6?{count:checks.length,progress:document.querySelector('#progress').textContent,startup:document.querySelector('#startup-text').textContent}:null;})()`), 'six-platform workbench ready', 45000);
    assert(!/启动失败/.test(ready.progress + ready.startup), `Startup failure: ${ready.progress}`);
    record('installed workbench boot and six platform controls', ready);
    // CDP interception can attach after the initial OOPIF navigation. Navigate each
    // existing iframe once more after its session has request interception enabled.
    await delay(800);
    await page.evaluate(`document.querySelectorAll('#panes iframe').forEach(f=>f.src=f.src)`);
    const targetClients = new Map();
    await until(async () => {
      const targets = await getTargets();
      for (const platform of platforms) {
        const host = new URL(platform.origin).hostname;
        const found = targets.find(t => t.type === 'iframe' && (()=>{try{return new URL(t.url).hostname===host}catch{return false}})());
        if (!found?.webSocketDebuggerUrl) return false;
        if (!targetClients.has(platform.id)) targetClients.set(platform.id, await CDP.open(found.webSocketDebuggerUrl));
        if (!await targetClients.get(platform.id).evaluate('Boolean(window.__fixture)')) return false;
      }
      return true;
    }, 'six fixture iframes', 45000);
    record('six AI panes rendered inside installed workbench using controlled fixtures');
    const initialPaging = await page.evaluate(`document.querySelector('#page-ind').textContent`);
    await page.evaluate(`document.querySelector('#page-right').click()`);
    const nextPaging = await page.evaluate(`document.querySelector('#page-ind').textContent`);
    assert.notEqual(initialPaging, nextPaging);
    await page.evaluate(`document.querySelector('#page-left').click();document.querySelector('.zoom-in').click()`);
    const zoom = await page.evaluate(`document.querySelector('.zoom-val').textContent`);
    assert.equal(zoom, '110%');
    record('pane pagination and zoom', { initialPaging, nextPaging, zoom });
    const marker = `Braintrust Windows acceptance ${Date.now()}`;
    const filename = 'braintrust-attachment-test.txt';
    await page.evaluate(`(() => {const input=document.querySelector('#question');input.value=${JSON.stringify(marker)};input.dispatchEvent(new Event('input',{bubbles:true}));const dt=new DataTransfer();dt.items.add(new File(['fixture attachment'],${JSON.stringify(filename)},{type:'text/plain'}));const file=document.querySelector('#file-input');file.files=dt.files;file.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    await until(() => page.evaluate(`document.querySelectorAll('#attach-chips .chip').length===1&&!document.querySelector('#send').disabled`), 'attachment chip');
    await page.evaluate(`document.querySelector('#send').click()`);
    const deliveries = [];
    for (const platform of platforms) {
      const receipt = await until(() => targetClients.get(platform.id).evaluate(`window.__fixture?.messages.find(message=>message.text===${JSON.stringify(marker)})`), `UI text/attachment delivery ${platform.id}`, 25000);
      assert.equal(receipt.files.length, 1);
      assert.equal(receipt.files[0].name, filename);
      assert.equal(receipt.files[0].size, Buffer.byteLength('fixture attachment'));
      assert.equal(await targetClients.get(platform.id).evaluate("document.querySelector('.reply').textContent"), `Fixture reply: ${marker}`);
      deliveries.push({ id: platform.id, textReceived: true, attachmentReceived: true, responseRendered: true });
    }
    record('UI send reaches all six iframe input/upload handlers and renders fixture responses', { deliveries });
    await page.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }).then(result => writeFileSync(join(evidence, 'installed-workbench-fixtures.png'), Buffer.from(result.data, 'base64')));
    await targetClients.get('chatgpt').evaluate(`document.querySelector('textarea').remove()`);
    await page.evaluate(`(() => {document.querySelectorAll('#checks input').forEach((input,i)=>{if(input.checked!==(i===0))input.click();});const question=document.querySelector('#question');question.value='Missing editor acceptance';question.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#send').click();})()`);
    await until(() => page.evaluate(`document.querySelector('#progress').textContent.includes('部分失败')&&document.querySelector('#progress').textContent.includes('ChatGPT')`), 'honest missing-editor failure feedback');
    record('missing iframe editor produces visible send failure');
    const selected = ids.slice(0, 2);
    await page.evaluate(`(() => {const ids=${JSON.stringify(ids)};document.querySelectorAll('#checks input').forEach((input,i)=>{const expected=${JSON.stringify(selected)}.includes(ids[i]);if(input.checked!==expected)input.click();});localStorage.setItem('${storedKey}',JSON.stringify(${JSON.stringify(selected)}));})()`);
    const remaining = await page.evaluate(`JSON.parse(localStorage.getItem('braintrust.local.selected'))`);
    assert.deepEqual(remaining, selected);
    record('selection stored for restart verification', { selected });
  }
  }
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.stack || error.message;
  if (page) await page.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }).then(result => writeFileSync(join(evidence, 'failure.png'), Buffer.from(result.data, 'base64'))).catch(() => {});
  process.exitCode = 1;
} finally {
  report.finishedAt = new Date().toISOString();
  writeFileSync(join(evidence, `ui-${report.mode}.json`), JSON.stringify(report, null, 2));
  if (args.download && browser) await browser.send('Browser.close').catch(()=>{});
  for (const connection of connections) connection.close();
  if(downloadProcess)downloadProcess.kill();
  console.log(JSON.stringify({ passed: report.passed, mode: report.mode, checks: report.checks.length, error: report.error?.split('\n')[0] }));
}
