# 智囊 · Braintrust 本地工作台分发

本目录提供官网下载包、应用启动器、图标和构建工具。当前产品使用本地 Node 22 服务与独立浏览器 Profile，不要求安装浏览器扩展。工作台已复用原设计的布局和样式，并通过 CDP iframe 桥嵌入各 AI 平台；“仍是极简控制页、尚未移植 UI”是早期状态，已不适用于当前源码。

本文于 **2026-10-26** 同步。历史分发基线是 `release/local-service` 分支提交 `4e621a8`；本轮候选及新增验收工具的执行结果应另以实际构建证明和测试证据为准。

## 安装形式与分发要求

| 平台 | 当前下载包 | 用户入口 |
|---|---|---|
| Windows x64 | `Braintrust-Setup-0.6.0.exe` | 下载 EXE → 安装 → 桌面或开始菜单中的 Braintrust 图标 |
| macOS Apple 芯片 | `Braintrust-0.6.0.dmg` | 打开 DMG → 把「智囊」拖进 Applications → 打开应用 |
| macOS Intel | `Braintrust-0.6.0-intel.dmg` | 使用独立 Intel 包，安装方式相同 |

Windows 采用直接下载 EXE 的路线，不以 Microsoft Store 上架、开发者计划注册或 Windows 代码签名作为交付前提。NSIS 安装器按当前用户安装，默认目录是 `%LOCALAPPDATA%\Braintrust`，提供桌面/开始菜单入口和卸载器。Windows 安全提示仍受系统策略、下载来源和文件信誉影响；未签名安装包不能承诺没有 SmartScreen，也不能把自动化静默安装通过等同于普通用户手动安装通过。

Apple 签名与公证可使用用户现有 Apple Developer 资格继续配置；会员资格不等于本机已有可用证书与公证凭证。本机目前未具备可用的 Developer ID 签名/公证条件，现有 DMG 仍按未公证产物处理。本机移除 quarantine 后能启动，不代表新用户下载后没有 Gatekeeper 提示。

仓库保留 `install.command`、`install.bat` 和 ZIP 分发工具，用于兼容或开发验证；官网下载的主要交互已改为 DMG / EXE。

## 运行架构与数据

```text
源码工作树及完整 commit
  └─ 构建：本地服务 + 设计版工作台 + Node 22 + 平台启动器
       ├─ Windows x64 EXE
       ├─ macOS ARM64 DMG
       └─ macOS Intel DMG

braintrust.chat 静态官网
  ├─ macOS / Windows 独立下载链接 → 阿里云 OSS 加速端点
  └─ /updates/local-service-update.json
GitHub Release：历史安装包备份

用户电脑
  ├─ 本地 Node 服务：127.0.0.1，带 API 令牌
  ├─ 系统 Edge / Chrome / Chromium：产品独立 Profile
  ├─ 工作台：本地页面 + CDP iframe 桥
  └─ 各 AI 平台官方网页：用户自行登录、完成验证并使用
```

安装包内置 Node 22，运行仍需要可用的系统浏览器。独立 Profile 不读取用户日常浏览器的 Cookie，也不承诺继承其登录态。产品本地数据和日志保存在用户目录；向 AI 平台发送的问题与附件仍会进入用户选择的平台。

| 项目 | Windows | macOS |
|---|---|---|
| 数据与浏览器 Profile | `%LOCALAPPDATA%\Braintrust\data` | `~/Library/Application Support/Braintrust/data` |
| 启动日志 | `%LOCALAPPDATA%\Braintrust\logs` | `~/Library/Logs/Braintrust` |

服务写入 `data/service.json`，包含端口、令牌与进程信息。启动器使用它找回已有服务，并通过 `/api/browser/open` 打开工作台；退出入口调用 `/api/quit`。本轮 Windows 生命周期验收还将检查重复启动、重启应用、运行中覆盖安装和卸载后的状态。

## 当前公网下载状态

**2026-10-26 实测：`https://braintrust.chat/` 与官网所用 OSS Windows 安装包端点均返回 HTTP 403，响应含 `UserDisable` 和代码 `0003-00000801`。** 这是当前下载入口的阻断，不能报告“官网下载已通过”。该响应不足以确定具体计费、账户或配置原因，需由 OSS 侧状态进一步确认。

历史 GitHub 备份地址为：

`https://github.com/porcelaintech/parallel-workshop/releases/download/v0.6.0-rc.1/Braintrust-Setup-0.6.0.exe`

- 文件大小：**24,181,479 字节**。
- SHA-256：`5b25f75d70ce9c20c5aa11513048e47af475258b488f8cab5be6463229a5ac65`。

使用备份验证安装器时，应明确标为备份测试，不能据此认定官网已恢复。历史 Release 标签为 `v0.6.0-rc.1`，但该包文件名、运行时版本与旧更新索引字段使用 `0.6.0`；这些身份并不完全一致，应保留原样记录，不能改写历史证据来冒充新候选。

