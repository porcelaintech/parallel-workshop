#!/usr/bin/env node
import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join, extname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { parseArgs } from 'node:util';
import { adaptersDir, defaultConfigDir, defaultDataDir, SERVICE_ROOT, sourceAdaptersDir } from './lib/paths.mjs';
import { acquireLock } from './lib/lock.mjs';
import { BrowserManager } from './lib/browser.mjs';
import { checkUpdate, downloadUpdate, selectArtifact } from './lib/update.mjs';

const args = parseArgs({ options: {
  host: { type: 'string', default: '127.0.0.1' },
  port: { type: 'string', default: '0' },
  'data-dir': { type: 'string' },
  browser: { type: 'string', default: process.env.BRAINTRUST_BROWSER_PATH || 'auto' },
  'no-browser': { type: 'boolean', default: false },
  'update-url': { type: 'string' },
  'print-ready': { type: 'boolean', default: false }
}, allowPositionals: true }).values;

const dataDir = args['data-dir'] || process.env.BRAINTRUST_DATA_DIR || defaultDataDir();
const configDir = defaultConfigDir();
mkdirSync(dataDir, { recursive: true });
mkdirSync(configDir, { recursive: true });
const lockRelease = acquireLock(join(dataDir, 'service.lock'));
const serviceInfoPath = join(dataDir, 'service.json');
const config = loadConfig(configDir);
const version = config.version || '0.6.0';
const token = randomBytes(24).toString('hex');
const events = new Set();
const logs = [];
const adapters = loadAdapters();
const browser = new BrowserManager({
  dataDir,
  browser: args.browser || config.browser || 'auto',
  serviceURL: `http://${args.host}:${args.port === '0' ? 0 : args.port}/`,
  log: message => emit('log', { message })
});

let server;

function log(message) {
  const entry = { at: new Date().toISOString(), message: String(message) };
  logs.push(entry);
  if (logs.length > 100) logs.shift();
  emit('log', entry);
  console.error(`[braintrust] ${entry.message}`);
}

function emit(type, payload) {
  const line = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  for (const response of events) response.write(line);
}

function loadConfig(dir) {
  const defaults = JSON.parse(readFileSync(join(SERVICE_ROOT, 'config', 'default.json'), 'utf8'));
  const userPath = join(dir, 'config.json');
  if (!existsSync(userPath)) return defaults;
  try { return { ...defaults, ...JSON.parse(readFileSync(userPath, 'utf8')) }; } catch { return defaults; }
}

function loadAdapters() {
  const result = [];
  const root = existsSync(adaptersDir()) ? adaptersDir() : sourceAdaptersDir();
  if (!existsSync(root)) return result;
  for (const name of ['chatgpt', 'deepseek', 'doubao', 'kimi', 'tongyi', 'yiyan']) {
    const path = join(root, `${name}.json`);
    if (existsSync(path)) result.push(JSON.parse(readFileSync(path, 'utf8')));
  }
  return result;
}

function authorized(request) {
  const header = request.headers.authorization || '';
  return header === `Bearer ${token}`;
}

function sendJSON(response, status, body) {
  const data = JSON.stringify(body);
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'content-length': Buffer.byteLength(data) });
  response.end(data);
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function staticFile(pathname) {
  const relative = pathname === '/' ? 'index.html' : pathname.slice(1);
  const root = join(SERVICE_ROOT, 'public');
  const full = join(root, relative);
  const separator = process.platform === 'win32' ? '\\' : '/';
  if (!full.startsWith(`${root}${separator}`) && full !== root) return null;
  if (!existsSync(full)) return null;
  return full;
}

function contentType(path) {
  return ({ '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml' })[extname(path)] || 'application/octet-stream';
}

