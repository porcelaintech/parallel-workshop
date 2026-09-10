// 真实 Windows Edge 上验证 v0.4.1 新启动模型（决定性 live test）：
//   1) 命令行 --load-extension（免开发者模式）在真实 Edge 中加载扩展；
//   2) 独立配置档 + 直接打开 chrome-extension://.../launch.html；
//   3) 首次启动展示引导页，点击「开始使用」后进入工作台（6 窗格、正确版本、无空白/错误页）；
//   4) 重启后引导不再出现（标记持久化），工作台直接可用；
//   5) 全程零 blank/错误/启动页残留。
// 前置：Edge 二进制路径通过 PWB_EDGE_BINARY 传入；PWB_EDGE_SOURCE 指向已安装的版本化扩展目录。
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cdpCommand } from './edge-workbench-target.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const source = resolve(process.env.PWB_EDGE_SOURCE || join(root, 'Windows/edge-extension'));
const edge = process.env.PWB_EDGE_BINARY || 'msedge.exe';
const port = Number(process.env.PWB_EDGE_PORT || 10141);
const extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek';
const workbenchURL = `chrome-extension://${extensionID}/workbench.html`;
const launchURL = `chrome-extension://${extensionID}/launch.html`;
// 与 launch.ps1 Get-LaunchArguments 一致：入口是本地 start.html（file:// 稳定加载后导航到启动页）
const startURL = new URL(`file://${join(source, 'start.html').replace(/\\/g, '/')}`).href;
const version = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8')).version;
const fixture = mkdtempSync(join(tmpdir(), 'braintrust-edge-live-'));
const profile = join(fixture, 'EdgeProfile');
const artifacts = process.env.PWB_EDGE_EVIDENCE || join(root, 'build', 'windows-edge-live');
mkdirSync(artifacts, { recursive: true });
const report = { source, version, fixture, platform: process.platform, node: process.version, status: 'RUNNING', cases: [], observations: [] };
const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));

function checkpoint(stage) {
  report.stage = stage;
  report.updatedAt = new Date().toISOString();
  writeFileSync(join(artifacts, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(`[edge-live] ${stage}`);
}

let child;
let output;

async function browserInfo() {
  return await (await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(3000) })).json();
}

async function listEdgeTargets() {
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(3000) });
  if (!response.ok) throw new Error(`Raw Edge target list: HTTP ${response.status}`);
  return await response.json();
}

async function startBrowser() {
  output = createWriteStream(join(artifacts, `edge-${report.cases.length}.log`));
  // 与 launch.ps1 Get-LaunchArguments 完全一致（附加调试端口）
  const args = [
    `--user-data-dir=${profile}`,
    `--disable-extensions-except=${source}`,
    `--load-extension=${source}`,
    '--no-first-run',
    '--no-default-browser-check',
    `--remote-debugging-port=${port}`,
    ...(process.env.PWB_EDGE_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),
    startURL
  ];
  report.launchArgs = args;
  child = spawn(edge, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let spawnError;
  child.on('error', (error) => { spawnError = error; });
  child.stdout.pipe(output, { end: false });
  child.stderr.pipe(output, { end: false });
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    if (spawnError) throw spawnError;
    try {
      const info = await browserInfo();
      report.browser = info.Browser;
      const targets = await listEdgeTargets();
      if (targets.some((target) => target.type === 'service_worker' && target.url === `chrome-extension://${extensionID}/background.js`)) {
        checkpoint('extension-worker-started');
        return;
      }
    } catch { /* Browser is still starting. */ }
    if (child.exitCode !== null) throw new Error(`Edge exited early: ${child.exitCode}`);
    await sleep(100);
  }
  throw new Error('Edge extension worker did not start (--load-extension may be unsupported on this Edge build)');
}

async function stopBrowser() {
  if (!child) return;
  try { await cdpCommand((await browserInfo()).webSocketDebuggerUrl, 'Browser.close'); } catch { /* Socket closes on shutdown. */ }
  const deadline = Date.now() + 10000;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) await sleep(100);
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  child.stdout?.unpipe(output);
  child.stderr?.unpipe(output);
  child.stdout?.destroy();
  child.stderr?.destroy();
  child.unref();
  await new Promise((resolveEnd) => (output ? output.end(resolveEnd) : resolveEnd()));
  output = null;
  child = null;
}

function forbiddenPage(page) {
  return page.url === 'about:blank' || /^(?:edge|chrome):\/\/(?:newtab|new-tab-page)/.test(page.url) ||
    /^https:\/\/ntp\.msn\.(?:com|cn)\/edge\/ntp/.test(page.url) ||
    page.url.startsWith('chrome-error:') || /^file:.*\/start\.html/.test(page.url) ||
    page.url === launchURL; // 工作台就绪后不得残留启动页（重复弹窗/未收口均视为失败）
}

