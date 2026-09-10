import { readFileSync } from 'node:fs';

const root = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const failures = [];
const requireText = (condition, message) => { if (!condition) failures.push(message); };
const readBuffer = (path) => readFileSync(`${root}/${path}`);
const read = (path) => readBuffer(path).toString('utf8').replace(/^\uFEFF/, '');

const preflightPath = 'scripts/windows-device-preflight.ps1';
const livePath = 'scripts/windows-device-live-test.ps1';
for (const path of [preflightPath, livePath]) {
  const bytes = readBuffer(path);
  const source = read(path);
  requireText(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
    `${path} 必须带 UTF-8 BOM，确保 Windows PowerShell 5.1 正确读取中文`);
  requireText(source.includes('Set-StrictMode -Version 2.0') && source.includes("$ErrorActionPreference = 'Stop'"),
    `${path} 缺少严格错误处理`);
  requireText(source.includes('ConvertTo-Json -Depth 8'), `${path} 必须输出结构化 JSON`);
  for (const ps7Only of ['??', '?.', 'ForEach-Object -Parallel', 'ConvertFrom-Json -AsHashtable']) {
    requireText(!source.includes(ps7Only), `${path} 使用了 Windows PowerShell 5.1 不支持的语法：${ps7Only}`);
  }
}
const preflight = read(preflightPath);
const live = read(livePath);
requireText(preflight.includes('checks = $checks.ToArray()') &&
  live.includes('stages = $stages.ToArray()'),
  'PowerShell 5.1 不得用 @($genericList) 序列化泛型 List');
requireText(live.includes('$MyInvocation.MyCommand.Path') &&
  live.includes("if (-not $BootstrapPath)") && !live.includes('Split-Path -Parent $PSScriptRoot'),
  'PowerShell 5.1 必须在脚本主体内解析仓库路径，不能在参数默认值使用 PSScriptRoot');
requireText(preflight.includes('[ValidateRange(1, 60)]'), '网络超时必须限制为 1–60 秒，避免无限等待');
requireText(preflight.includes('readOnly = $true') && preflight.includes('readyForInstallerTest') &&
  preflight.includes('windowsHostReadyForMacSshProbe') && preflight.includes('remoteLoginVerified = $false'),
  '预检结果没有明确只读属性、本机前置结论或 Mac 侧登录验证边界');
requireText(preflight.includes("Add-Check 'os.windows'") && preflight.includes("Add-Check 'powershell.compatible'") &&
  preflight.includes("Add-Check 'edge.installed'"), '预检缺少 OS、PowerShell 或 Edge 诊断');
requireText(preflight.includes("Get-Service -Name 'sshd'") && preflight.includes("Add-Check 'openssh.port22'") &&
  preflight.includes("Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'"), '预检缺少 OpenSSH 服务、监听端口或防火墙诊断');
requireText(preflight.includes("Add-Check 'openssh.authorizedKeys'") && preflight.includes('contentsRead = $false'),
  '预检缺少 authorized_keys 存在性检查或意外读取了密钥内容');
requireText(preflight.includes('if ($isAdministrator)') && preflight.includes("'ssh\\administrators_authorized_keys'"),
  '管理员账户必须按 Windows OpenSSH 默认规则检查 ProgramData 密钥文件');
requireText(preflight.includes("Get-NetIPAddress -AddressFamily IPv4") &&
  preflight.includes('Test-GitHubDownloadRoute $Repository $NetworkTimeoutSeconds') &&
  preflight.includes('Invoke-RestMethod -UseBasicParsing') && preflight.includes('Invoke-WebRequest -UseBasicParsing -Method Head'),
  '预检缺少局域网地址或代理感知的 GitHub Release/资产可达性诊断');
requireText(preflight.includes('Get-Acl -LiteralPath') &&
  preflight.includes('ACL inspection only; no probe file was created'), '路径权限必须通过 ACL 只读评估');
requireText(preflight.includes("Add-Check 'path.installRoot.aclWriteHint'") &&
  preflight.includes("Add-Check 'path.temp.aclWriteHint'") && preflight.includes('writePermissionRequiresLiveTest = $true'),
  'ACL 结果必须标为非阻断提示，真实写权限留给隔离 live test 验证');
for (const mutation of [
  /\bNew-Item\b/, /\bSet-Item\b/, /\bRemove-Item\b/, /\bCopy-Item\b/, /\bMove-Item\b/,
  /\bRename-Item\b/, /\bSet-Content\b/, /\bAdd-Content\b/, /\bOut-File\b/, /\bStart-Process\b/,
  /\bStart-Service\b/, /\bSet-Service\b/, /\bAdd-WindowsCapability\b/,
  /\b(?:New|Set|Enable)-NetFirewallRule\b/, /\breg(?:\.exe)?\s+add\b/i,
]) {
  requireText(!mutation.test(preflight), `只读预检包含潜在修改命令：${mutation}`);
}

requireText(live.includes("ParameterSetName = 'Archive'") && live.includes("ParameterSetName = 'Url'") &&
  live.includes('[string]$ArchivePath') && live.includes('[Uri]$ArchiveUrl'), '真机测试必须接受候选 ZIP 或 HTTPS URL');
