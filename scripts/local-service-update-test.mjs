import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkUpdate, downloadUpdate } from '../local-service/lib/update.mjs';

const payload = Buffer.from('braintrust-local-service-update-test');
const sha256 = createHash('sha256').update(payload).digest('hex');
const server = createServer((request, response) => {
  if (request.url === '/manifest.json') {
    const body = JSON.stringify({ version: '0.6.0', artifacts: { [process.platform === 'win32' ? 'win32-x64' : 'darwin-universal']: { url: 'http://127.0.0.1:0/update.zip', sha256 } } });
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(body); return;
  }
  if (request.url === '/update.zip') { response.writeHead(200); response.end(payload); return; }
  response.writeHead(404); response.end();
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
const manifestURL = `http://127.0.0.1:${port}/manifest.json`;
const result = await checkUpdate(manifestURL, '0.5.0');
assert.equal(result.state, 'available');
assert.equal(result.latestVersion, '0.6.0');
result.artifact.url = `http://127.0.0.1:${port}/update.zip`;
const output = await downloadUpdate(result.artifact, mkdtempSync(join(tmpdir(), 'braintrust-update-')));
assert.equal(readFileSync(output.path, 'utf8'), payload.toString('utf8'));
await new Promise(resolve => server.close(resolve));
console.log('✅ 本地服务更新测试通过（版本判断、下载和 SHA-256 校验）');
