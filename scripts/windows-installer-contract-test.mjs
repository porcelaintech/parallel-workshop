import { readFileSync } from 'node:fs';

const root = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const fail = [];
const requireText = (condition, message) => { if (!condition) fail.push(message); };
const readBuffer = (path) => readFileSync(`${root}/${path}`);
const read = (path) => readBuffer(path).toString('utf8').replace(/^\uFEFF/, '');

const psFiles = [
  'install-windows.ps1',
  'Windows/edge-extension/install.ps1',
  'Windows/edge-extension/launch.ps1',
];

for (const path of psFiles) {
  const bytes = readBuffer(path);
  const source = read(path);
  requireText(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
    `${path} 必须带 UTF-8 BOM，确保 Windows PowerShell 5.1 正确读取中文`);
  requireText(source.includes('Set-StrictMode -Version 2.0') && source.includes("$ErrorActionPreference = 'Stop'"),
    `${path} 缺少严格错误处理`);
  for (const ps7Only of ['??', '?.', 'ForEach-Object -Parallel', 'ConvertFrom-Json -AsHashtable']) {
    requireText(!source.includes(ps7Only), `${path} 使用了 Windows PowerShell 5.1 不支持的语法：${ps7Only}`);
  }
}

const bootstrap = read('install-windows.ps1');
requireText(bootstrap.includes('/releases/latest'), '固定入口必须读取最新稳定 Release');
requireText(!/releases\/download\/v?\d/.test(bootstrap), '固定入口不得硬编码下载版本号');
requireText(bootstrap.includes("$_.name -eq 'edge-extension.zip'"), '固定入口必须精确选择用户安装包');
requireText(bootstrap.includes('Invoke-WithRetry') && bootstrap.includes('Get-FileHash'),
  '固定入口缺少重试或 SHA-256 强校验');
requireText(bootstrap.includes('/releases/latest/download/update.json') && bootstrap.includes('-TimeoutSec 12') &&
  bootstrap.indexOf('/releases/latest/download/update.json') < bootstrap.indexOf('https://api.github.com'),
  '固定入口应优先读取无 API 配额限制的官方索引，网络请求必须有界');
requireText(bootstrap.includes('$release.draft -or $release.prerelease'), '固定入口未拒绝草稿或预发布版本');
requireText(bootstrap.includes('Expand-Archive -LiteralPath'), '固定入口没有安全处理含空格的压缩包路径');
requireText(bootstrap.includes('[switch]$VerifyOnly') && bootstrap.includes('[switch]$NoLaunch') &&
  bootstrap.includes('[switch]$NoShortcuts') && bootstrap.includes('[switch]$NoClipboard'),
  '固定入口缺少无人值守/仅验证参数');
requireText(bootstrap.includes('NoClipboard = [bool]$NoClipboard'), '固定入口没有把无剪贴板模式传给安装器');

const installer = read('Windows/edge-extension/install.ps1');
requireText(installer.includes("GetFolderPath('LocalApplicationData')"), '默认安装位置必须是当前用户目录');
requireText(installer.includes('[switch]$Enterprise') === false, '内层安装器不得暴露管理员策略模式（仅外层引导器可选）');
requireText(!/Start-Process[^\n]+-Verb\s+RunAs/i.test(installer) && !/net\s+session/i.test(installer),
  '默认安装流程不得请求管理员权限');
requireText(installer.includes("[Guid]::NewGuid().ToString('N')") &&
  installer.includes('.edge-extension.new-') && installer.includes('.edge-extension.old-'),
  '安装器必须使用并发安全的同卷暂存/备份目录');
requireText(installer.includes('Test-IsSameOrChildPath $originalLocation $targetRootFull') &&
  installer.includes('Set-Location -LiteralPath $targetRootFull'),
  '安装器未处理从已安装目录内执行更新的 Windows 目录锁');
requireText(installer.includes("$_.Name -ne '_metadata'"), '安装器必须剔除 Edge 的陈旧 _metadata 缓存');
requireText(installer.includes('恢复旧版本') && installer.includes('已保留原版本'), '原子替换失败时缺少回滚');
requireText(installer.includes('FromBase64String') && installer.includes('Get-DerivedExtensionID') &&
  installer.includes('$expectedExtensionID'),
  '安装器必须校验 manifest 公钥确实导出固定扩展 ID');
requireText(installer.includes("'edge-extension-' + $version") && installer.includes("'current.txt'"),
  '安装器必须使用版本化目录 + current.txt 指针（免文件锁更新模型）');
requireText(installer.includes('$shortcut.TargetPath = $powershellPath') &&
  installer.includes('$shortcut.Arguments = $launcherArgs'),
  '快捷方式应指向启动器（每次启动自动检查更新）');
