# 智囊 · Braintrust

一次提问，多位 AI 并排回答。智囊（原「平行工作台」）把 ChatGPT、DeepSeek、豆包、Kimi、通义千问和文心一言放进同一个工作区。

- [Windows 安装与打开](Windows/README.md)：一条 PowerShell 命令，之后从桌面「智囊」启动。
- [macOS 安装与打开](macOS/README.md)：一条终端命令安装原生应用。
- [复制给 Agent 的极简安装 Prompt](AGENT_INSTALL_PROMPT.md)：按平台直接执行官方命令。

## v0.4.1 更新

v0.4.1 是当前稳定版。一键安装入口始终获取最新稳定 Release。

- **更新按钮修复**：修复仓库更名（`HanchengQiao/parallel-workshop` → `porcelaintech/parallel-workshop`）导致的更新断链。macOS 更新检查现按「官方 API → 发布索引 → CDN 镜像 → 历史仓库名索引」多级回退，任何点击都有明确反馈，失败时提供「前往下载页」直达入口。**v0.4.0 及更早版本无法自助更新，请用上方安装命令重装一次 v0.4.1，之后更新按钮恢复可用。**
- **Windows 免开发者模式、免反复授权**：彻底移除 `debugger` 权限（附件投递改用帧内主世界合成拖放，不再弹「已开始调试此浏览器」），并弃用「开发者模式 + 加载解压缩扩展」。安装后通过桌面/开始菜单「智囊」图标启动，Edge 用独立配置档 + 命令行加载扩展：不再有启动骚扰条，也不需要任何反复授权。
- **Windows 每次启动自动更新**：启动器先校验官方发布索引（SHA-256 强校验）再打开工作台，更新全程无感。
- **入口更显眼**：安装后自动创建桌面与开始菜单「智囊」入口；首次打开展示引导页（工具栏固定教程 + 登录说明 + 旧版清理提示），只出现一次。
- **企业模式（可选）**：已加入 AD 域的设备可用 `-Enterprise` 安装，一次性管理员授权后由 Edge 策略自动安装并持续自动更新官方签名 CRX。
- **权限最小化**：manifest 权限从 6 项减到 4 项（去掉 `debugger`、`activeTab`），商店包同步精简。

---

顶部统一输入框一键同步发送（macOS ⌘↩ / Windows Ctrl↩），回答保留各平台的原生界面。

## 核心设计

- **不调 API、无付费依赖**：嵌入各平台官方网页客户端
- **登录态持久（应用内）**：macOS 版使用应用自带的 WebKit 持久存储（`~/Library/WebKit/ParallelWorkbench`），登录请在工作台窗格内完成（登录围栏保证不出框），每个平台登录一次后持久；Windows/Edge 版使用智囊自己的 Edge 配置档（`%LOCALAPPDATA%\ParallelWorkbench\EdgeProfile`），登录状态与更新互不影响，首次使用请在智囊窗口内登录一次
- **登录态备份/恢复**：`--backup-auth` / `--restore-auth`，防应用存储损坏/系统重装导致全部登录失效（已实战验证）
- **使用习惯持久化**：双端记住平台勾选、分页位置和逐平台缩放；DeepSeek 额外按稳定 `model_type` 记住上次模型，并在新会话重置后恢复
- **脱离谷歌生态**：macOS 原生 SwiftUI 应用；Windows 侧后续走 Edge 扩展（微软生态），共享本仓库 adapter/injection 核心
- **不提供代理服务**：国际平台走用户系统里已有的代理环境
- **风险管控**：不自动化任何登录/验证流程（人工在 pane 内完成）；注入只做「定位输入框→设值→发送」，不轮询、不自动重试

## 安装

用户可从 GitHub 最新稳定 Release 安装：

让 Agent 帮忙安装时，直接复制[对应平台的 Prompt](AGENT_INSTALL_PROMPT.md)；安装器已负责版本查询、下载与校验。

```sh
# macOS：从最新稳定 Release 下载、强制校验 SHA-256 后原子安装
curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash
```

