#!/usr/bin/env node
// One real, unauthenticated ChatGPT connectivity question from an installed CI product.
// No fixture interception, login automation, or automatic resubmission is permitted.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values: args } = parseArgs({ options: {
  'service-info': { type: 'string' }, evidence: { type: 'string' }, 'trusted-control': { type: 'boolean', default: false }
} });
if (!args['service-info'] || !args.evidence) throw new Error('Usage: node windows-guest-send-test.mjs --service-info PATH --evidence DIR');
const evidence = resolve(args.evidence);
mkdirSync(evidence, { recursive: true });
const service = JSON.parse(readFileSync(args['service-info'], 'utf8').replace(/^\uFEFF/, ''));
const base = `http://127.0.0.1:${service.port}`;
const prompt = 'Connectivity test. Please reply only BRAINTRUST_TEST_OK.';
const marker = 'BRAINTRUST_TEST_OK';
const report = {
  mode: 'real-unauthenticated-chatgpt-single-send', startedAt: new Date().toISOString(),
  status: 'unverified', passed: false, sendAttempts: 0, prompt,
  route: args['trusted-control'] ? 'browser-native-CDP-control' : 'installed-product-API',
  limitations: [
    'One guest ChatGPT answer does not validate signed-in accounts, all six platforms, or attachments.',
    'A hosted Windows VM does not validate consumer Windows SmartScreen or a physical device.'
  ]
};
const clients = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
class CDP {
  constructor(socket) { this.socket = socket; this.next = 0; this.pending = new Map(); this.events = new Map(); }
  static async open(url) {
    const client = new CDP(new WebSocket(url));
    clients.push(client);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP connection timeout')), 10000);
      client.socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      client.socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('CDP connection failed')); }, { once: true });
    });
    client.socket.addEventListener('message', event => {
      const data = JSON.parse(event.data);
      const entry = client.pending.get(data.id);
      if (!entry) {
        for (const callback of client.events.get(data.method) || []) {
          try { callback(data.params); } catch {}
        }
        return;
      }
      client.pending.delete(data.id); clearTimeout(entry.timer);
      if (data.error) entry.reject(new Error(`${entry.method}: ${data.error.message}`));
      else entry.resolve(data.result);
    });
    client.socket.addEventListener('close', () => {
      for (const entry of client.pending.values()) { clearTimeout(entry.timer); entry.reject(new Error('CDP connection closed')); }
      client.pending.clear();
    });
    return client;
  }
  on(method, callback) { this.events.set(method, [...(this.events.get(method) || []), callback]); }
  send(method, params = {}) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timeout`)); }, 15000);
      this.pending.set(id, { resolve, reject, timer, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const data = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (data.exceptionDetails) throw new Error(data.exceptionDetails.exception?.description || data.exceptionDetails.text);
    return data.result?.value;
  }
  close() { this.socket.close(); }
}
const sanitizedURL = raw => {
  try { const url = new URL(raw); return { hostname: url.hostname, pathname: url.pathname.slice(0, 350) }; }
  catch { return { hostname: null, pathname: null }; }
};
const sanitizedLog = raw => {
  const text = String(raw || '').replace(/https?:\/\/[^\s)"']+/g, value => { const url = sanitizedURL(value); return url.hostname ? `${url.hostname}${url.pathname}` : '[URL redacted]'; });
  if (/authorization|bearer|cookie|token|session|api.?key|secret|password|credential|jwt/i.test(text)) return '[potentially sensitive log redacted]';
  return text.replace(/[A-Za-z0-9_-]{40,}/g, '[long value redacted]').slice(0, 300);
};
const instrumented = new WeakSet();
let trackNetwork = false;
async function instrument(client) {
  if (instrumented.has(client)) return;
  instrumented.add(client);
  report.network ||= { requests: [], responses: [], failures: [] };
  report.pageErrors ||= [];
  report.logs ||= [];
  const requests = new Map();
  const append = (items, item) => { if (items.length < 600 || String(item.pathname || '').includes('conversation')) items.push(item); };
  client.on('Network.requestWillBeSent', params => {
    const item = { ...sanitizedURL(params.request?.url), type: params.type, at: new Date().toISOString() };
    requests.set(params.requestId, item);
    if (['Document', 'Fetch', 'XHR', 'EventSource', 'Other'].includes(params.type)) append(report.network.requests, item);
  });
  client.on('Network.responseReceived', params => append(report.network.responses, {
    ...sanitizedURL(params.response?.url), status: params.response?.status, type: params.type, at: new Date().toISOString()
  }));
  client.on('Network.loadingFailed', params => append(report.network.failures, {
    ...(requests.get(params.requestId) || { hostname: null, pathname: null }), type: params.type,
    errorText: sanitizedLog(params.errorText), blockedReason: params.blockedReason || null, canceled: Boolean(params.canceled)
  }));
  client.on('Runtime.exceptionThrown', params => append(report.pageErrors, {
    text: sanitizedLog(params.exceptionDetails?.exception?.description || params.exceptionDetails?.text), at: new Date().toISOString()
  }));
  client.on('Log.entryAdded', params => append(report.logs, {
    source: params.entry?.source, level: params.entry?.level, text: sanitizedLog(params.entry?.text), ...sanitizedURL(params.entry?.url), at: new Date().toISOString()
  }));
  client.on('Runtime.consoleAPICalled', params => {
    const values = (params.args || []).filter(value => value.type === 'string').map(value => sanitizedLog(value.value));
    if (values.length) append(report.logs, { source: 'console', level: params.type, text: values.join(' ').slice(0, 300), at: new Date().toISOString() });
  });
  const result = await Promise.allSettled([client.send('Network.enable'), client.send('Runtime.enable'), client.send('Log.enable')]);
  report.instrumentationErrors ||= [];
  for (const item of result) if (item.status === 'rejected') report.instrumentationErrors.push(sanitizedLog(item.reason?.message));
}
async function api(path, body) {
  const response = await fetch(base + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${service.token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20000)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(`${path} HTTP ${response.status}: ${result.error || ''}`);
  return result;
}
const snapshotExpression = `(() => {
  const visible = el => {const r=el.getBoundingClientRect();return r.width>0&&r.height>0;};
  const text=(document.body?.innerText||'');
  const roles=[...document.querySelectorAll('[data-message-author-role]')].map(el=>({role:el.getAttribute('data-message-author-role'),text:(el.innerText||'').trim().slice(0,1600)}));
  const actions=[...document.querySelectorAll('button,a')].filter(visible).map(el=>(el.innerText||el.getAttribute('aria-label')||'').trim());
  const loginActions=actions.filter(value=>/^(log in|sign in|sign up|登录|注册)(?:\\s|$)/i.test(value));
  const accountMenu=[...document.querySelectorAll('[data-testid="profile-button"],[data-testid="accounts-profile-button"],[data-testid="user-menu-button"]')].some(visible);
  const inputs=[...document.querySelectorAll('textarea,[contenteditable="true"]')].slice(0,8).map(el=>({tag:el.tagName,id:el.id,contenteditable:el.getAttribute('contenteditable'),visible:visible(el),disabled:Boolean(el.disabled),readOnly:Boolean(el.readOnly),text:String(el.value??el.innerText??'').slice(0,220)}));
  const input=inputs.some(el=>el.visible&&!el.disabled&&!el.readOnly);
  const sendButtons=[...document.querySelectorAll('button[aria-label="Send message"],button.wm-compose,button[data-testid="send-button"],button[data-testid="composer-submit-button"]')].slice(0,6).map(el=>({tag:el.tagName,id:el.id,testid:el.getAttribute('data-testid'),ariaLabel:el.getAttribute('aria-label'),ariaDisabled:el.getAttribute('aria-disabled'),type:el.getAttribute('type'),visible:visible(el),disabled:Boolean(el.disabled),outerHTML:el.outerHTML.slice(0,1600)}));
  const challenge=/just a moment|verify you are human|confirm you are human|checking your browser|确认您是人类|验证您是真人/i.test(text.slice(0,5000));
  const rateLimit=/too many requests|rate limit|usage limit|reached.*limit|达到.*上限|请求过于频繁/i.test(text.slice(-5000));
  return {hostname:location.hostname,title:document.title,readyState:document.readyState,input,inputs,sendButtons,domElementCount:document.querySelectorAll('*').length,loginActions,accountMenu,challenge,rateLimit,fixture:Boolean(window.__fixture),roles,bodyTail:text.slice(-1800)};
})()`;
let frame, workbench;
try {
  if (process.platform !== 'win32' || process.env.CI !== 'true') throw new Error('Run only on the clean Windows CI installation prepared for this acceptance test');
  const health = await api('/api/health');
  report.version = health.version;
  report.browser = health.browser?.version?.Browser;
  if (!health.browser?.running || !health.browser.port) throw new Error('Installed browser is not running');
  const targets = () => fetch(`http://127.0.0.1:${health.browser.port}/json/list`, { signal: AbortSignal.timeout(5000) }).then(response => response.json());
  const getFrame = async () => {
    if (frame?.socket.readyState === WebSocket.OPEN) { if (trackNetwork) await instrument(frame); return frame; }
    const target = (await targets()).find(item => item.type === 'iframe' && (() => {try{return new URL(item.url).hostname === 'chatgpt.com';}catch{return false;}})());
    if (!target?.webSocketDebuggerUrl) return null;
    frame = await CDP.open(target.webSocketDebuggerUrl);
    report.frameConnections = (report.frameConnections || 0) + 1;
    if (trackNetwork) await instrument(frame);
    return frame;
  };
  const workbenchTarget = (await targets()).find(item => item.type === 'page' && item.url.startsWith(base + '/'));
  if (workbenchTarget) workbench = await CDP.open(workbenchTarget.webSocketDebuggerUrl);
  const deadline = Date.now() + 60000;
  let ready = false;
  let stableSignature = null;
  let stableSince = 0;
  while (Date.now() < deadline) {
    let before;
    try {
      const current = await getFrame();
      if (current) before = await current.evaluate(snapshotExpression);
    } catch (error) {
      report.lastReadinessObservationError = error.message;
      try { frame?.close(); } catch {}
      frame = null;
    }
    if (before) {
      report.before = before;
      if (before.fixture) { report.status = 'blocked'; report.reason = 'Fixture document detected; refusing to treat it as a real platform'; break; }
      if (before.challenge || before.rateLimit) { report.status = 'blocked'; report.reason = before.challenge ? 'Human verification required; no bypass attempted' : 'Platform rate or usage limit'; break; }
      if (before.roles.length || before.accountMenu) {
        before.roles = before.roles.map(item => ({ role: item.role, text: '[existing content redacted]' }));
        before.inputs = before.inputs.map(item => ({ ...item, text: '[existing content redacted]' }));
        before.bodyTail = '[existing account or conversation content redacted]';
        report.status = 'blocked'; report.reason = 'Existing conversation or account UI; refusing to use non-clean guest state'; break;
      }
      if (before.readyState === 'complete' && before.input && before.loginActions.length) {
        const signature = JSON.stringify({ inputs: before.inputs, sendButtons: before.sendButtons, loginActions: before.loginActions, domElementCount: before.domElementCount });
        if (signature !== stableSignature) { stableSignature = signature; stableSince = Date.now(); }
        else if (Date.now() - stableSince >= 950) {
          const probe = await api('/api/platforms/chatgpt/probe');
          report.probe = { state: probe.state, ok: probe.ok };
          report.readiness = { documentComplete: true, stableObservations: 2, stableForMs: Date.now() - stableSince };
          if (probe.state === 'ready') { ready = true; break; }
        }
      } else {
        stableSignature = null; stableSince = 0;
      }
    }
    await delay(1000);
  }
  if (!ready) {
    report.status = report.status === 'blocked' ? 'blocked' : 'unverified';
    report.reason ||= 'Clean guest input did not become ready within 60 seconds; no message sent';
  } else {
    trackNetwork = true;
    await instrument(frame);
    report.sendAttempts = 1;
    report.sendStartedAt = new Date().toISOString();
    try {
      if (args['trusted-control']) {
        report.trustedFocus = await frame.evaluate(`(() => {
          const visible=el=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0&&!el.disabled&&!el.readOnly;};
          const selectors=['div#prompt-textarea','textarea#prompt-textarea','[contenteditable="true"]','textarea'];
          const input=selectors.flatMap(selector=>[...document.querySelectorAll(selector)]).find(visible);
          if(!input)return {focused:false};input.focus();return {focused:document.activeElement===input,tag:input.tagName,id:input.id};
        })()`);
        if (!report.trustedFocus?.focused) throw new Error('Trusted control could not focus the existing visible input');
        await frame.send('Input.insertText', { text: prompt });
        report.afterTrustedInsertion = await frame.evaluate(snapshotExpression);
        const buttonDeadline = Date.now() + 10000;
        while (Date.now() < buttonDeadline) {
          report.trustedSubmitFocus = await frame.evaluate(`(() => {
            const button=[...document.querySelectorAll('button[aria-label="Send message"]')].find(el=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0&&!el.disabled&&el.getAttribute('aria-disabled')!=='true';});
            if(!button)return {focused:false};button.focus();return {focused:document.activeElement===button,tag:button.tagName,id:button.id,ariaLabel:button.getAttribute('aria-label')};
          })()`);
          if (report.trustedSubmitFocus?.focused) break;
          await delay(150);
        }
        if (!report.trustedSubmitFocus?.focused) throw new Error('Trusted control did not find a visible enabled Send message button');
        report.beforeTrustedSubmit = await frame.evaluate(snapshotExpression);
        if (!report.beforeTrustedSubmit.inputs.some(item => item.visible && item.text.includes(prompt))) throw new Error('Trusted control input did not retain the test question; no submit attempted');
        // Submit the observed send button with a native key, not Enter in a mobile textarea.
        await frame.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r' });
        await frame.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
        report.sendResult = { commandsCompleted: true, route: 'browser-native-CDP-control' };
      } else {
        const sent = await api('/api/send', { text: prompt, platforms: ['chatgpt'], attachments: [] });
        report.sendResult = { ok: sent.ok, results: sent.results?.map(item => ({ id: item.id, ok: item.ok, error: item.error || null, result: item.result })) };
      }
    } catch (error) { report.sendError = error.message; }
    try { report.afterSend = await frame.evaluate(snapshotExpression); }
    catch (error) { report.afterSendObservationError = error.message; }
    const responseDeadline = Date.now() + 60000;
    while (Date.now() < responseDeadline) {
      let after;
      try {
        const current = await getFrame();
        if (current) after = await current.evaluate(snapshotExpression);
      } catch (error) {
        // A real guest submission can replace its iframe execution context.
        // Reconnect for observation only; the one submitted prompt is never retried.
        report.lastResponseObservationError = error.message;
        try { frame?.close(); } catch {}
        frame = null;
      }
      if (!after) { await delay(1000); continue; }
      if (after.fixture || after.accountMenu) {
        after.roles = after.roles.map(item => ({ role: item.role, text: '[unexpected context redacted]' }));
        after.inputs = after.inputs.map(item => ({ ...item, text: '[unexpected context redacted]' }));
        after.bodyTail = '[unexpected account or fixture context redacted]';
        report.after = after; report.status = 'blocked'; report.reason = 'Unexpected account or fixture context after submission; observation stopped'; break;
      }
      report.after = after;
      const assistants = after.roles.filter(item => item.role === 'assistant');
      if (assistants.length && assistants[assistants.length - 1].text.includes(marker)) {
        report.status = 'passed'; report.passed = true;
        report.responseEvidence = { role: 'assistant', newAssistantCount: assistants.length, text: assistants[assistants.length - 1].text };
        break;
      }
      if (after.challenge || after.rateLimit) { report.status = 'blocked'; report.reason = 'Platform verification or rate limit appeared after the single send'; break; }
      await delay(1000);
    }
    if (!report.passed && report.status !== 'blocked') { report.status = 'unverified'; report.reason = 'No new assistant-role response containing the marker within 60 seconds; no resubmission attempted'; }
  }
} catch (error) {
  report.status = 'unverified'; report.error = error.stack || error.message;
} finally {
  if (workbench) {
    try {
      const screenshot = await workbench.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
      writeFileSync(join(evidence, 'real-guest-workbench.png'), Buffer.from(screenshot.data, 'base64'));
    } catch (error) { report.screenshotError = error.message; }
  }
  report.finishedAt = new Date().toISOString();
  writeFileSync(join(evidence, 'real-guest-send.json'), JSON.stringify(report, null, 2) + '\n');
  for (const client of clients) client.close();
  console.log(JSON.stringify({ status: report.status, passed: report.passed, sendAttempts: report.sendAttempts, reason: report.reason || report.error?.split('\n')[0] || null }));
  process.exitCode = report.passed ? 0 : 2;
}
