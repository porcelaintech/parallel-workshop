// 仅用于隔离 Edge profile：真实验证工具栏逻辑会把当前 about:blank 原地替换为工作台。
import { assertCleanWorkbenchTargets, cdpCommand, ensureSingleWorkbenchPage, listEdgeTargets } from './edge-workbench-target.mjs';

const EXT_ID = process.argv[2] || 'mklpdfdkbchlahfahofajchfjphlpkek';
const PORT = Number(process.env.PWB_EDGE_PORT || 9223);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const page = await ensureSingleWorkbenchPage({ port: PORT, extId: EXT_ID });
let targets = await listEdgeTargets(PORT);
const worker = targets.find(target => target.type === 'service_worker' && target.url.endsWith('/background.js'));
if (!worker) throw new Error('扩展 service worker 未就绪');

const tabResult = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', {
  expression: `(async () => {
    const tab = await chrome.tabs.getCurrent();
    return { id: tab && tab.id, windowId: tab && tab.windowId };
  })()`,
  awaitPromise: true,
  returnByValue: true
});
const tab = tabResult?.result?.value;
if (!Number.isInteger(tab?.id) || !Number.isInteger(tab?.windowId)) throw new Error('无法读取工作台 tab 元数据');

await cdpCommand(page.webSocketDebuggerUrl, 'Page.navigate', { url: 'about:blank' });
await sleep(250);

const actionResult = await cdpCommand(worker.webSocketDebuggerUrl, 'Runtime.evaluate', {
  expression: `(async () => {
    await openWorkbenchFromAction({ id: ${tab.id}, windowId: ${tab.windowId}, url: 'about:blank' });
    return true;
  })()`,
  awaitPromise: true,
  returnByValue: true
});
if (actionResult?.result?.value !== true) throw new Error('工具栏启动函数未完成');

let restored = null;
for (let i = 0; i < 30 && !restored; i++) {
  await sleep(250);
  targets = await listEdgeTargets(PORT);
  restored = targets.find(target => target.type === 'page' && target.id === page.id &&
    target.url === `chrome-extension://${EXT_ID}/workbench.html`);
}
if (!restored) throw new Error('about:blank 未在原 tab 内恢复为工作台');

const hygiene = await assertCleanWorkbenchTargets({ port: PORT, extId: EXT_ID });
console.log(`✅ Edge 工具栏真实回归通过（同一 target=${restored.id}，workbench=${hygiene.workbenchCount}，blank=${hygiene.blankCount}）`);