async function handler(request, response) {
  const url = new URL(request.url || '/', `http://${request.headers.host || '127.0.0.1'}`);
  if (url.pathname === '/api/session' && request.method === 'GET') return sendJSON(response, 200, { token, version, productName: config.productName });
  if (url.pathname.startsWith('/api/')) {
    if (!authorized(request)) return sendJSON(response, 401, { error: 'UNAUTHORIZED' });
    try {
      if (url.pathname === '/api/health' && request.method === 'GET') return sendJSON(response, 200, { ok: true, status: 'ready', version, pid: process.pid, dataDir, browser: await browser.status() });
      if (url.pathname === '/api/platforms' && request.method === 'GET') return sendJSON(response, 200, { platforms: adapters, selected: config.selectedPlatforms || adapters.map(a => a.id) });
      if (url.pathname === '/api/logs' && request.method === 'GET') return sendJSON(response, 200, { logs });
      if (url.pathname === '/api/events' && request.method === 'GET') {
        response.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive' });
        response.write(`event: ready\ndata: ${JSON.stringify({ version })}\n\n`);
        events.add(response);
        request.on('close', () => events.delete(response));
        return;
      }
      if (url.pathname === '/api/browser/start' && request.method === 'POST') return sendJSON(response, 200, await browser.ensureRunning());
      if (url.pathname === '/api/browser/prepare' && request.method === 'POST') {
        return sendJSON(response, 200, await browser.prepareWorkbench());
      }
      if (url.pathname === '/api/browser/open' && request.method === 'POST') {
        const status = await browser.ensureRunning();
        const target = await browser.focusWorkbench();
        return sendJSON(response, 200, { ok: true, browser: status, target });
      }
      if (url.pathname === '/api/quit' && request.method === 'POST') {
        sendJSON(response, 200, { ok: true });
        setTimeout(() => { shutdown().finally(() => process.exit(0)); }, 150);
        return;
      }
      if (url.pathname === '/api/browser/stop' && request.method === 'POST') { await browser.stop(); return sendJSON(response, 200, { ok: true }); }
      const openMatch = url.pathname.match(/^\/api\/platforms\/([^/]+)\/open$/);
      if (openMatch && request.method === 'POST') {
        const adapter = adapters.find(item => item.id === openMatch[1]);
        if (!adapter) return sendJSON(response, 404, { error: 'UNKNOWN_PLATFORM' });
        return sendJSON(response, 200, { ok: true, target: await browser.openPlatform(adapter) });
      }
      const probeMatch = url.pathname.match(/^\/api\/platforms\/([^/]+)\/probe$/);
      if (probeMatch && request.method === 'GET') {
        const adapter = adapters.find(item => item.id === probeMatch[1]);
        if (!adapter) return sendJSON(response, 404, { error: 'UNKNOWN_PLATFORM' });
        return sendJSON(response, 200, await browser.probe(adapter));
      }
      if (url.pathname === '/api/send' && request.method === 'POST') {
        const body = await readBody(request);
        if (typeof body.text !== 'string' || !body.text.trim()) return sendJSON(response, 400, { error: 'TEXT_REQUIRED' });
        const ids = Array.isArray(body.platforms) && body.platforms.length ? body.platforms : adapters.map(a => a.id);
        const results = [];
        for (const id of ids) {
          const adapter = adapters.find(item => item.id === id);
          if (!adapter) { results.push({ id, ok: false, error: 'UNKNOWN_PLATFORM' }); continue; }
          try { results.push({ id, name: adapter.name, ok: true, result: await browser.send(adapter, body.text, Array.isArray(body.attachments) ? body.attachments : []) }); }
          catch (error) { results.push({ id, name: adapter.name, ok: false, error: error.message }); }
        }
        return sendJSON(response, 200, { ok: results.some(item => item.ok), results });
      }
      if (url.pathname === '/api/update/check' && request.method === 'POST') {
        const body = await readBody(request);
        return sendJSON(response, 200, await checkUpdate(body.url || args['update-url'] || config.updateManifest, version));
      }
      if (url.pathname === '/api/update/download' && request.method === 'POST') {
        const body = await readBody(request);
        return sendJSON(response, 200, await downloadUpdate(body.artifact || selectArtifact(body.manifest), join(dataDir, 'updates')));
      }
      return sendJSON(response, 404, { error: 'NOT_FOUND' });
    } catch (error) {
      log(error.stack || error.message || error);
      return sendJSON(response, 500, { error: error.message || 'INTERNAL_ERROR' });
    }
  }
  if (url.pathname === '/config.js') {
    const body = `window.__BRAINTRUST_CONFIG__=${JSON.stringify({ token, version, productName: config.productName })};`;
    response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' });
    return response.end(body);
  }
  const file = staticFile(url.pathname);
  if (!file) return sendJSON(response, 404, { error: 'NOT_FOUND' });
  response.writeHead(200, { 'content-type': contentType(file), 'cache-control': 'no-cache' });
  return response.end(readFileSync(file));
}

server = createServer((request, response) => handler(request, response).catch(error => {
  log(error.stack || error.message || error);
  if (!response.headersSent) sendJSON(response, 500, { error: 'INTERNAL_ERROR' }); else response.end();
}));

server.listen(Number(args.port), args.host, async () => {
  const address = server.address();
  const serviceURL = `http://${address.address}:${address.port}/`;
  browser.serviceURL = serviceURL;
  const ready = { ok: true, url: serviceURL, port: address.port, token, version, dataDir };
  try {
    writeFileSync(serviceInfoPath, `${JSON.stringify({ pid: process.pid, port: address.port, token, version, dataDir })}\n`, { mode: 0o600 });
  } catch (error) { log(`无法写入 service.json：${error.message}`); }
  if (args['print-ready']) process.stdout.write(`${JSON.stringify(ready)}\n`);
  log(`本地服务已启动：${serviceURL}`);
  if (!args['no-browser'] && config.openBrowser !== false) {
    try { await browser.ensureRunning(); log('浏览器工作台已打开'); }
    catch (error) { log(`浏览器尚未打开：${error.message}`); }
  }
});

async function shutdown() {
  await browser.stop();
  server?.close();
  try { rmSync(serviceInfoPath, { force: true }); } catch {}
  lockRelease();
}
process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);
process.once('exit', () => { try { rmSync(serviceInfoPath, { force: true }); } catch {} try { lockRelease(); } catch {} });
