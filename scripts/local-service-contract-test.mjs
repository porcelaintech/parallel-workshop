import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const root = decodeURIComponent(new URL('..', import.meta.url).pathname);
const service = join(root, 'local-service', 'server.mjs');
assert.ok(existsSync(service), '本地服务入口缺失');
const windowsSmoke = join(root, 'scripts', 'local-service-windows-smoke.ps1');
assert.ok(existsSync(windowsSmoke), 'Windows smoke test 缺失');
assert.deepEqual([...readFileSync(windowsSmoke).subarray(0, 3)], [0xef, 0xbb, 0xbf], 'Windows PowerShell smoke test 必须带 UTF-8 BOM');
const dataDir = mkdtempSync(join(tmpdir(), 'braintrust-service-'));
const child = spawn(process.execPath, [service, '--no-browser', '--print-ready', '--data-dir', dataDir, '--port', '0'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
let output = '';
child.stdout.on('data', chunk => { output += String(chunk); });
child.stderr.on('data', chunk => { output += String(chunk); });
const deadline = Date.now() + 10000;
let ready;
while (Date.now() < deadline && !ready) {
  const line = output.split(/\r?\n/).find(item => item.startsWith('{"ok":true'));
  if (line) ready = JSON.parse(line);
  else await new Promise(resolve => setTimeout(resolve, 50));
}
assert.ok(ready, `服务未在期限内启动：${output}`);
const unauthorized = await fetch(`${ready.url}api/health`);
assert.equal(unauthorized.status, 401, 'API 必须拒绝没有令牌的请求');
const headers = { authorization: `Bearer ${ready.token}` };
const health = await (await fetch(`${ready.url}api/health`, { headers })).json();
assert.equal(health.ok, true);
const platforms = await (await fetch(`${ready.url}api/platforms`, { headers })).json();
assert.equal(platforms.platforms.length, 6, '必须加载六个平台适配器');
const page = await (await fetch(ready.url)).text();
assert.match(page, /智囊/);
child.kill('SIGTERM');
await new Promise(resolve => child.once('exit', resolve));
console.log('✅ 本地服务合同测试通过（启动、令牌、健康检查、六平台适配器、静态工作台）');
