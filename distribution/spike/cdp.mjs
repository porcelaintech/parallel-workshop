import { spawn } from 'node:child_process';
import { rmSync } from 'node:fs';

const mode = process.argv[2] || 'plain';
const pageURL = process.argv[3] || 'http://127.0.0.1:48081/parent.html';
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9333;
const profile = new URL(`./.profile-${mode}`, import.meta.url).pathname;
rmSync(profile, { recursive: true, force: true });
const child = spawn(chrome, [
  '--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, 'about:blank'
], { stdio: ['ignore', 'ignore', 'ignore'] });

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
for (let i = 0; i < 100; i++) {
  try { const r = await fetch(`http://127.0.0.1:${port}/json/version`); if (r.ok) break; } catch {}
  await sleep(100);
}

const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });

let nextId = 0;
const pending = new Map();
const sessions = new Map();
const events = [];
const send = (method, params = {}, sessionId = '') => new Promise((resolve, reject) => {
  const id = ++nextId;
  const key = `${sessionId}:${id}`;
  pending.set(key, { resolve, reject, method });
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});
ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id) {
    const key = `${message.sessionId || ''}:${message.id}`;
    const entry = pending.get(key);
    if (!entry) return;
    pending.delete(key);
    if (message.error) entry.reject(new Error(`${entry.method}: ${message.error.message}`));
    else entry.resolve(message.result);
    return;
  }
  if (message.method === 'Target.attachedToTarget') {
    const { sessionId, targetInfo } = message.params;
    sessions.set(sessionId, targetInfo);
    events.push({ event: 'attached', sessionId, type: targetInfo.type, url: targetInfo.url });
    if (mode === 'strip' && targetInfo.type === 'iframe') {
      send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Response' }] }, sessionId).catch(() => {});
      send('Runtime.enable', {}, sessionId).catch(() => {});
    }
    return;
  }
  if (message.method === 'Fetch.requestPaused') {
    const { requestId, request, responseStatusCode, responseHeaders, responseErrorReason } = message.params;
    const headers = responseHeaders || [];
    const xfo = headers.find(h => h.name.toLowerCase() === 'x-frame-options')?.value;
    const csp = headers.find(h => h.name.toLowerCase() === 'content-security-policy')?.value;
    events.push({ event: 'paused', session: message.sessionId || 'parent', url: request?.url, status: responseStatusCode, xfo, csp: csp?.slice(0, 80), error: responseErrorReason });
    if (mode === 'strip' && responseStatusCode && headers.length) {
      const filtered = headers.filter(h => !['x-frame-options', 'content-security-policy'].includes(h.name.toLowerCase()));
      if (xfo || csp) {
        send('Fetch.getResponseBody', { requestId }, message.sessionId || '').then(async (body) => {
          await send('Fetch.fulfillRequest', {
            requestId,
            responseCode: responseStatusCode,
            responseHeaders: filtered,
            body: body.base64Encoded ? body.body : Buffer.from(body.body || '', 'utf8').toString('base64')
          }, message.sessionId || '');
          events.push({ event: 'fulfilled', url: request?.url, bytes: body.body?.length || 0 });
        }).catch((error) => {
          events.push({ event: 'fulfill-error', message: error.message, url: request?.url });
          send('Fetch.continueRequest', { requestId }, message.sessionId || '').catch(() => {});
        });
      } else {
        send('Fetch.continueResponse', { requestId, responseCode: responseStatusCode, responseHeaders: filtered }, message.sessionId || '').catch((error) => {
          events.push({ event: 'continueResponse-error', message: error.message, url: request?.url });
          send('Fetch.continueRequest', { requestId }, message.sessionId || '').catch(() => {});
        });
      }
    } else {
      send('Fetch.continueRequest', { requestId }, message.sessionId || '').catch(() => {});
    }
    return;
  }
  if (message.method === 'Network.loadingFailed') {
    events.push({ event: 'loadingFailed', type: message.params.type, error: message.params.errorText });
  }
  if (message.method === 'Network.responseReceived' && message.params.type === 'SubFrame') {
    events.push({ event: 'subFrame', url: message.params.response?.url, status: message.params.response?.status });
  }
});

await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');
await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
if (mode === 'strip') {
  await send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Response' }] }).catch((error) => events.push({ event: 'fetch-enable-error', message: error.message }));
}
await send('Page.navigate', { url: pageURL });
await sleep(9000);

const tree = await send('Page.getFrameTree');
const flatten = (node, depth = 0) => [{ depth, id: node.frame.id, url: node.frame.url, name: node.frame.name }, ...(node.childFrames || []).flatMap(c => flatten(c, depth + 1))];
const frames = flatten(tree.frameTree);
const evaluations = [];
for (const [sessionId, info] of sessions) {
  if (info.type !== 'iframe') continue;
  try {
    const result = await send('Runtime.evaluate', { expression: `({href:location.href,title:document.title,ta:!!document.querySelector('textarea'),ce:!!document.querySelector('[contenteditable=\"true\"]'),text:(document.body?.innerText||'').slice(0,240)})`, returnByValue: true }, sessionId);
    evaluations.push({ sessionId, type: info.type, url: info.url, value: result.result?.value });
  } catch (error) {
    evaluations.push({ sessionId, type: info.type, url: info.url, error: error.message });
  }
}
console.log(JSON.stringify({ mode, frames, sessions: [...sessions.values()].map(s => ({ type: s.type, url: s.url, title: s.title })), evaluations, events: events.slice(0, 40) }, null, 2));
try { ws.close(); } catch {}
try { await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`); } catch {}
child.kill('SIGTERM');
await sleep(500);
process.exit(0);
