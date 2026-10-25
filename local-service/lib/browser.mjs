import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { homedir, platform } from 'node:os';
import { join } from 'node:path';
import { SERVICE_ROOT } from './paths.mjs';

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

export class BrowserManager {
  constructor({ dataDir, browser = 'auto', serviceURL, log = () => {} }) {
    this.dataDir = dataDir;
    this.browserPreference = browser;
    this.serviceURL = serviceURL;
    this.log = log;
    this.port = null;
    this.child = null;
    this.browserPath = null;
  }

  get running() { return Boolean(this.child && this.child.exitCode === null); }

  async ensureRunning() {
    if (this.running && this.port) return this.status();
    this.browserPath = findBrowser(this.browserPreference);
    if (!this.browserPath) throw new Error('未找到可用的 Chromium/Edge/Chrome。请设置 BRAINTRUST_BROWSER_PATH。');
    this.port = await freePort();
    const profile = join(this.dataDir, 'browser-profile');
    mkdirSync(profile, { recursive: true });
    const args = [
      `--user-data-dir=${profile}`, '--profile-directory=Default',
      `--remote-debugging-port=${this.port}`, '--no-first-run', '--no-default-browser-check',
      '--disable-background-networking', '--disable-features=Translate', `--app=${this.serviceURL}`
    ];
    this.child = spawn(this.browserPath, args, { detached: false, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    this.child.stdout?.on('data', data => this.log(String(data).trim()));
    this.child.stderr?.on('data', data => this.log(String(data).trim()));
    this.child.on('exit', (code, signal) => this.log(`浏览器退出 code=${code ?? ''} signal=${signal ?? ''}`));
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      try {
        const response = await fetch(`http://127.0.0.1:${this.port}/json/version`, { signal: AbortSignal.timeout(1000) });
        if (response.ok) return this.status();
      } catch {}
      await sleep(150);
    }
    throw new Error('浏览器启动超时');
  }

  async stop() {
    if (!this.child) return;
    try { this.child.kill(); } catch {}
    this.child = null;
    this.port = null;
  }

  async status() {
    let version = null;
    if (this.port) {
      try { version = await (await fetch(`http://127.0.0.1:${this.port}/json/version`)).json(); } catch {}
    }
    return { running: this.running, port: this.port, path: this.browserPath, version };
  }

  async listTargets() {
    if (!this.port) return [];
    const response = await fetch(`http://127.0.0.1:${this.port}/json/list`);
    if (!response.ok) throw new Error(`无法读取浏览器目标（HTTP ${response.status}）`);
    return await response.json();
  }

  async focusWorkbench() {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const target = targets.find(item => item.type === 'page' && (item.url === this.serviceURL || item.url.startsWith(this.serviceURL)));
    if (target) {
      const response = await fetch(`http://127.0.0.1:${this.port}/json/activate/${target.id}`);
      if (!response.ok) throw new Error(`无法激活工作台（HTTP ${response.status}）`);
      return target;
    }
    const response = await fetch(`http://127.0.0.1:${this.port}/json/new?${encodeURIComponent(this.serviceURL)}`, { method: 'PUT' });
    if (!response.ok) throw new Error(`无法打开工作台（HTTP ${response.status}）`);
    return await response.json();
  }

  async openPlatform(adapter) {
    await this.ensureRunning();
    const url = adapter.origin;
    const response = await fetch(`http://127.0.0.1:${this.port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
    if (!response.ok) throw new Error(`无法打开 ${adapter.name}（HTTP ${response.status}）`);
    return await response.json();
  }

  async send(adapter, text, attachments = []) {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const target = targets.find(item => item.type === 'page' && hostMatches(item.url, adapter));
    if (!target?.webSocketDebuggerUrl) throw new Error(`${adapter.name} 尚未打开，请先打开平台页面`);
    const expression = buildInjection(adapter, text, attachments);
    return await evaluate(target.webSocketDebuggerUrl, expression);
  }

  async probe(adapter) {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const target = targets.find(item => item.type === 'page' && hostMatches(item.url, adapter));
    if (!target?.webSocketDebuggerUrl) return { ok: false, state: 'not-open', url: null };
    const expression = buildProbe(adapter);
    const result = await evaluate(target.webSocketDebuggerUrl, expression);
    if (!result) return { ok: false, state: 'no-response', url: target.url };
    return { ok: true, state: result.challenge ? 'challenge' : result.loggedOut || result.loginModal ? 'login-required' : result.input ? 'ready' : 'input-not-found', url: result.url || target.url, detail: result };
  }
}

function hostMatches(raw, adapter) {
  try {
    const host = new URL(raw).hostname;
    return (adapter.homeHosts || [new URL(adapter.origin).hostname]).some(item => host === item || host.endsWith(`.${item}`));
  } catch { return false; }
}

function buildInjection(adapter, text, attachments = []) {
  const cfg = { ...adapter, text };
  const selectors = JSON.stringify(adapter.input?.selectors || []);
  const send = JSON.stringify(adapter.send || { type: 'enter' });
  const payload = JSON.stringify(text);
  const attachmentPayload = JSON.stringify(attachments.filter(item => item && item.data).slice(0, 10));
  return `(async () => {\n` +
    `const text=${payload}, selectors=${selectors}, send=${send}, attachments=${attachmentPayload};\n` +
    `if(${JSON.stringify(adapter.prepare?.clickSelector || '')}){const p=${JSON.stringify(adapter.prepare?.clickSelector || '')};const q2=s=>{try{return s.startsWith('xpath:')?document.evaluate(s.slice(6),document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue:document.querySelector(s)}catch{return null}};q2(p)?.click();await new Promise(r=>setTimeout(r,${Math.max(0, Number(adapter.prepare?.waitSeconds || 0) * 1000)}));}\n` +
    `const q=s=>{try{return s.startsWith('xpath:')?document.evaluate(s.slice(6),document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue:document.querySelector(s)}catch{return null}};\n` +
    `const el=selectors.map(q).find(Boolean)||document.querySelector('textarea,[contenteditable="true"]');\n` +
    `if(!el)return {ok:false,error:'NO_INPUT'};\n` +
    `const target=el; target.focus();\n` +
    `if(target.matches('textarea,input')){const p=target.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;const d=Object.getOwnPropertyDescriptor(p,'value');if(d?.set)d.set.call(target,text);else target.value=text;target.dispatchEvent(new Event('input',{bubbles:true}));target.dispatchEvent(new Event('change',{bubbles:true}));}\n` +
    `else{const r=document.createRange();r.selectNodeContents(target);const s=getSelection();s.removeAllRanges();s.addRange(r);try{document.execCommand('insertText',false,text)}catch{target.textContent=text}target.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:text}));}\n` +
    `if(attachments.length){const dt=new DataTransfer();for(const a of attachments){try{const bytes=Uint8Array.from(atob(a.data),c=>c.charCodeAt(0));dt.items.add(new File([bytes],a.name||'attachment',{type:a.mime||'application/octet-stream'}));}catch{}}const qs=${JSON.stringify(adapter.attachment?.selectors || [])};const fileInput=qs.map(s=>q(s)).find(x=>x&&x.tagName==='INPUT'&&x.type==='file')||document.querySelector('input[type=file]');if(fileInput&&dt.files.length){fileInput.files=dt.files;fileInput.dispatchEvent(new Event('input',{bubbles:true}));fileInput.dispatchEvent(new Event('change',{bubbles:true}));}}\n` +
    `const chain=send.selectors||[];const b=chain.map(q).find(x=>x&&!x.disabled&&x.getAttribute('aria-disabled')!=='true');\n` +
    `if(send.type==='button'||send.type==='pointer'||send.type==='combo'){if(!b)return {ok:false,error:'NO_SEND_BUTTON'};b.click();if(send.type==='combo')target.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));return {ok:true,sent:send.type};}\n` +
    `if(send.type==='paragraph'){try{document.execCommand('insertParagraph');return {ok:true,sent:'paragraph'}}catch{return {ok:false,error:'PARAGRAPH_NOT_ACCEPTED'}}}\n` +
    `for(const type of ['keydown','keypress','keyup'])target.dispatchEvent(new KeyboardEvent(type,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));return {ok:true,sent:'enter'};})()`;
}

function buildProbe(adapter) {
  return `(() => { const has=s=>(s||[]).some(x=>{try{return x.startsWith('xpath:')?!!document.evaluate(x.slice(6),document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue:!!document.querySelector(x)}catch{return false}}); return {input:has(${JSON.stringify(adapter.input?.selectors || [])}),loggedOut:has(${JSON.stringify(adapter.probe?.loggedOut || [])}),loginModal:has(${JSON.stringify(adapter.probe?.loginModal || [])}),challenge:has(${JSON.stringify(adapter.probe?.challenge || [])}),url:location.href};})()`;
}

async function evaluate(wsURL, expression) {
  if (typeof WebSocket !== 'function') throw new Error('当前 Node 运行时缺少 WebSocket；请使用随包提供的 Node 22+ 运行时');
  const ws = new WebSocket(wsURL);
  let id = 0;
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });
  const result = await new Promise((resolve, reject) => {
    const requestId = ++id;
    const timer = setTimeout(() => reject(new Error('CDP 执行超时')), 15000);
    const onMessage = event => {
      const message = JSON.parse(event.data);
      if (message.id !== requestId) return;
      clearTimeout(timer); ws.removeEventListener('message', onMessage);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result?.result?.value);
    };
    ws.addEventListener('message', onMessage);
    ws.send(JSON.stringify({ id: requestId, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }));
  });
  try { ws.close(); } catch {}
  return result;
}

function findBrowser(preference) {
  if (preference && preference !== 'auto' && existsSync(preference)) return preference;
  if (process.env.BRAINTRUST_BROWSER_PATH && existsSync(process.env.BRAINTRUST_BROWSER_PATH)) return process.env.BRAINTRUST_BROWSER_PATH;
  const bundled = platform() === 'win32'
    ? [join(SERVICE_ROOT, 'runtime', 'chrome-win64', 'chrome.exe')]
    : platform() === 'darwin'
      ? [join(SERVICE_ROOT, 'runtime', 'chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'), join(SERVICE_ROOT, 'runtime', 'chrome-mac-x64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing')]
      : [];
  const system = platform() === 'win32'
    ? [join(process.env.PROGRAMFILES || 'C:\\Program Files', 'Microsoft', 'Edge', 'Application', 'msedge.exe'), join(process.env.LOCALAPPDATA || '', 'Microsoft', 'Edge', 'Application', 'msedge.exe'), join(process.env.PROGRAMFILES || 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe')]
    : platform() === 'darwin'
      ? ['/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
      : ['/usr/bin/microsoft-edge', '/usr/bin/google-chrome', '/usr/bin/chromium'];
  const candidates = [...bundled, ...system];
  return candidates.find(existsSync) || null;
}

async function freePort() {
  const { createServer } = await import('node:net');
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)); });
  });
}