async function evaluate(page, expression) {
  const result = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result?.value;
}

async function waitForWorkbench(label, expectedOnboarding) {
  const started = Date.now();
  checkpoint(`waiting:${label}`);
  const deadline = started + 60000;
  let last;
  while (Date.now() < deadline) {
    const pages = (await listEdgeTargets()).filter((target) => target.type === 'page');
    last = pages.map((page) => ({ id: page.id, url: page.url }));
    const workbenches = pages.filter((page) => page.url === workbenchURL);
    if (workbenches.length === 1 && !pages.some(forbiddenPage)) {
      const state = await evaluate(workbenches[0], `({version:chrome.runtime.getManifest().version,panes:document.querySelectorAll('.pane').length,overlay:!!document.getElementById('startup-overlay'),url:location.href})`);
      if (state.version === version && state.panes === 6 && !state.overlay && state.url === workbenchURL) {
        await sleep(700);
        const stablePages = (await listEdgeTargets()).filter((target) => target.type === 'page');
        if (stablePages.filter((page) => page.url === workbenchURL).length === 1 && !stablePages.some(forbiddenPage)) {
          const result = { label, expectedOnboarding, elapsedMs: Date.now() - started, version: state.version,
            workbenches: 1, blankOrErrorPages: 0,
            extraPages: stablePages.filter((page) => page.url !== workbenchURL).map(({ url }) => url) };
          report.cases.push(result);
          console.log(JSON.stringify(result));
          checkpoint(`passed:${label}`);
          return workbenches[0];
        }
      }
    }
    await sleep(100);
  }
  throw new Error(`${label} failed: ${JSON.stringify(last)}`);
}

async function waitForOnboarding() {
  const started = Date.now();
  const deadline = started + 30000;
  while (Date.now() < deadline) {
    const pages = (await listEdgeTargets()).filter((target) => target.type === 'page');
    const launcher = pages.find((page) => page.url === launchURL || page.url.startsWith(launchURL + '#'));
    if (launcher) {
      // 页面可能尚在导航（pending URL 已出现但文档未就绪），轮询等待元素挂载。
      const state = await evaluate(launcher,
        `({ready:!!document.getElementById('launch-onboarding'),visible:document.getElementById('launch-onboarding')&&!document.getElementById('launch-onboarding').hidden,steps:document.getElementById('launch-onboarding')?document.querySelectorAll('#launch-onboarding li').length:0,docURL:location.href})`);
      if (!state.ready) { await sleep(200); continue; }
      if (state.visible && state.steps === 4) {
        checkpoint('onboarding-visible');
        await evaluate(launcher, `document.getElementById('launch-onboarding-done').click()`);
        return;
      }
    }
    await sleep(100);
  }
  throw new Error('first-run onboarding did not appear');
}

try {
  await startBrowser();
  await waitForOnboarding();
  const page = await waitForWorkbench('first-launch-onboarding-then-workbench', true);

  checkpoint('preserve-extension-storage-sentinel');
  const sentinel = { selected: ['deepseek', 'doubao'], zoom: 0.9, proof: 'preserve-local-storage' };
  await evaluate(page, `chrome.storage.local.set({'edge-live-preserved':${JSON.stringify(sentinel)}})`);
  checkpoint('shutdown');
  await stopBrowser();

  checkpoint('second-cold-launch');
  await startBrowser();
  // 第二次启动：引导已标记完成，直接进入工作台
  const second = await waitForWorkbench('second-launch-straight-to-workbench', false);
  const preserved = await evaluate(second, `(async()=>(await chrome.storage.local.get('edge-live-preserved'))['edge-live-preserved'])()`);
  assert.deepEqual(preserved, sentinel, 'extension local storage must persist across cold restarts in the dedicated profile');
  report.preserved = { localStorage: true, onboardingOnce: true };
  checkpoint('passed');
  report.status = 'PASS';
} catch (error) {
  report.status = 'FAIL';
  report.error = String(error.stack || error);
  try {
    report.failureDiagnostics = [];
    for (const page of (await listEdgeTargets()).filter((target) => target.type === 'page').slice(0, 6)) {
      const diagnostic = { id: page.id, url: page.url, title: page.title };
      try {
        const value = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', {
          expression: `({url:location.href,title:document.title,status:document.getElementById('launch-status')?.textContent||null,onboarding:document.getElementById('launch-onboarding')&&!document.getElementById('launch-onboarding').hidden,errorCodes:document.body?.innerText.match(/ERR_[A-Z_]+/g)||[],version:typeof chrome!=='undefined'&&chrome.runtime?.getManifest?chrome.runtime.getManifest().version:null})`,
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