requireText(installer.includes("Join-Path $dir '智囊.lnk'") && installer.includes('Test-ProductShortcut'),
  '安装器必须提供智囊入口，且仅迁移本产品旧快捷方式');
requireText(installer.includes('& $launcherPath'),
  '安装完成后必须直接打开智囊工作台');
requireText(installer.includes('if (-not $NoClipboard)') && installer.includes("Get-Command 'Set-Clipboard'"),
  '安装器必须允许隔离测试禁止写入全局剪贴板');

const launcher = read('Windows/edge-extension/launch.ps1');
requireText(launcher.includes("$extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'") &&
  launcher.includes('chrome-extension://$extensionID/launch.html'),
  '启动器必须指向固定侧载扩展 ID');
requireText(launcher.includes('--load-extension') && launcher.includes('--disable-extensions-except'),
  '启动器必须用命令行加载扩展（免开发者模式、免反复授权）');
requireText(launcher.includes('--user-data-dir'), '启动器必须使用独立 Edge 配置档（保证命令行参数在已运行 Edge 时也生效）');
requireText(launcher.includes("'current.txt'") && launcher.includes("'edge-extension-' + $current"),
  '启动器必须解析版本化安装目录指针');
requireText(launcher.includes('/releases/latest/download/update.json') && launcher.includes('Get-FileHash') &&
  launcher.includes('edgeSHA256'),
  '启动器必须在启动前自动检查更新并强校验 SHA-256');
requireText(launcher.includes('Start-Process -FilePath $edge -ArgumentList $args'),
  '启动器必须直接启动 Edge');
requireText(!launcher.includes('Get-ExtensionRegistration') && !launcher.includes('Secure Preferences'),
  '新启动模型不再依赖开发者模式注册项');

for (const path of ['Windows/edge-extension/install.bat', 'Windows/edge-extension/launch.bat']) {
  const bat = read(path);
  const psName = path.endsWith('install.bat') ? 'install.ps1' : 'launch.ps1';
  requireText(bat.includes(`-File "%~dp0${psName}" %*`), `${path} 未安全传递含空格路径和参数`);
  requireText(/exit \/b %ERRORLEVEL%/i.test(bat), `${path} 未向 Agent 返回真实退出码`);
  requireText(!/\bpause\b/i.test(bat) && !/\btimeout\b/i.test(bat), `${path} 不得阻塞或固定等待`);
}

const workflow = read('.github/workflows/ci.yml');
requireText(workflow.includes('runs-on: windows-latest') && workflow.includes('shell: powershell'),
  'CI 必须使用 Windows PowerShell 5.1 真机解析和安装');
requireText(workflow.includes('测试 用户\\Parallel Workbench'), 'CI 未覆盖中文与空格路径');
requireText(workflow.includes('source-in-target update'), 'CI 未覆盖从安装目录重复更新');
requireText(workflow.includes('Verify bounded fixed bootstrap command') &&
  workflow.includes('--retry-max-time 90 --connect-timeout 10 --max-time 60'),
  'CI 未执行带超时和重试上限的固定下载入口');

for (const path of ['README.md', 'Windows/README.md', 'Windows/edge-extension/README.md',
  'Windows/edge-extension/WINDOWS.md', 'AGENT_INSTALL_PROMPT.md']) {
  const doc = read(path);
  requireText(doc.includes("$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N')") &&
    doc.includes('& curl.exe --fail --location --silent --show-error --retry 3') &&
    doc.includes('--connect-timeout 10 --max-time 60') &&
    doc.includes('releases/latest/download/install-windows.ps1') &&
    doc.includes('& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller'),
  `${path} 未使用可从现有 PowerShell 正确执行的固定 Latest 命令`);
  requireText(!doc.includes('raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install-windows.ps1'),
    `${path} 仍从 main 取引导器，可能与 Latest Release 资产错配`);
  requireText(doc.includes('Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue'),
    `${path} 的固定入口没有清理一次性引导脚本`);
  requireText(!doc.includes('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='),
    `${path} 仍含会被外层 PowerShell 提前展开变量的旧命令`);
}

const releaseScript = read('scripts/make-release.sh');
requireText(/[\"']install-windows\.ps1[\"']/.test(releaseScript) &&
  releaseScript.includes('SHA256 install-windows.ps1'),
  '发布脚本没有把与 Release 同步的 Windows 引导器作为 Latest 资产上传');

if (fail.length) {
  console.error(`❌ Windows 安装契约失败：\n- ${fail.join('\n- ')}`);
  process.exit(1);
}

console.log('✅ Windows 安装契约通过（PS 5.1 编码/最新版/校验/原子安装/路径/启动）');
