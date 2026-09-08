# 智囊 · Braintrust — Windows/Edge 版

v0.4.0 是当前稳定版。

> 本目录是 **Windows 产品入口**。macOS 用户请使用仓库根目录下 `macOS/` 目录（或直接执行 `install.sh`）。

一条 PowerShell 命令安装最新稳定版，之后从桌面「智囊」打开。让 Agent 安装时，复制 [Windows 极简 Prompt](../AGENT_INSTALL_PROMPT.md#windows--复制以下整段)，无需先准备开发环境。

智囊将 ChatGPT、DeepSeek、豆包、Kimi、通义千问和文心一言放进同一个窗口；一个输入框向选中的模型同步提问。

## 从 GitHub 一键安装最新版

在 PowerShell 中直接执行下面整行（不要再次包进 `powershell.exe -Command`）：

```powershell
$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { & curl.exe --fail --location --silent --show-error --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 'https://github.com/porcelaintech/parallel-workshop/releases/latest/download/install-windows.ps1' --output $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "安装器下载失败（curl 退出码 $LASTEXITCODE）" }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller; if ($LASTEXITCODE -ne 0) { throw "智囊安装失败（退出码 $LASTEXITCODE）" } } finally { Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue }
```

命令自动下载、校验和安装，并创建桌面与开始菜单快捷方式。首次在打开的 Edge 扩展管理页启用「开发人员模式」，选择「加载解压缩的扩展」，粘贴安装器给出的路径即可。

## 平时怎样打开

双击桌面「智囊」，或在 Windows 开始菜单搜索「智囊」。会直接打开带加载提示的启动页，准备完成后进入工作台；无需每次去浏览器右上角的拼图菜单找扩展。浏览器工具栏入口仍可使用。

## 怎样更新

顶部 `Update` 随时可检查更新：没有新发布时显示「已是最新版」，网络异常会显示具体原因与重试入口。发现新版后下载并校验 ZIP，按提示解压、运行其中的 `install.bat`；也可重新执行上面同一条安装命令。

安装器替换本产品的旧程序文件，保留登录和使用偏好。更新后从桌面「智囊」打开，启动页核对已安装版本与 Edge 实际加载的版本；仍在运行旧版时会重新加载本扩展以启用新版。

## 产品形态对照

| 平台 | 形态 | 登录态 |
|---|---|---|
| macOS | 原生应用（SwiftUI + WKWebView） | 应用内独立 WebKit 持久存储 |
| **Windows** | **Edge 扩展（MV3，本目录）** | **继承 Edge 浏览器** |

两者共用同一套适配器/注入核心（`Sources/WorkbenchCore/Resources/` → `scripts/build-edge-extension.sh` 同步）。

当前内置平台：ChatGPT、DeepSeek、豆包、Kimi、通义千问、文心一言。

## 在 Windows 上安装（开发者模式侧载）

1. 把整个 `edge-extension/` 目录复制到 Windows 机器（或解压 `build/edge-extension.zip`）
2. 打开 Edge，地址栏输入 `edge://extensions`
3. 打开左下角「开发人员模式」开关
4. 点「加载解压缩的扩展」→ 选择 `edge-extension` 目录
5. 正常安装后双击桌面「智囊」打开；源码手动侧载也可使用扩展工具栏入口

> 日常使用前：先在 Edge 里正常登录各平台（chat.deepseek.com / doubao.com / kimi.com 等），扩展里的 pane 直接继承这些登录态。

## 自动测试（已在 Mac 上的 Edge 真机通过）

`scripts/edge-e2e.mjs` 在真实 Edge 中验证：UI 对齐（勾选框/按宽度显示1–3窗格/分页）、探测链路（状态角标真实更新）、发送链路（问题真实进入平台对话区并得到回答）。逐项结论：

- [x] 扩展加载、工作台窗口打开
- [x] 各平台 iframe 嵌入（CSP 剥离规则生效）
- [x] 勾选框交互（取消勾选即隐藏）与「1-3 / 6」分页
- [x] 状态角标（就绪/未登录/未找到输入框/无响应）
- [x] 统一输入 → 注入发送 → 平台对话区出现消息气泡

**快捷方式**：install.bat 创建「桌面 + 开始菜单」的「智囊」快捷方式，先打开本地 `start.html` 显示加载状态，扩展就绪后在同一窗口进入版本核对页和工作台。无需添加固定的空白页预热等待。

## 首次实测清单（在 Windows Edge 上逐项确认）

- [ ] 扩展加载无报错（edge://extensions 无红色错误）
- [ ] 各平台 pane 能嵌入显示（CSP 剥离规则生效）
- [ ] 登录态继承（Edge 里已登录的平台 pane 内免登录）
- [ ] 统一输入 → 各 pane 注入发送 → 回答生成
- [ ] 状态角标与发送反馈正常

## 附件（多模态）通道设计

发送带附件的问题时，按平台选择注入通道（**互斥，杜绝双重注入**），并做接受度验证 + 诚实降级：

| 通道 | 适用平台 | 原理 | 状态 |
|---|---|---|---|
| 文件输入框赋值 | 适配器配置了选择器（Kimi `input.hidden-input`、ChatGPT `input.wm-composer-srOnly`）；无选择器时自动兜底页内任一 file input（含隐藏） | 隔离世界重建 File → `input.files = dt.files` → change 事件 → 平台原生上传管线 | ✅ 已实测：ChatGPT 附件 chip 出现；Kimi 赋值成功 |
| CDP 拖放（WB_ATTACH） | 无文件输入框的平台（DeepSeek/通义/文心） | 页面侧计算坐标（iframe 框 × CSS zoom + 帧内编辑器中心）→ chrome.debugger `Input.dispatchDragEvent` 在页面坐标派发（命中测试跨 OOPIF 投进对应帧） | ⚠️ 尽力而为 |

- **CDP 拖放的平台限制**：`DragData.files` 要求磁盘文件路径，扩展无文件系统权限 → 只能投递 MIME 数据（`types=['image/png']` 而非 `'Files'`）；严格检查 File 类型的平台（如文心）会拒绝 → 工作台诚实提示「附件未被平台接受，请手动添加」
- **Edge 152 注意**：`Page.getFrameTree` 对 chrome-extension 页面里的跨域 iframe（OOPIF）不返回子帧 → CDP 帧树发现不可用，必须用 `webNavigation.getAllFrames` + 坐标命中
- 接受度验证：内容脚本 `WB_ATTACH_CHECK`（隔离世界可读宿主 DOM，检查文件名是否出现在页面）
- 逐平台矩阵测试：`scripts/edge-attach-matrix.mjs`（通道级验证，不发送真实消息；`--full` 才做全平台真实发送）

## 扩展开发/测试陷阱

- **扩展重新加载**：仅刷新网页不会重新加载后台或 manifest。安装新包后，从桌面启动页确认实际版本；若仍为旧版，在 `edge://extensions` 对「智囊」点击「重新加载」。不要删除 Edge profile 的 `Service Worker`、`Extension State` 或 `Extension Scripts`，这些目录属于整个浏览器配置，可能影响其他扩展。
- **重定向域名**：帧 URL 与适配器 origin 可能不同（tongyi.com → qianwen.com、yiyan → wenxin），帧匹配必须用 homeHosts 兜底

## 登录围栏与 DeepSeek 微信回调

- 平台 iframe 保持 sandbox，禁止认证子帧导航整个工作台。
- DeepSeek 微信授权完成后，`intercept.js` 捕获微信 QR 页产生的 callback 候选；`auth-bridge.js` 与后台分别验证微信来源、DeepSeek HTTPS origin、固定 callback path 和 code 长度，最终只导航 DeepSeek pane。
- 问答注入/探测不再使用页面可见的 `postMessage` token，而是通过 `chrome.tabs.sendMessage` 直接投递到扩展隔离世界。
- DNR 规则与 host_permissions 需覆盖认证域名（appleid.apple.com / auth.openai.com / open.weixin.qq.com / passport.baidu.com 等），否则认证页在帧内被 X-Frame-Options 拦截
- 已实测：DeepSeek「使用 Apple 账号登录」→ 无新开标签页，Apple 认证页在帧内完整渲染 ✅

## 已知差异与注意

- ChatGPT 等国际平台：走 Edge 自身网络环境（你的代理），扩展不提供任何代理能力
- 游客模式平台（ChatGPT/文心）：未登录也能问答，登录后功能完整
- 若某平台 pane 空白：先在该平台官网正常访问一次确认网络可达，再刷新 pane

## 后续路线

2026-09-08 起，下一正式版的发行方向调整为 **Windows 原生应用 + MSIX + Microsoft Store 管理安装和更新**。现有扩展仍为当前稳定版；新增的 [原生验证工程](native-preview/README.md) 用于验证三窗格、会话与打包，不是完整产品。

原生应用使用自己的 WebView2 数据目录和按平台隔离的 profile，不复用或读取 Edge 浏览器的用户目录，也不承诺自动继承浏览器登录态。需要在新应用中验证各服务支持的登录方式和重启后的会话保持。

整体阶段、Mac 路线、缺少 Windows 终端时的构建与实测边界见 [原生应用与商店发行推进](../docs/native-store-release-plan.md)。
