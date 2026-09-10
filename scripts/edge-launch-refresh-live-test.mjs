// Real Edge lifecycle regression. All profiles and installed files are disposable.
// No target-cleanup helper is used: an extra blank/error/start page fails the test.
// PWB_EDGE_SOURCE may point at an extracted release edge-extension directory.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { cpSync, createWriteStream, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { platform, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { cdpCommand } from './edge-workbench-target.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const source = resolve(process.env.PWB_EDGE_SOURCE || join(root, 'Windows/edge-extension'));
const edge = process.env.PWB_EDGE_BINARY || process.env.PWB_EDGE_BIN || '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge';
const port = Number(process.env.PWB_EDGE_PORT || 10141);
const extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek';
const workbenchURL = `chrome-extension://${extensionID}/workbench.html`;
const version = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8')).version;
const fixture = mkdtempSync(join(tmpdir(), 'braintrust-launch-live-'));
const artifacts = process.env.PWB_EDGE_EVIDENCE || join(root, 'build', 'launch-refresh-live', new Date().toISOString().replace(/[:.]/g, '-'));
mkdirSync(artifacts, { recursive: true });
const report = { source, version, fixture, platform: platform(), node: process.version, status: 'RUNNING', cases: [], observations: [] };
function checkpoint(stage) {
  report.stage = stage;
  report.updatedAt = new Date().toISOString();
  writeFileSync(join(artifacts, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(`[edge-live] ${stage}`);
}

function installCandidateAt(destination) {
  if (platform() === 'win32') {
    // Exercise the actual product installer while Edge is running, including
    // directory replacement and rollback, rather than simulating it with cp.
    execFileSync('powershell.exe', [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', join(source, 'install.ps1'), '-SourceDir', source,
      '-TargetRoot', dirname(destination), '-NoLaunch', '-NoShortcuts', '-NoClipboard'
    ], { timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  } else cpSync(source, destination, { recursive: true });
}
if (process.env.PWB_EDGE_START_URL) assert.equal(process.env.PWB_EDGE_START_URL, pathToFileURL(join(source, 'start.html')).href,
  'The actual PowerShell launcher must point at the installed visible entry.');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let child;
let output;

async function evaluate(page, expression) {
  const result = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true
  });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result?.value;
}

async function browserInfo() {
  return await (await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(3000) })).json();
}

async function listEdgeTargets() {
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(3000) });
  if (!response.ok) throw new Error(`Raw Edge target list: HTTP ${response.status}`);
  return await response.json();
}

async function startBrowser(extension, profile, entry) {
  output = createWriteStream(join(artifacts, `edge-${report.cases.length}.log`));
  const args = [
    `--user-data-dir=${profile}`, '--profile-directory=Default',
    `--disable-extensions-except=${extension}`, `--load-extension=${extension}`,
    `--remote-debugging-port=${port}`, '--no-first-run', '--no-default-browser-check',
    ...(entry ? [`--app=${entry}`] : ['--no-startup-window'])
  ];
  child = spawn(edge, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  let spawnError;
  child.on('error', error => { spawnError = error; });
  child.stdout.pipe(output, { end: false });
  child.stderr.pipe(output, { end: false });
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (spawnError) throw spawnError;
    try {
      const info = await browserInfo();
      report.browser = info.Browser;
      const targets = await listEdgeTargets(port);
      if (targets.some(target => target.type === 'service_worker' && target.url === `chrome-extension://${extensionID}/background.js`)) return;
    } catch { /* Browser is still starting. */ }
    if (child.exitCode !== null) throw new Error(`Edge exited early: ${child.exitCode}`);
    await sleep(100);
  }
  throw new Error('Edge extension worker did not start');
}