```powershell
# Windows：在 PowerShell 中直接执行，自动获取最新稳定版
$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "智囊安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
```

> 未签名开源分发：install.sh 校验 GitHub 资产摘要后安装并移除隔离属性；正式对外分发仍建议签名公证。npm 包和 Homebrew tap 尚未发布，因此不再宣传对应命令。

安装过程中遇到等待或报错，可按[安装耗时反馈](INSTALL_FEEDBACK.md)提供最后一步输出。

## 运行（开发者）

```sh
cd parallel-workshop
swift build && open -n .build/arm64-apple-macosx/debug/ParallelWorkbench
# 或 swift run ParallelWorkbench
```

每个 pane 有独立标题栏：平台名、文字状态角标、放大/缩小按钮、刷新按钮和发送结果反馈；工作台外壳只使用暖白、石墨、鼠尾草三色，通过明度、描边和文案区分状态。

## 无人值守验收测试

```sh
swift run WorkbenchTester [--probe-only] [--only=id1,id2] [--cookies] [--backup-auth] [--restore-auth] [问题文本]
```

- 默认对全部平台：加载官网 → 输入框就绪 → 自动注入发送 → 取证（消息气泡/输入框清空/回答标志/回答原文）+ 截图到 `test-output/`
- `--probe-only`：只取证不发送（输入框候选/全部按钮/登录入口/编辑器结构/链接清单/页面文本）
- `--only=deepseek,kimi`：只测指定平台；`--cookies`：各平台登录 cookie 审计
- `--attach=文件路径 --attach-only`：附件接受度验收（注入附件不发送，取证输入框状态/文件名是否出现在页面）——macOS 侧逐平台附件矩阵
- Edge 侧逐平台附件矩阵：`node scripts/edge-attach-matrix.mjs [扩展ID] [--full]`（--full 才做全平台真实发送）

**⚠️ 运营规则：测试器与 GUI 同名（ParallelWorkbench）共享 WebKit 数据目录，禁止并发运行**（测试器有单实例守护自动拒绝）。先退 GUI 再跑测试，测完再启 GUI。

## 验收记录（自动测试）

| 平台 | 状态 | 发送机制 | 证据 |
|---|---|---|---|
| DeepSeek | ✅ 通过 | 合成回车 | 输入框清空、回答"我是DeepSeek，随时为你答疑解惑。" |
| 豆包 | ✅ 接入（未登录探测） | 点击 `button#flow-end-msg-send` | Edge iframe 注入生效，未登录角标正确 |
| Kimi | ✅ 通过 | 点击 `div.send-button-container` | 输入框清空、回答"我是Kimi，由月之暗面开发的AI助手。" |
| ChatGPT | ✅ 通过（游客） | 点击 `button[aria-label='Send message']` | 回答标志"ChatGPT said"出现 |
| 通义千问 | ✅ 通过 | 预动作「新建对话」+ 指针事件序列点发送 | 消息气泡 + 自动会话标题 |
| 文心一言 | ✅ 通过（游客模式） | 合成回车 | 输入框清空、回答"我是百度自研的文心助手，随时为你服务~" |

## 结构

```
Sources/
├── WorkbenchCore/              # 核心库（GUI 与测试器共享）
│   ├── Adapter.swift           # 适配器模型（input/send/probe/verify/prepare）
│   ├── InjectionScripts.swift  # 脚本模板加载与 __CFG__ 注入
│   ├── PaneController.swift    # WKWebView 注入引擎、状态探测、测试辅助
│   ├── Resources.swift         # 资源根目录多路回退定位
│   └── Resources/
│       ├── adapters/*.json     # 每平台一份适配器配置
│       └── injection/*.js      # 纯 JS 注入/探测核心（异步，适配 React/Slate/Lexical）
├── ParallelWorkbench/          # macOS GUI 应用（SwiftUI）
└── WorkbenchTester/            # 无人值守验收测试器（CLI）
```

## 适配器 schema

