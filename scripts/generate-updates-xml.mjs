#!/usr/bin/env node
// 生成 Edge 自托管扩展更新清单 updates.xml（Omaha/update2 协议）。
// 权威依据：https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/auto-update
//   - 根元素 gupdate，xmlns 必须精确为 'http://www.google.com/update2/response'，protocol 精确 '2.0'
//   - 每个 <app appid='<扩展ID>'> 下恰好一个 <updatecheck codebase='https://...' version='x.y.z'/>
//   - hash_sha256 可选（小写 hex 的 .crx SHA-256），提供后浏览器下载时会校验完整性
//
// 用法：
//   node scripts/generate-updates-xml.mjs <版本> <crx 路径> <repo> [输出路径]
// 缺省输出 build/updates.xml；repo 缺省 porcelaintech/parallel-workshop。
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function fail(message) {
  console.error(`❌ ${message}`);
  process.exit(1);
}

const [version, crxArg, repoArg, outArg] = process.argv.slice(2);
if (!version || !/^\d+(\.\d+){1,3}$/.test(version)) fail('用法: node generate-updates-xml.mjs <x.y.z> <crx路径> [repo] [输出]');
const crxPath = resolve(crxArg || join(repoRoot, 'build', 'edge-extension.crx'));
const repo = repoArg || 'porcelaintech/parallel-workshop';
const outPath = resolve(outArg || join(repoRoot, 'build', 'updates.xml'));

if (!existsSync(crxPath)) fail(`CRX 不存在: ${crxPath}`);

const pubDer = execFileSync('openssl', ['rsa', '-in', process.env.PWB_CRX_KEY || join(repoRoot, 'keys', 'edge-extension.pem'), '-pubout', '-outform', 'DER'], { stdio: ['ignore', 'pipe', 'pipe'] });
const digest = createHash('sha256').update(pubDer).digest().subarray(0, 16);
let hex = '';
for (const b of digest) hex += b.toString(16).padStart(2, '0');
const extId = [...hex].map((c) => String.fromCharCode('a'.charCodeAt(0) + parseInt(c, 16))).join('');

const crx = readFileSync(crxPath);
const sha256 = createHash('sha256').update(crx).digest('hex');
const codebase = `https://github.com/${repo}/releases/download/v${version}/edge-extension-${extId}.crx`;
const xml = `<?xml version='1.0' encoding='UTF-8'?>\n` +
  `<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>\n` +
  `  <app appid='${extId}'>\n` +
  `    <updatecheck codebase='${codebase}' version='${version}' hash_sha256='${sha256}' />\n` +
  `  </app>\n` +
  `</gupdate>\n`;

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, xml);
console.log(`✅ updates.xml 已生成: ${outPath}`);
console.log(`   appid    : ${extId}`);
console.log(`   version  : ${version}`);
console.log(`   codebase : ${codebase}`);
console.log(`   sha256   : ${sha256}`);