async function stopBrowser() {
  if (!child) return;
  try { await cdpCommand((await browserInfo()).webSocketDebuggerUrl, 'Browser.close'); } catch { /* Browser socket closes on shutdown. */ }
  const deadline = Date.now() + 10000;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) await sleep(100);
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  // Chromium child processes may inherit these pipes after the browser process
  // exits; close our owned handles so a completed report cannot hang the runner.
  child.stdout?.unpipe(output);
  child.stderr?.unpipe(output);
  child.stdout?.destroy();
  child.stderr?.destroy();
  child.unref();
  await new Promise(resolve => output ? output.end(resolve) : resolve());
  output = null;
  child = null;
}

async function openEntry(url) {
  return await cdpCommand((await browserInfo()).webSocketDebuggerUrl, 'Target.createTarget', { url, newWindow: true });
}

function forbiddenPage(page) {
  return page.url === 'about:blank' || /^(?:edge|chrome):\/\/(?:newtab|new-tab-page)/.test(page.url) ||
    /^https:\/\/ntp\.msn\.(?:com|cn)\/edge\/ntp/.test(page.url) ||
    page.url.startsWith('chrome-error:') || page.url.endsWith('/launch.html') ||
    /^file:.*\/start\.html/.test(page.url);
}

async function ready(label, expectedVersion = version) {
  const started = Date.now();
  checkpoint(`waiting:${label}`);
  let last;
  let candidate;
  let previousTargets;
  const deadline = started + 45000;
  while (Date.now() < deadline) {
    const pages = (await listEdgeTargets(port)).filter(target => target.type === 'page');
    last = pages.map(page => ({ id: page.id, url: page.url }));
    const targetSignature = JSON.stringify(last);
    if (targetSignature !== previousTargets) {
      report.observations.push({ label, elapsedMs: Date.now() - started, rawTopLevelPages: last });
      previousTargets = targetSignature;
    }
    const workbenches = pages.filter(page => page.url === workbenchURL);
    if (workbenches.length === 1 && !pages.some(forbiddenPage)) {
      try {
        const state = await evaluate(workbenches[0], `({version:chrome.runtime.getManifest().version,panes:document.querySelectorAll('.pane').length,overlay:!!document.getElementById('startup-overlay'),url:location.href})`);
        if (state.version === expectedVersion && state.panes === 6 && !state.overlay && state.url === workbenchURL) {
          candidate = workbenches[0];
          // Require stability across asynchronous onInstalled and launch-ready events.
          await sleep(700);
          const stablePages = (await listEdgeTargets(port)).filter(target => target.type === 'page');
          if (stablePages.filter(page => page.url === workbenchURL).length === 1 && !stablePages.some(forbiddenPage)) {
            const result = { label, elapsedMs: Date.now() - started, version: state.version, targetId: candidate.id,
              workbenches: 1, blankOrErrorOrStartupPages: 0,
              additionalBrowserPages: stablePages.filter(page => page.url !== workbenchURL).map(({ id, url, title }) => ({ id, url, title })) };
            report.cases.push(result);
            console.log(JSON.stringify(result));
            checkpoint(`passed:${label}`);
            return candidate;
          }
        }
      } catch { /* Navigation/reload temporarily invalidates the old context. */ }
    }
    await sleep(100);
  }
  throw new Error(`${label} failed: ${JSON.stringify(last)}`);
}

