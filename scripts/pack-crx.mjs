#!/usr/bin/env node
// CRX3 打包器：把构建好的扩展目录打包为 Edge/Chromium 可安装的 .crx（自托管分发用）。
//
// 权威依据（Chromium 官方源码）：
//   - 文件布局: "Cr24" | uint32le(3) | uint32le(len(header)) | CrxFileHeader(protobuf) | zip
//   - CrxFileHeader 字段号: sha256_with_rsa=2, signed_header_data=10000
//   - AsymmetricKeyProof: public_key=1 (SPKI DER), signature=2
//   - 签名范围: "CRX3 SignedData" + 0x00 + uint32le(len(signed_header_data)) + signed_header_data + zip
//   - 算法: RSA PKCS#1 v1.5 SHA-256（openssl dgst -sha256 -sign，勿用 PSS）
//
// 用法：
//   node scripts/pack-crx.mjs <扩展目录> <私钥.pem> <输出.crx>
//   PWB_CRX_KEY 环境变量可替代 <私钥.pem> 参数。
//
// 扩展 ID 推导（与 Chromium id_util 一致）：
//   SHA256(SPKI_DER) 前 16 字节 → hex → 每半字节 0-15 映射为 'a'-'p'。
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, statSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function fail(message) {
  console.error(`❌ ${message}`);
  process.exit(1);
}

// —— 最小 protobuf 编码（varint + tag + 字段）——
function varint(value) {
  const bytes = [];
  let v = BigInt(value);
  do {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    if (v !== 0n) b |= 0x80;
    bytes.push(b);
  } while (v !== 0n);
  return Buffer.from(bytes);
}

function tag(fieldNumber, wireType) {
  return varint((fieldNumber << 3) | wireType);
}

function fieldBytes(fieldNumber, payload) {
  return Buffer.concat([tag(fieldNumber, 2), varint(payload.length), payload]);
}

// SignedData { crx_id = 1 }
function encodeSignedData(crxIdBytes) {
  return fieldBytes(1, crxIdBytes);
}

// AsymmetricKeyProof { public_key = 1, signature = 2 }
function encodeKeyProof(publicKeyDer, signature) {
  return Buffer.concat([fieldBytes(1, publicKeyDer), fieldBytes(2, signature)]);
}

// CrxFileHeader { sha256_with_rsa = 2 (repeated), signed_header_data = 10000 }
function encodeCrxFileHeader(proof, signedHeaderData) {
  return Buffer.concat([fieldBytes(2, proof), fieldBytes(10000, signedHeaderData)]);
}

function zipDirectory(sourceDir) {
  // 用系统 zip 生成确定性归档；扩展目录内已有构建产物，直接打包。
  const archivePath = join(sourceDir, '..', `.crx-stage-${process.pid}.zip`);
  try {
    const prevCwd = process.cwd();
    process.chdir(sourceDir);
    try {
      execFileSync('zip', ['-q', '-r', '-X', archivePath, '.', '-x', '.*'], { stdio: 'pipe' });
    } finally {
      process.chdir(prevCwd);
    }
    return readFileSync(archivePath);
  } finally {
    try { execFileSync('rm', ['-f', archivePath]); } catch {}
  }
}

function deriveExtensionId(pubDer) {
  const digest = createHash('sha256').update(pubDer).digest().subarray(0, 16);
  let hex = '';
  for (const byte of digest) hex += byte.toString(16).padStart(2, '0');
  return [...hex].map((c) => String.fromCharCode('a'.charCodeAt(0) + parseInt(c, 16))).join('');
}

function main() {
  const args = process.argv.slice(2);
  const sourceDir = args[0] ? resolve(args[0]) : join(repoRoot, 'build', 'crx-input');
  const keyPath = args[1] || process.env.PWB_CRX_KEY || join(repoRoot, 'keys', 'edge-extension.pem');
  const outPath = args[2] ? resolve(args[2]) : join(repoRoot, 'build', 'edge-extension.crx');

  if (!existsSync(join(sourceDir, 'manifest.json'))) {
    fail(`扩展目录缺少 manifest.json: ${sourceDir}`);
  }
  if (!existsSync(keyPath)) {
    fail(`私钥不存在: ${keyPath}（首次打包前运行: openssl genrsa -out ${keyPath} 2048）`);
  }
  mkdirSync(dirname(outPath), { recursive: true });

  const manifest = JSON.parse(readFileSync(join(sourceDir, 'manifest.json'), 'utf8'));
  const version = String(manifest.version || '');
  if (!/^\d+(\.\d+){1,3}$/.test(version)) fail(`manifest.json 版本号无效: ${version}`);

  const pubDer = execFileSync('openssl', ['rsa', '-in', keyPath, '-pubout', '-outform', 'DER'], { stdio: ['ignore', 'pipe', 'pipe'] });
  if (manifest.key) {
    // manifest 若声明 key，必须与签名私钥一致（CRX 场景 key 通常省略，ID 由签名决定）。
    const declaredKey = Buffer.from(String(manifest.key), 'base64');
    if (!declaredKey.equals(pubDer)) {
      fail('manifest.json 的 key 与私钥不匹配（公钥推导不一致）');
    }
  }
  const extId = deriveExtensionId(pubDer);

  const zipBytes = zipDirectory(sourceDir);
  const signedHeaderData = encodeSignedData(createHash('sha256').update(pubDer).digest().subarray(0, 16));
  const signatureInput = Buffer.concat([
    Buffer.from('CRX3 SignedData\0', 'binary'),
    Buffer.from([signedHeaderData.length & 0xff, (signedHeaderData.length >> 8) & 0xff, (signedHeaderData.length >> 16) & 0xff, (signedHeaderData.length >> 24) & 0xff]),
    signedHeaderData,
    zipBytes
  ]);
  const signature = execFileSync('openssl', ['dgst', '-sha256', '-sign', keyPath], { input: signatureInput, stdio: ['pipe', 'pipe', 'pipe'] });
  const header = encodeCrxFileHeader(encodeKeyProof(pubDer, signature), signedHeaderData);

  const crx = Buffer.concat([
    Buffer.from('Cr24', 'binary'),
    Buffer.from([3, 0, 0, 0]),
    Buffer.from([header.length & 0xff, (header.length >> 8) & 0xff, (header.length >> 16) & 0xff, (header.length >> 24) & 0xff]),
    header,
    zipBytes
  ]);
  writeFileSync(outPath, crx);
  const sha256 = createHash('sha256').update(crx).digest('hex');
  console.log(`✅ CRX 打包完成: ${outPath}`);
  console.log(`   extension id : ${extId}`);
  console.log(`   version      : ${version}`);
  console.log(`   size         : ${crx.length} bytes`);
  console.log(`   sha256       : ${sha256}`);
}

main();
