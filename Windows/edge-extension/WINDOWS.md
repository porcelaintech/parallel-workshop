# 智囊 · Braintrust — Windows 安装与使用

v0.4.1 是当前稳定版。

下面的固定命令自动获取 GitHub 最新稳定版。让 Agent 帮忙安装时，复制[Windows 极简 Prompt](https://github.com/porcelaintech/parallel-workshop/blob/main/AGENT_INSTALL_PROMPT.md#windows--复制以下整段)，直接使用本机 PowerShell 即可。

本版（v0.4.1）彻底重构 Windows 分发与更新：

- **免开发者模式**：扩展不再需要「开发人员模式 + 加载解压缩扩展」。安装后通过桌面/开始菜单「智囊」图标启动，启动器用独立 Edge 配置档 + `--load-extension` 命令行加载扩展（Edge 全平台保留该能力），因此没有启动骚扰条、没有反复授权。
- **每次启动自动更新**：启动器先读取官方发布索引 `update.json`（SHA-256 强校验 + 扩展 ID 校验），发现新版先下载安装再打开工作台，全程无感；版本化安装目录保证运行中的旧版文件不被覆盖。
- **更新按钮**：工作台顶部仍固定显示版本与 `Update` 状态（已是最新 / 发现新版）。发现新版时重启智囊（桌面图标）即自动完成更新；也可点击下载更新包作为手动兜底。
- **一次性引导**：首次启动展示引导页（工具栏固定教程、登录说明、旧版清理提示），只出现一次。
- **企业模式**：已加入 AD 域的 Windows 可用 `-Enterprise` 安装，一次性 UAC 授权写入 Edge 策略后，Edge 自动安装并持续自动更新官方签名 CRX（`updates.xml`）。
- **权限最小化**：移除了 `debugger` 与 `activeTab`，只保留 declarativeNetRequest、storage、scripting、webNavigation。

> 旧版（≤ v0.4.0，开发者模式安装）用户：请用上面的安装命令重装一次。重装后若 `edge://extensions` 里还有旧「智囊」条目（显示损坏），点移除即可（仅一次）。

## 产品形态对照

| 平台 | 形态 | 登录态 |
|---|---|---|
| macOS | 原生应用（SwiftUI + WKWebView） | 应用内独立 WebKit 持久存储 |
| **Windows** | **Edge 扩展（MV3，本目录）** | **智囊自己的 Edge 配置档（`%LOCALAPPDATA%\ParallelWorkbench\EdgeProfile`）** |

两者共用同一套适配器/注入核心（`Sources/WorkbenchCore/Resources/` → `scripts/build-edge-extension.sh` 同步）。

当前内置平台：ChatGPT、DeepSeek、豆包、Kimi、通义千问、文心一言。

## 一键安装最新稳定版

请在 PowerShell 中直接执行下面整行，不要再次包进 `powershell.exe -Command`。

```powershell
$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "智囊安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
```

安装器会自动完成版本查询、重试下载、SHA-256 校验、解压、原子复制与快捷方式创建，不需要管理员权限，也不会等待“按任意键”而卡住 Agent。

## 安装后如何使用

1. 双击桌面或开始菜单的「智囊」图标即可打开工作台（首次展示一次性引导页）
2. 首次使用请在智囊窗口内的各 pane 登录对应平台（登录态保存在智囊自己的配置档里，之后一直记住；更新不会影响登录）
3. 也可以把 Edge 工具栏里的智囊图标固定：点右上角拼图 → 找到智囊 → 点图钉

> 注意：请始终通过「智囊」图标启动。直接打开 Edge 不会加载智囊扩展（这是免开发者模式设计的代价，换来零骚扰条与零反复授权）。

### 开发者自测（加载仓库内未打包扩展）

```bash
bash scripts/build-edge-extension.sh
# 测试用 Edge 实例：
"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"   --user-data-dir=/tmp/wb-edge-live   --disable-extensions-except="$(pwd)/Windows/edge-extension"   --load-extension="$(pwd)/Windows/edge-extension"   --remote-debugging-port=9223 --no-first-run --no-startup-window &
node scripts/edge-e2e.mjs
node scripts/edge-attach-matrix.mjs
```

## 自动测试（已在 Mac 上的 Edge 真机通过）

`scripts/edge-e2e.mjs` 在真实 Edge 中验证：UI 对齐（勾选框/按宽度显示1–3窗格/分页）、探测链路（状态角标真实更新）、发送链路（问题真实进入平台对话区并得到回答）。逐项结论：

- [x] 扩展加载、工作台窗口打开
- [x] 各平台 iframe 嵌入（CSP 剥离规则生效）
- [x] 勾选框交互（取消勾选即隐藏）与「1-3 / 6」分页
- [x] 状态角标（就绪/未登录/未找到输入框/无响应）
- [x] 统一输入 → 注入发送 → 平台对话区出现消息气泡

**快捷方式**：install.bat 创建「桌面 + 开始菜单」的「智囊」快捷方式，先打开本地 `start.html` 显示加载状态，扩展就绪后在同一窗口核对版本并进入工作台。已有「平行工作台」快捷方式也会更新到同一入口。

## 实测清单（GitHub Actions windows-latest 真机 Edge 逐项确认）

- [x] 扩展用 `--load-extension` 加载无报错（免开发者模式，决定性 live test：`scripts/windows-edge-live-test.mjs`）
- [x] 首次启动展示一次性引导页，点击后进入工作台（6 窗格、正确版本、零 blank/错误页）
- [x] 冷重启直达工作台，引导不再出现，扩展本地存储与登录配置持久
- [x] 各平台 pane 能嵌入显示（CSP 剥离规则生效）
- [x] 状态角标（就绪/未登录/未找到输入框/无响应）与统一输入注入发送链路
- [x] 附件双通道（文件输入框赋值 + 帧内主世界拖放）派发成功
- [x] 安装器幂等重装、版本化目录回滚、旧版目录迁移、启动器自动更新（`scripts/windows-installer-behavior-test.ps1`）
- [x] 企业模式在未加域机器上按官方约束明确拒绝（不写入任何文件）

## 附件（多模态）通道设计

发送带附件的问题时，按平台选择注入通道（**互斥，杜绝双重注入**），并做接受度验证 + 诚实降级：

| 通道 | 适用平台 | 原理 | 状态 |
|---|---|---|---|
| 文件输入框赋值 | 适配器配置了选择器（Kimi `input.hidden-input`、ChatGPT `input.wm-composer-srOnly`）；无选择器时自动兜底页内任一 file input（含隐藏） | 隔离世界重建 File → `input.files = dt.files` → change 事件 → 平台原生上传管线 | ✅ 已实测：ChatGPT 附件 chip 出现；Kimi 赋值成功 |
| 帧内主世界拖放 | 无文件输入框的平台（通义/文心） | `chrome.scripting.executeScript(world:'MAIN')` 把自包含拖放函数注入目标帧：主世界构造真实 `File` + `DataTransfer`，在帧内编辑器中心派发 dragenter/dragover/drop | ✅ 已实测：帧内 drop 事件 3 连发成功 |

- **为什么不是 CDP**：旧版用 `chrome.debugger` 的 `Input.dispatchDragEvent`，每次投递都会弹「已开始调试此浏览器」横幅，且 `debugger` 权限在商店审核是重灾区 → v0.4.1 移除该权限，改为主世界合成拖放（站点拿到的 `dataTransfer.files` 与用户真实拖放等价，同为不可信事件）。
- **主世界无扩展 API**：MAIN world 内容脚本里没有 `chrome.runtime`，必须由工作台 `chrome.scripting` 注入函数执行（自包含、参数可序列化）。
- 接受度验证：内容脚本 `WB_ATTACH_CHECK`（隔离世界可读宿主 DOM，检查文件名是否出现在页面）
- 逐平台矩阵测试：`scripts/edge-attach-matrix.mjs`（通道级验证，不发送真实消息；`--full` 才做全平台真实发送）

## 扩展开发/测试陷阱

- **扩展重新加载**：更新文件后仅刷新网页不会重新加载后台或 manifest。启动页会核对运行版本；仍为旧版时，在 `edge://extensions` 对「智囊」点击「重新加载」。不要删除 Edge profile 的 `Service Worker`、`Extension State` 或 `Extension Scripts`，这些目录属于整个浏览器配置，可能影响其他扩展。
- **重定向域名**：帧 URL 与适配器 origin 可能不同（tongyi.com → qianwen.com、yiyan → wenxin），帧匹配必须用 homeHosts 兜底

## 登录围栏与 DeepSeek 微信回调

- 平台 iframe 保持 sandbox，禁止认证子帧导航整个工作台。
- DeepSeek 微信授权完成后，认证桥严格校验 `open.weixin.qq.com` 来源与 DeepSeek callback 白名单，只导航 DeepSeek pane。
- 问答注入/探测通过 `chrome.tabs.sendMessage` 直达隔离 content script，页面主世界无法读取或伪造回执。
- DNR 规则与 host_permissions 需覆盖认证域名（appleid.apple.com / auth.openai.com / open.weixin.qq.com / passport.baidu.com 等），否则认证页在帧内被 X-Frame-Options 拦截
- 已实测：DeepSeek「使用 Apple 账号登录」→ 无新开标签页，Apple 认证页在帧内完整渲染 ✅

## 已知差异与注意

- ChatGPT 等国际平台：走 Edge 自身网络环境（你的代理），扩展不提供任何代理能力
- 游客模式平台（ChatGPT/文心）：未登录也能问答，登录后功能完整
- 若某平台 pane 空白：先在该平台官网正常访问一次确认网络可达，再刷新 pane

## 后续路线

1. **上架 Microsoft Edge 加载项商店**（正式分发，无需开发者模式）：按微软商店审核要求补充隐私说明等材料
2. **（可选）Windows 原生应用**：Edge WebView2（`CoreWebView2Environment` 指向 Edge 用户数据目录可继承 Edge 登录态，但有"Edge 需先关闭/独立配置目录"的限制）；工程量大，仅在扩展形态不能满足时考虑
3. 平台改版导致适配器失效：改 `lib/adapters/*.json`（或同步回 macOS 侧统一改），重新加载扩展即可