## 本轮 Windows 候选构建

`distribution/scripts/build-windows-candidate.mjs` 用于从明确的干净源码提交构建测试候选，默认完整版本为 **`0.6.0-rc.2.A`**，保留 `0.6.0` 三段基数。它生成安装包和 `build-proof.json`，记录源码 commit、完整候选版本、Node 运行时来源校验值、安装包大小与 SHA-256。候选安装包必须小于 **50,000,000 字节**。

在源码改动已提交、工作树干净，且构建环境已备好 Node 22、NSIS 及解压工具后运行：

```sh
node distribution/scripts/build-windows-candidate.mjs

# 输出目录
# build/windows-acceptance/artifacts/
#   Braintrust-Setup-0.6.0-rc.2.A.exe
#   build-proof.json
```

该脚本只构建，不发布 Release、不上传 OSS、不替换官网链接。测试结论必须绑定实际安装包 SHA-256 与构建证明中的源码 commit；源码变化后重新构建，应使用新的完整候选标识，避免同一名称对应不同产物。

`distribution/scripts/build-release.sh` 仍保留历史双平台构建入口，但其旧版 Release/更新索引约定需要单独复核，不能代替本轮候选证明。尤其旧索引的 `darwin-universal` 实际指向 ARM64 DMG，不能据此认为它适用于 Intel Mac。

## Windows 验收方法与证据边界

历史 `.github/workflows/windows-installer-smoke.yml` 已在 Windows CI 中验证过 GitHub 备份 EXE 的静默安装、安装文件、快捷方式图标、直接运行 PowerShell 启动器、headless Edge/CDP 和静默卸载。它显式传入浏览器路径，没有覆盖真实桌面图标启动、自动发现浏览器、官网浏览器下载或已登录平台使用。

本轮新增工具用于扩大覆盖，**测试结果尚待执行取证，本文不预先宣称通过**：

- `scripts/windows-installed-ui-test.mjs`：面向已安装产品做浏览器交互；支持从官网发现并点击 Windows 下载链接、保存下载证据，以及安装后的工作台 UI、确定性测试页面和持久化检查。
- `scripts/windows-installed-lifecycle-test.ps1`：检查安装器、快捷方式启动、服务与浏览器、应用重启、运行中覆盖安装及卸载；可验证带中文和空格的安装路径。
- `.github/workflows/windows-download-acceptance.yml`：区分当前公网下载、固定哈希历史备份和新候选；在 Windows 2022 / 2025 托管虚拟机中运行，并保留证据。候选测试包括 headless 与有窗口模式，不预设 `BRAINTRUST_BROWSER_PATH`，以覆盖自动寻找浏览器。

确定性测试页面可检查产品输入、发送和附件通道，但不会生成真实 AI 回答。未登录真实官网的探针可记录页面和登录状态，也不能代替登录后问答。Windows 托管虚拟机测试不是消费者 Windows 10/11 的物理桌面测试；静默安装也不会覆盖安装向导、SmartScreen 或用户手动放行体验。

## 尚未完成的验证与优化

- 恢复并复核官网与 OSS 下载入口，确认浏览器点击能完整下载且哈希匹配。
- 执行本轮候选安装、图标启动、UI、应用重启、覆盖安装和卸载测试，逐项记录结果。
- 六平台真实账号的登录、发送、回答与附件矩阵；当前历史证据主要是 probe，DeepSeek 登录页的 `NO_INPUT` 不能算发送成功。
- 消费者 Windows 10/11 的首次安装、SmartScreen 与手动交互。
- Windows 系统重启后的启动、会话保持及代理环境行为；应用进程重启不能替代操作系统重启。
- 自动更新下载后的安装替换与重启；目前“检查/下载”不等于自动更新闭环。
- Apple Developer ID 签名、公证及新下载用户的首次打开验证。

## 主要目录

```text
distribution/
  macos/build-dmg.sh                 ARM64 / Intel DMG
  macos/launcher.sh                  macOS 应用启动器
  windows/installer.nsi              Windows 按用户安装与卸载
  windows/build-installer.sh         NSIS 构建入口
  windows/launcher.vbs               无控制台启动入口
  windows/launcher.ps1               服务启动、浏览器发现与找回
  windows/stop.ps1                   停止已安装服务
  scripts/build-windows-candidate.mjs 候选构建与来源证明
  scripts/build-release.sh           历史双平台构建入口
  assets/                           应用图标
  spike/                            早期可行性实验
```

官网源码在 `website/`；平台页面及注入核心在 `Sources/WorkbenchCore/Resources/`，本地服务和设计版工作台在 `local-service/`。其他历史说明如与当前源码不一致，应以实际安装包、来源证明及本次验证记录为准。