requireText(live.includes("$ArchiveUrl.Scheme -ne 'https'") || live.includes("$Uri.Scheme -ne 'https'"),
  '远程候选包必须限制为 HTTPS');
requireText(live.includes("ParameterSetName -eq 'Url' -and -not $ExpectedSHA256"),
  '远程候选包必须要求调用方提供受信任 SHA-256');
requireText(live.includes("'ParallelWorkbench-device-test-' + [Guid]::NewGuid().ToString('N')") &&
  live.includes("'测试 用户\\Parallel Workbench'"), '真机测试未使用唯一的中文空格隔离目录');
requireText(live.includes("'-NoLaunch', '-NoShortcuts', '-NoClipboard', '-VerifyOnly'") &&
  (live.match(/'-NoLaunch', '-NoShortcuts', '-NoClipboard'/g) || []).length >= 3,
  '真机测试没有在验证及两次安装中强制禁用启动、快捷方式和剪贴板');
requireText(live.includes("'bootstrap.verifyOnly'") && live.includes("'bootstrap.install.first'") &&
  live.includes("'bootstrap.install.idempotent'"), '真机测试缺少 VerifyOnly、首次安装或幂等安装阶段');
requireText(live.includes("foreach ($scriptName in @('install.ps1', 'launch.ps1'))") &&
  live.includes('与当前受信任源码不一致，拒绝执行'),
  '执行候选脚本前必须与受信任的本地安装/启动脚本逐字节比对');
requireText(live.includes('Get-DirectoryFingerprint $installed') &&
  live.includes('$firstInstallFingerprint -ne $secondInstallFingerprint'),
  '幂等验证必须比较完整扩展文件树，而非只比较版本或单个文件');
requireText(live.includes("Join-Path $installed 'launch.ps1'") && live.includes("@('-PrintOnly')") &&
  live.includes("'launcher.printOnly'"), '真机测试必须以 PrintOnly 检查启动器');
requireText(live.includes('WaitForExit([Math]::Max(1, $StepTimeoutSeconds) * 1000)') &&
  live.includes('$process.Kill()'), '每个 PowerShell 子阶段必须有超时上限');
requireText(live.includes('Get-FileHash -LiteralPath $candidate -Algorithm SHA256') &&
  live.includes('ExpectedSHA256'), '真机测试没有记录并按需强校验候选包 SHA-256');
requireText(live.includes("Remove-Item -LiteralPath $testRoot -Recurse -Force") &&
  live.includes('[switch]$KeepArtifacts') && live.includes('Test-SafeCleanupRoot') &&
  live.includes("'.pwb-device-test-sentinel'") && live.includes('[IO.FileAttributes]::ReparsePoint'),
  '真机测试缺少 sentinel/reparse/直属路径清理保护或审计留存开关');
requireText(live.includes('requestedNoLaunch = $true') && live.includes('requestedNoClipboard = $true') &&
  live.includes("launchValidationMode = 'PrintOnly'") && live.includes('This is not an OS sandbox.') &&
  live.includes('edgeProcessObservationAvailable = $edgeSnapshotCaptured'),
  '结构化摘要必须准确说明隔离请求与非沙箱边界');
requireText(live.includes('$edgeSnapshotCaptured = $true') && live.includes('if ($edgeSnapshotCaptured)'),
  '前置失败时不得把既有 Edge 进程误报为测试新进程');
requireText(!/\bStart-Process\b/.test(live) &&
  live.includes(`([string]$launchProbe.Arguments).Contains('--load-extension="' + $installed + '"')`) &&
  live.includes(`([string]$launchProbe.Arguments).Contains('--user-data-dir=')`) &&
  live.includes(`$launchProbe.Arguments -match 'about:blank'`),
  '真机测试不得启动 Edge；必须验证启动参数用命令行加载本次安装并启用独立 profile，且拒绝 blank 预热');

const qa = read('scripts/qa.sh');
requireText(qa.includes('node scripts/windows-device-harness-contract-test.mjs || FAIL=1'),
  'qa.sh 未接入 Windows 真机测试工具契约');

const workflow = read('.github/workflows/ci.yml');
requireText(workflow.includes("'scripts\\windows-device-preflight.ps1'") &&
  workflow.includes("'scripts\\windows-device-live-test.ps1'"),
  'Windows CI 的 PowerShell 5.1 parser 未覆盖真机测试工具');
requireText(workflow.includes('Run isolated Windows device harness') &&
  workflow.includes('-ExpectedSHA256 $digest') && workflow.includes('-TemporaryBase $env:RUNNER_TEMP'),
  'Windows CI 未真实执行带 SHA 校验和中文空格路径的隔离测试工具');

if (failures.length) {
  console.error(`❌ Windows 真机测试工具契约失败：\n- ${failures.join('\n- ')}`);
  process.exit(1);
}

console.log('✅ Windows 真机测试工具契约通过（只读预检/受信脚本/隔离安装/幂等/PrintOnly）');