try {
  checkpoint('prepare-published-v0.3.1');
  // The old runtime is built from the actual published tag, not a new build whose
  // version number was edited. Only its generated runtime resources are needed.
  const oldStage = join(fixture, 'published-031');
  mkdirSync(oldStage);
  const archive = execFileSync('git', ['archive', 'v0.3.1', 'Windows/edge-extension'], { cwd: root, maxBuffer: 10 * 1024 * 1024 });
  execFileSync('tar', ['-xf', '-', '-C', oldStage], { input: archive });
  const installed = join(oldStage, 'Windows/edge-extension');
  const oldProfile = join(fixture, 'upgrade-profile');
  await startBrowser(installed, oldProfile);
  await openEntry(workbenchURL);
  let page = await ready('published-v0.3.1-before-install', '0.3.1');
  const originalTargetID = page.id;
  const sentinel = { selected: ['deepseek', 'doubao'], zoom: 0.9, proof: 'preserve-extension-local-storage' };
  checkpoint('save-extension-storage-sentinel');
  await evaluate(page, `chrome.storage.local.set({'launch-regression-preserved':${JSON.stringify(sentinel)}})`);
  checkpoint('save-site-cookie-sentinel');
  await cdpCommand(page.webSocketDebuggerUrl, 'Network.setCookie', {
    name: 'braintrust_reload_regression', value: 'preserve-site-cookie',
    url: 'https://chat.deepseek.com/', secure: true, expires: Math.floor(Date.now() / 1000) + 3600
  });
  checkpoint('install-new-files-while-old-edge-is-running');
  installCandidateAt(installed);
  checkpoint('verify-old-runtime-new-disk-mismatch');
  const mismatch = await evaluate(page, `(async()=>({runtime:chrome.runtime.getManifest().version,disk:(await(await fetch(chrome.runtime.getURL('manifest.json'),{cache:'no-store'})).json()).version}))()`);
  assert.deepEqual(mismatch, { runtime: '0.3.1', disk: version });
  checkpoint('open-visible-entry-for-upgrade');
  await openEntry(pathToFileURL(join(installed, 'start.html')).href);
  page = await ready('actual-v0.3.1-runtime-to-new-disk-and-self-reload');
  assert.equal(page.id, originalTargetID, 'The old workbench tab must be restored in place after Edge changes it to a new-tab page');
  assert.deepEqual(await evaluate(page, `(async()=>(await chrome.storage.local.get('launch-regression-preserved'))['launch-regression-preserved'])()`), sentinel);
  const cookies = await cdpCommand(page.webSocketDebuggerUrl, 'Network.getCookies', { urls: ['https://chat.deepseek.com/'] });
  assert.equal(cookies.cookies.find(cookie => cookie.name === 'braintrust_reload_regression')?.value, 'preserve-site-cookie');
  report.preserved = { localStorage: true, siteCookie: true, originalWorkbenchTab: true };
  await Promise.all([openEntry(pathToFileURL(join(installed, 'start.html')).href), openEntry(pathToFileURL(join(installed, 'start.html')).href)]);
  assert.equal((await ready('two-simultaneous-desktop-launches-reuse-existing')).id, page.id);
  await stopBrowser();

  await startBrowser(installed, oldProfile, pathToFileURL(join(installed, 'start.html')).href);
  await ready('cold-restart-existing-profile-through-visible-local-entry');
  await stopBrowser();

  const freshInstalled = join(fixture, 'fresh-install', 'edge-extension');
  checkpoint('install-fresh-candidate');
  installCandidateAt(freshInstalled);
  await startBrowser(freshInstalled, join(fixture, 'first-install-profile'), pathToFileURL(join(freshInstalled, 'start.html')).href);
  await ready('fresh-install-local-entry-and-onInstalled-concurrent');
  await stopBrowser();
  report.status = 'PASS';
} catch (error) {
  report.status = 'FAIL';
  report.error = String(error.stack || error);
  report.failureDiagnostics = [];
  try {
    for (const page of (await listEdgeTargets()).filter(target => target.type === 'page').slice(0, 6)) {
      const diagnostic = { id: page.id, url: page.url, title: page.title };
      try {
        const value = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', {
          expression: `({url:location.href,title:document.title,status:document.getElementById('launch-status')?.textContent||null,errorCodes:document.body?.innerText.match(/ERR_[A-Z_]+/g)||[],version:typeof chrome!=='undefined'&&chrome.runtime?.getManifest?chrome.runtime.getManifest().version:null})`,
          returnByValue: true
        }, 3000);
        diagnostic.state = value.result?.value;
      } catch (probeError) { diagnostic.probeError = String(probeError.message || probeError); }
      report.failureDiagnostics.push(diagnostic);
    }
  } catch (probeError) { report.diagnosticError = String(probeError.message || probeError); }
  throw error;
} finally {
  await stopBrowser();
  writeFileSync(join(artifacts, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(`Live evidence: ${join(artifacts, 'report.json')}`);
}
