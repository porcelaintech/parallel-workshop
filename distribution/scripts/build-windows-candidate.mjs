// Build a Windows test candidate from this exact clean commit; never publish it.
import { cpSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = resolve(new URL('../..', import.meta.url).pathname);
process.chdir(root);
execFileSync('git', ['diff', '--exit-code']);
execFileSync('git', ['diff', '--cached', '--exit-code']);
if (execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'], { encoding: 'utf8' }).trim()) throw new Error('Candidate requires a clean working tree including untracked source inputs');
const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
const version = process.env.CANDIDATE_VERSION || '0.6.0-rc.2.B';
const sourceVersion = JSON.parse(readFileSync('local-service/package.json')).version;
if (!/^\d+\.\d+\.\d+-rc\.\d+(?:\.[A-Z]+)?$/.test(version) || version.split('-')[0] !== sourceVersion.split('-')[0]) {
  throw new Error('Candidate must retain the current three-part version and have a unique rc identifier');
}
const out = resolve('build/windows-acceptance');
rmSync(out, { recursive: true, force: true });
const stage = join(out, 'stage');
const service = join(stage, 'local-service');
mkdirSync(service, { recursive: true });
for (const item of ['server.mjs', 'package.json', 'README.md', 'lib', 'config', 'public']) {
  cpSync(join(root, 'local-service', item), join(service, item), { recursive: true });
}
mkdirSync(join(service, 'data', 'adapters'), { recursive: true });
cpSync('Sources/WorkbenchCore/Resources/adapters', join(service, 'data', 'adapters'), { recursive: true });
cpSync('Sources/WorkbenchCore/Resources/injection', join(service, 'data'), { recursive: true });
for (const item of ['package.json', 'config/default.json']) {
  const path = join(service, item);
  const data = JSON.parse(readFileSync(path));
  data.version = version;
  writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
}
mkdirSync(join(stage, 'assets'), { recursive: true });
cpSync('distribution/assets/AppIcon.ico', join(stage, 'assets/AppIcon.ico'));
cpSync('distribution/windows/launcher.ps1', join(stage, 'launcher.ps1'));
const runtimeVersion = '22.23.4';
const archive = `node-v${runtimeVersion}-win-x64.zip`;
const base = `https://nodejs.org/dist/v${runtimeVersion}`;
const sumsResponse = await fetch(`${base}/SHASUMS256.txt`, { signal: AbortSignal.timeout(30000) });
if (!sumsResponse.ok) throw new Error(`Node checksums HTTP ${sumsResponse.status}`);
const expected = (await sumsResponse.text()).split('\n').find(line => line.trim().endsWith(` ${archive}`))?.trim().split(/\s+/)[0];
if (!expected) throw new Error('Official Node archive checksum missing');
const response = await fetch(`${base}/${archive}`, { signal: AbortSignal.timeout(180000) });
if (!response.ok) throw new Error(`Node archive HTTP ${response.status}`);
const bytes = Buffer.from(await response.arrayBuffer());
const actual = createHash('sha256').update(bytes).digest('hex');
if (actual !== expected) throw new Error('Official Node checksum mismatch');
const zip = join(out, archive);
writeFileSync(zip, bytes);
execFileSync('unzip', ['-q', zip, '-d', out]);
const runtime = join(service, 'runtime', 'node-win-x64');
mkdirSync(runtime, { recursive: true });
for (const item of ['node.exe', 'LICENSE']) cpSync(join(out, `node-v${runtimeVersion}-win-x64`, item), join(runtime, item));
const proof = { version, sourceCommit, sourceRef: process.env.GITHUB_REF || null, runtimeVersion, runtimeArchiveSHA256: actual };
writeFileSync(join(service, 'build-proof.json'), JSON.stringify(proof, null, 2) + '\n');
const artifactDir = join(out, 'artifacts');
mkdirSync(artifactDir, { recursive: true });
const installer = join(artifactDir, `Braintrust-Setup-${version}.exe`);
execFileSync('bash', ['distribution/windows/build-installer.sh', stage, installer, version], { stdio: 'inherit' });
const installerBytes = readFileSync(installer);
if (installerBytes.length > 50000000) throw new Error('Installer exceeds 50 MB');
proof.installer = { name: installer.split('/').pop(), bytes: installerBytes.length, sha256: createHash('sha256').update(installerBytes).digest('hex') };
writeFileSync(join(artifactDir, 'build-proof.json'), JSON.stringify(proof, null, 2) + '\n');
console.log(JSON.stringify(proof, null, 2));
