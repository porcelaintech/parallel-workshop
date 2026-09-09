import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const folder = mkdtempSync(join(tmpdir(), 'pwb-update-index-test-'));
// fileURLToPath 处理含空格等特殊字符的检出路径（URL.pathname 保留 %20 会导致 spawn 找不到文件）
const generator = fileURLToPath(new URL('./generate-update-manifest.mjs', import.meta.url));
try {
  writeFileSync(join(folder, 'ParallelWorkbench-1.2.3.dmg'), 'test-dmg');
  writeFileSync(join(folder, 'edge-extension.zip'), 'test-edge');
  const result = spawnSync(process.execPath, [generator, '1.2.3', folder], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const index = JSON.parse(readFileSync(join(folder, 'update.json'), 'utf8'));
  assert.equal(index.version, '1.2.3');
  assert.equal(index.schemaVersion, 1);
  assert.equal(index.dmgSHA256, createHash('sha256').update('test-dmg').digest('hex'));
  assert.equal(index.edgeSHA256, createHash('sha256').update('test-edge').digest('hex'));
  assert.equal(index.dmgURL, 'https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg');
  assert.equal(index.edgeURL, 'https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/edge-extension.zip');
  const before = readFileSync(join(folder, 'update.json'));
  const invalid = spawnSync(process.execPath, [generator, '../bad', folder]);
  assert.notEqual(invalid.status, 0);
  assert.deepEqual(readFileSync(join(folder, 'update.json')), before);
} finally {
  rmSync(folder, { recursive: true, force: true });
}
console.log('✅ 更新索引绑定发布版本、资产 URL 和真实文件 SHA-256');
