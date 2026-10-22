import { createHash, verify } from 'node:crypto';
import { createWriteStream, mkdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs';
import { basename, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';

const timeoutSignal = (ms) => AbortSignal.timeout(Math.max(1000, ms));

export async function checkUpdate(manifestURL, currentVersion) {
  if (!manifestURL) return { state: 'disabled', currentVersion };
  const response = await fetch(manifestURL, { signal: timeoutSignal(12000), headers: { accept: 'application/json' } });
  if (!response.ok) throw new Error(`更新索引返回 HTTP ${response.status}`);
  const manifest = await response.json();
  if (!/^\d+\.\d+\.\d+$/.test(String(manifest.version || ''))) throw new Error('更新索引版本号无效');
  const newer = compareVersions(manifest.version, currentVersion) > 0;
  return { state: newer ? 'available' : 'latest', currentVersion, latestVersion: manifest.version, manifest, artifact: selectArtifact(manifest) };
}

export async function downloadUpdate(manifest, destination) {
  if (!manifest?.url || !manifest?.sha256) throw new Error('更新包缺少 url 或 sha256');
  mkdirSync(destination, { recursive: true });
  const name = basename(new URL(manifest.url).pathname) || 'braintrust-update.bin';
  const tmp = join(destination, `.${name}.download-${process.pid}`);
  const target = join(destination, name);
  const response = await fetch(manifest.url, { signal: timeoutSignal(120000) });
  if (!response.ok || !response.body) throw new Error(`更新包下载失败（HTTP ${response.status}）`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(tmp));
  const digest = createHash('sha256').update(readFileSync(tmp)).digest('hex');
  if (digest.toLowerCase() !== String(manifest.sha256).toLowerCase()) {
    rmSync(tmp, { force: true });
    throw new Error('更新包 SHA-256 校验失败');
  }
  renameSync(tmp, target);
  return { path: target, sha256: digest, bytes: statSync(target).size };
}

export function compareVersions(a, b) {
  const left = String(a).split('.').map(Number);
  const right = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    const d = (left[i] || 0) - (right[i] || 0);
    if (d) return d;
  }
  return 0;
}

export function selectArtifact(manifest) {
  if (manifest?.url && manifest?.sha256) return manifest;
  const key = process.platform === 'win32' ? 'win32-x64' : process.platform === 'darwin' ? 'darwin-universal' : 'linux-x64';
  return manifest?.artifacts?.[key] || null;
}