```jsonc
{
  "id": "tongyi",
  "name": "通义千问",
  "origin": "https://www.tongyi.com/qianwen/",
  "input": { "selectors": ["CSS 或 xpath: 前缀的 fallback 链"] },
  "send": {
    "type": "enter|button|pointer|paragraph|combo",
    "selectors": ["发送按钮 fallback 链（button/pointer/combo 用）"]
  },
  "probe": { "loggedOut": [], "loginModal": [], "challenge": [] },
  "verify": { "responseIndicator": "回答标志文本（发送后不清空输入框的平台用）" },
  "prepare": { "clickSelector": "发送前预动作（如点「新建对话」）", "waitSeconds": 3 },
  "international": false
}
```

## Windows/Edge 扩展

Edge/Chrome MV3 扩展位于 `Windows/edge-extension/`，复用同一套 adapter/注入核心（`scripts/build-edge-extension.sh` 同步）。Edge 开发者模式「加载解压缩的扩展」即可安装。详见 `Windows/edge-extension/README.md`。

## 打包

```sh
bash scripts/package-app.sh   # 生成 build/ParallelWorkbench.app（未签名）
```

签名 + 公证（对外分发，需 Apple 开发者账号）：`codesign --deep --force --sign "Developer ID" build/ParallelWorkbench.app && xcrun notarytool submit ...`

## 多模态与语音

- **附件（文件/图片）**：输入框下方附件栏（选择/拖放/⌘V 粘贴图片），随问题发送给所有勾选平台；自动注入按平台选择通道，并做接受度验证与诚实降级：
  - **Kimi ✅**：文件进入解析管线（macOS 实测上传卡「wb-tiny Parsing failed」）；**ChatGPT ✅**：文件进入上传管线（Edge 实测附件 chip 出现）
  - **DeepSeek ⚠️**：赋值成功但平台未展示上传卡（疑似要求真实用户手势）；**通义/文心 ❌**：无 file input 且拒绝合成拖放 → 提示「请手动添加」
  - 通道机制：有文件输入框的平台走 `input.files` 原生上传管线；其余走 CDP 拖放（尽力而为——扩展无文件系统权限，CDP 只能投递 MIME 数据，无法构造真实 File）
- **语音输入**：macOS 使用系统 `SFSpeechRecognizer`，Edge 使用 Web Speech API；是否完全在设备端处理取决于系统、语言与浏览器能力。点击 🎤 开始，实时转写进输入框，再点一次结束
- 首次使用语音：macOS 需授权麦克风与语音识别（系统设置 → 隐私与安全性）

## 版本更新

- **双端入口与状态**：顶部固定显示 `Update` 和当前版本；启动、回到前台及每 6 小时自动检查。已是最新版时明确提示；网络超时或服务错误显示原因并支持重试。GitHub API 受限或暂时不可用时使用 Release 的 `update.json` 备用索引。
- **macOS**：发现新版后点击 `Update`，下载 DMG → 强制校验 SHA-256 → 安装 → 等待旧进程退出 → 重启新版（仓库可通过环境变量 `PWB_REPO` 配置）
- **Edge 扩展**：GitHub 侧载渠道精确下载 `edge-extension.zip` 并校验 SHA-256，随后按提示运行新版 `install.bat`。从桌面「智囊」打开时，启动页核对实际运行版本；若 Edge 仍加载旧版，会重新加载本扩展并启用已安装新版。商店渠道由浏览器管理安装与重载
- **固定安装入口**：macOS `install.sh` 与 Windows `install-windows.ps1` 都从 Latest 稳定 Release 获取版本，不再把版本号写进用户命令

## 已知限制与后续

- 文心一言 / DeepSeek 登录：用户回来后各扫码一次（角标与引导已就绪）
- 应用数据目录损坏/重装系统 → 用 `--restore-auth` 一键恢复
- 平台改版导致选择器失效 → 配置外置，测试器取证输出可直接用于修复
- Edge 扩展真机加载测试：本机 Chrome 151 官方版已移除 `--load-extension` 命令行能力，需在 Edge/Chrome 开发者模式手动加载后实测
