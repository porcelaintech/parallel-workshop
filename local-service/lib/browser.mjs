import { existsSync, mkdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { platform } from 'node:os';
import { join } from 'node:path';
import { SERVICE_ROOT } from './paths.mjs';
import { FrameBridge } from './frame-bridge.mjs';

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
    this.frameBridge = null;
    this.starting = null;
    this.preparing = null;
  }

  get running() { return Boolean(this.child && this.child.exitCode === null); }

  async ensureRunning() {
    if (this.starting) return this.starting;
    if (this.running && this.port) return this.status();
    this.starting = this.startBrowser();
    try { return await this.starting; }
    finally { this.starting = null; }
  }

  async startBrowser() {
    await this.frameBridge?.stop();
    this.frameBridge = null;
    this.browserPath = findBrowser(this.browserPreference);
    if (!this.browserPath) throw new Error('未找到可用的 Chromium/Edge/Chrome。请设置 BRAINTRUST_BROWSER_PATH。');
    const port = await freePort();
    this.port = port;
    const profile = join(this.dataDir, 'browser-profile');
    mkdirSync(profile, { recursive: true });
    const headless = process.env.BRAINTRUST_BROWSER_HEADLESS === '1' ? ['--headless=new', '--disable-gpu', '--no-sandbox'] : [];
    const args = [
      ...headless,
      `--user-data-dir=${profile}`, '--profile-directory=Default',
      `--remote-debugging-port=${port}`, '--no-first-run', '--no-default-browser-check',
      '--disable-background-networking', '--disable-features=Translate', `--app=${this.serviceURL}`
    ];
    const child = spawn(this.browserPath, args, { detached: false, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    this.child = child;
    let launchError = null;
    child.on('error', error => { launchError = error; });
    child.stdout?.on('data', data => this.log(String(data).trim()));
    child.stderr?.on('data', data => this.log(String(data).trim()));
    child.on('exit', (code, signal) => {
      this.log(`浏览器退出 code=${code ?? ''} signal=${signal ?? ''}`);
      if (this.child === child) {
        this.child = null;
        this.port = null;
        const bridge = this.frameBridge;
        this.frameBridge = null;
        bridge?.stop().catch(() => {});
      }
    });
    try {
      const deadline = Date.now() + 20000;
      while (Date.now() < deadline) {
        if (launchError) throw launchError;
        if (child.exitCode !== null || child.signalCode !== null) throw new Error('浏览器在启动完成前退出');
        try {
          const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1000) });
          if (response.ok) return this.status();
        } catch {}
        await sleep(150);
      }
      throw new Error('浏览器启动超时');
    } catch (error) {
      try { child.kill(); } catch {}
      if (this.child === child) { this.child = null; this.port = null; }
      throw error;
    }
  }

  async stop() {
    if (this.starting) await this.starting.catch(() => {});
    try { await this.frameBridge?.stop(); } catch {}
    this.frameBridge = null;
    const child = this.child;
    const port = this.port;
    if (!child) return;
    // Let Chromium flush its profile before falling back to terminating the process.
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1000) });
      const version = await response.json();
      if (version.webSocketDebuggerUrl) await cdpCommand(version.webSocketDebuggerUrl, 'Browser.close', {}, 2000);
    } catch {}
    const deadline = Date.now() + 3000;
    while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) await sleep(50);
    if (child.exitCode === null && child.signalCode === null) {
      try { child.kill(); } catch {}
      const killDeadline = Date.now() + 2000;
      while (child.exitCode === null && child.signalCode === null && Date.now() < killDeadline) await sleep(50);
    }
    if (this.child === child) { this.child = null; this.port = null; }
  }

  async prepareWorkbench() {
    await this.ensureRunning();
    if (this.preparing) return this.preparing;
    this.preparing = (async () => {
      if (!this.frameBridge) this.frameBridge = new FrameBridge({ browserPort: this.port, pageURL: this.serviceURL, log: this.log });
      await this.frameBridge.start();
      return { ok: true, browserPort: this.port };
    })();
    try { return await this.preparing; }
    finally { this.preparing = null; }
  }

  async status() {
    let version = null;
    if (this.port) {
      try { version = await (await fetch(`http://127.0.0.1:${this.port}/json/version`, { signal: AbortSignal.timeout(1500) })).json(); } catch {}
    }
    return { running: this.running, port: this.port, path: this.browserPath, version };
  }

  async listTargets() {
    if (!this.port) return [];
    const response = await fetch(`http://127.0.0.1:${this.port}/json/list`, { signal: AbortSignal.timeout(3000) });
    if (!response.ok) throw new Error(`无法读取浏览器目标（HTTP ${response.status}）`);
    return await response.json();
  }

  async focusWorkbench() {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const target = targets.find(item => item.type === 'page' && (item.url === this.serviceURL || item.url.startsWith(this.serviceURL)));
    if (target) {
      const response = await fetch(`http://127.0.0.1:${this.port}/json/activate/${target.id}`, { signal: AbortSignal.timeout(3000) });
      if (!response.ok) throw new Error(`无法激活工作台（HTTP ${response.status}）`);
      return target;
    }
    const response = await fetch(`http://127.0.0.1:${this.port}/json/new?${encodeURIComponent(this.serviceURL)}`, { method: 'PUT', signal: AbortSignal.timeout(3000) });
    if (!response.ok) throw new Error(`无法打开工作台（HTTP ${response.status}）`);
    return await response.json();
  }

  async openPlatform(adapter) {
    await this.ensureRunning();
    const url = adapter.origin;
    const response = await fetch(`http://127.0.0.1:${this.port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT', signal: AbortSignal.timeout(3000) });
    if (!response.ok) throw new Error(`无法打开 ${adapter.name}（HTTP ${response.status}）`);
    return await response.json();
  }

  async send(adapter, text, attachments = []) {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const matches = targets.filter(item => (item.type === 'page' || item.type === 'iframe') && hostMatches(item.url, adapter));
    const target = matches.find(item => item.type === 'iframe') || matches[0];
    if (!target?.webSocketDebuggerUrl) throw new Error(`${adapter.name} 尚未打开，请先打开平台页面`);
    const expression = buildInjection(adapter, text, attachments);
    return await evaluate(target.webSocketDebuggerUrl, expression);
  }

  async probe(adapter) {
    await this.ensureRunning();
    const targets = await this.listTargets();
    const matches = targets.filter(item => (item.type === 'page' || item.type === 'iframe') && hostMatches(item.url, adapter));
    const target = matches.find(item => item.type === 'iframe') || matches[0];
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
  // Serialize one self-contained page function; no browser extension API is required.
  return `(${injectIntoPage.toString()})(${JSON.stringify({ ...adapter, text, attachments: attachments.slice(0, 10) })})`;
}

async function injectIntoPage(cfg) {
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const query = selector => {
    try { return selector.startsWith('xpath:') ? document.evaluate(selector.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue : document.querySelector(selector); }
    catch { return null; }
  };
  const visible = el => Boolean(el && el.getClientRects?.().length && getComputedStyle(el).visibility !== 'hidden');
  const first = (selectors, predicate = visible) => (selectors || []).map(query).find(predicate);
  if (cfg.prepare?.clickSelector) {
    query(cfg.prepare.clickSelector)?.click();
    await sleep(Math.min(5000, Math.max(0, Number(cfg.prepare.waitSeconds || 0) * 1000)));
  }
  let target = first(cfg.input?.selectors) || [...document.querySelectorAll('textarea,[contenteditable="true"]')].find(visible);
  if (target && !target.matches('textarea,input,[contenteditable="true"]')) target = target.querySelector('textarea,input,[contenteditable="true"]');
  if (!target) return { ok: false, error: 'NO_INPUT' };
  target.focus();
  await sleep(120);
  if (target.matches('textarea,input')) {
    const proto = target.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
    if (setter) setter.call(target, cfg.text); else target.value = cfg.text;
    target.dispatchEvent(new Event('input', { bubbles: true }));
    target.dispatchEvent(new Event('change', { bubbles: true }));
  } else {
    const range = document.createRange();
    range.selectNodeContents(target);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    if (!document.execCommand('insertText', false, cfg.text)) target.textContent = cfg.text;
    target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: cfg.text }));
  }
  await sleep(150);

  const attachments = cfg.attachments || [];
  if (attachments.length) {
    const data = new DataTransfer();
    for (const attachment of attachments) {
      try {
        if (!attachment?.data) return { ok: false, error: 'INVALID_ATTACHMENT' };
        const bytes = Uint8Array.from(atob(attachment.data), char => char.charCodeAt(0));
        data.items.add(new File([bytes], attachment.name || 'attachment', { type: attachment.mime || 'application/octet-stream' }));
      } catch { return { ok: false, error: 'INVALID_ATTACHMENT' }; }
    }
    const opener = first(cfg.attachment?.openSelectors);
    if (opener) { opener.click(); await sleep(600); }
    const fileInput = first(cfg.attachment?.selectors, el => el?.matches('input[type="file"]')) || document.querySelector('input[type="file"]');
    if (!fileInput) return { ok: false, error: 'ATTACHMENT_REQUIRES_MANUAL_UPLOAD' };
    fileInput.files = data.files;
    fileInput.dispatchEvent(new Event('input', { bubbles: true }));
    fileInput.dispatchEvent(new Event('change', { bubbles: true }));
    if (fileInput.files.length !== attachments.length) return { ok: false, error: 'ATTACHMENT_NOT_ACCEPTED' };
    await sleep(150);
  }

  const send = cfg.send || { type: 'enter' };
  if (['button', 'pointer', 'combo'].includes(send.type)) {
    const enabled = el => visible(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
    let button;
    const deadline = Date.now() + 2000;
    do {
      button = first(send.selectors, enabled);
      if (button) break;
      await sleep(50);
    } while (Date.now() < deadline);
    if (!button) return { ok: false, error: 'NO_SEND_BUTTON' };
    if (send.type === 'pointer') {
      const rect = button.getBoundingClientRect();
      const init = { bubbles: true, cancelable: true, clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2, button: 0 };
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) button.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : MouseEvent)(type, init));
    } else button.click();
    if (send.type === 'combo') target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    return { ok: true, sent: send.type, attachmentsInjected: attachments.length };
  }
  if (send.type === 'paragraph') return document.execCommand('insertParagraph') ? { ok: true, sent: 'paragraph' } : { ok: false, error: 'PARAGRAPH_NOT_ACCEPTED' };
  for (const type of ['keydown', 'keypress', 'keyup']) target.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
  return { ok: true, sent: 'enter', attachmentsInjected: attachments.length };
}

function buildProbe(adapter) {
  return `(() => { const has=s=>(s||[]).some(x=>{try{return x.startsWith('xpath:')?!!document.evaluate(x.slice(6),document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue:!!document.querySelector(x)}catch{return false}}); return {input:has(${JSON.stringify(adapter.input?.selectors || [])}),loggedOut:has(${JSON.stringify(adapter.probe?.loggedOut || [])}),loginModal:has(${JSON.stringify(adapter.probe?.loginModal || [])}),challenge:has(${JSON.stringify(adapter.probe?.challenge || [])}),url:location.href};})()`;
}

async function cdpCommand(wsURL, method, params, timeout = 15000) {
  if (typeof WebSocket !== 'function') throw new Error('当前 Node 运行时缺少 WebSocket；请使用随包提供的 Node 22+ 运行时');
  const ws = new WebSocket(wsURL);
  try {
    await new Promise((resolve, reject) => {
      const finish = (error) => { clearTimeout(timer); ws.removeEventListener('open', onOpen); ws.removeEventListener('error', onError); error ? reject(error) : resolve(); };
      const onOpen = () => finish();
      const onError = () => finish(new Error('CDP 连接失败'));
      const timer = setTimeout(() => finish(new Error('CDP 连接超时')), Math.min(timeout, 5000));
      ws.addEventListener('open', onOpen, { once: true });
      ws.addEventListener('error', onError, { once: true });
    });
    return await new Promise((resolve, reject) => {
      const finish = (error, value) => {
        clearTimeout(timer);
        ws.removeEventListener('message', onMessage);
        ws.removeEventListener('close', onClose);
        ws.removeEventListener('error', onError);
        error ? reject(error) : resolve(value);
      };
      const onClose = () => finish(new Error('CDP 连接已关闭'));
      const onError = () => finish(new Error('CDP 连接失败'));
      const onMessage = event => {
        let message;
        try { message = JSON.parse(event.data); } catch { return; }
        if (message.id !== 1) return;
        if (message.error) finish(new Error(message.error.message));
        else finish(null, message.result);
      };
      const timer = setTimeout(() => finish(new Error('CDP 执行超时')), timeout);
      ws.addEventListener('message', onMessage);
      ws.addEventListener('close', onClose, { once: true });
      ws.addEventListener('error', onError, { once: true });
      ws.send(JSON.stringify({ id: 1, method, params }));
    });
  } finally {
    try { ws.close(); } catch {}
  }
}

async function evaluate(wsURL, expression) {
  const result = await cdpCommand(wsURL, 'Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text || '页面注入执行失败');
  return result.result?.value;
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
    ? [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, process.env.PROGRAMFILES, process.env.LOCALAPPDATA].filter(Boolean).flatMap(root => [join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'), join(root, 'Google', 'Chrome', 'Application', 'chrome.exe')])
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
