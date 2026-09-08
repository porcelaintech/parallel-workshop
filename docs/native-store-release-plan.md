# 智囊原生应用与商店发行推进

更新日期：2026-09-08。本文记录发行方向、工程验证边界与进入下一阶段所需条件；不代表产品已通过商店审核。

## 当前决策

| 平台 | 原生应用方向 | 发行与更新方向 | 首个验证目标 |
| --- | --- | --- | --- |
| macOS | 保留 SwiftUI、AppKit、WKWebView，新增独立商店构建 | Mac App Store 安装和更新；站外发行保留独立渠道 | 可重复构建和 Archive，商店包排除自安装更新代码，验证沙盒中的实际功能 |
| Windows | 新增 WinUI 3、WebView2 原生验证工程 | MSIX 安装包，最终由 Microsoft Store 分发和更新 | 三个网页窗格、持久会话、可安装和升级的包；在 Windows 环境验证 |

原生应用负责窗口、生命周期、会话存储、文件访问及故障恢复；商店负责正式发行和版本更新。第三方网页仍由各服务方维护，网页改版、登录限制和上传权限变化仍需我们验证和适配。原生化不能作为这些兼容性问题已被修复的依据。

Windows 选择 MSIX 的原因是让 Store 管理更新。传统 EXE/MSI 即使列入 Microsoft Store，已安装应用的更新仍由开发者负责，不符合本次减少自维护更新链路的主要目标。[微软发行路径比较](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path)

## 已核实的起点

- 源码基线：`338a2fbd6c829a7690d852c9b318fae0db471d29`，对应 `main` 与 `v0.4.0`；2026-09-08 查询远端 `main` 与此一致。
- 原 Mac 工程是 SwiftPM 原生应用，通过脚本拼装 `.app`；既有签名脚本用于站外 Developer ID 签名与公证，不是 Mac App Store 提交链路。
- 原 Windows 工程是 Edge 扩展，已有的 Edge Add-ons 包和安装器不等于 Windows 原生程序或 Microsoft Store 的 MSIX 包。
- 原 Mac 包的 Bundle ID 为 `ParallelWorkbench`、build 固定为 `1`；启用沙盒及正式应用身份后，需要单独验证用户数据与网页登录状态的迁移。
- 当前有可用的 Xcode 26.6、Swift 6.3.3、XcodeGen 2.46.0。此前 tune Translate 是 iOS 工程，可复用通用构建工具和配置组织方式，不能复制其应用身份和 iOS 权限给本产品。
- 用户确认尚无 Apple/Microsoft 商店开发者账户，也没有 Windows 终端。当前工作不包含开户、付费资源创建或商店提交。
- 用户报告的“3.0.0 更新按钮不可用”仍作为原始故障记录保留；当前源码与本机安装显示 `0.4.0`，尚不能将二者视作同一受影响包或宣称已定位根因。

## 第一阶段：无需商店账户的工程准备

### Mac 商店构建

独立的 macOS application target 应复用现有业务代码，具有固定可配置的版本与 build、应用资源、沙盒权限以及 Archive scheme。开发验证使用明确的占位身份；正式发行必须换成发行主体拥有并注册的应用身份。

商店构建必须排除 GitHub 版本轮询、下载 DMG、运行替换应用脚本和旧版重启更新链路，不能仅隐藏按钮。更新入口应准确说明由 App Store 管理；未取得 Store 应用编号时，不应伪造商店链接或显示“已是最新版”。Mac App Store 要求沙盒及商店分发更新。[Apple 沙盒配置](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) · [审核指南 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

验证结果应分开记录：

1. 无签名编译通过：只证明工程和代码可编译。
2. 无签名 Archive 与包结构检查通过：只证明归档中包含正确应用及资源。
3. 带沙盒权限的本地开发签名运行通过：验证受系统限制后的网络、文件、语音、网页登录和会话保持。
4. 商店分发签名、Validate、TestFlight 与 App Review：依赖真实账户、应用身份、签名和审核材料。

前两项不能代替后两项。

### Windows 原生验证工程

首个样机用于验证“能否可靠运行及发行”，暂不把已有扩展的自动发送和附件注入直接搬入新宿主。保留三窗格和实际服务网页，为登录、原生文件选择、重新打开应用后会话保留提供测试载体。各平台会话使用稳定且独立的 profile；不得假定 Edge 浏览器的登录状态会自动迁入。[WebView2 多 profile](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/multi-profile-support)

本地开发包身份仅用于测试。Microsoft Store 正式包的 Identity、Publisher 等必须来自 Partner Center。Store 对通过认证的 MSIX 重新签名，因此仅走该渠道无需先购买第三方公信签名证书；商店之外的 MSIX 分发仍有自己的签名要求。[MSIX 包与签名要求](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)

Windows 缺少终端时分两步处理：

- **云端构建**：准备 GitHub Actions Windows runner 工作流，编译项目并保存包和构建日志。文件存在不代表工作流已执行；只有真实运行的日志才算编译证据。
- **交互验证**：后续接入可操作的 Windows 实机、虚拟机或远程桌面环境，验证安装、登录、文件选择、退出重开、升级和故障恢复。CI 编译成功不能替代这一步。

GitHub 提供 Windows 托管 runner；私有仓库受账户额度和计费规则约束。当前已在本项目公开仓库的独立测试分支启动标准 Windows runner 构建，没有创建付费环境。首轮发现 Windows 默认文本编码差异，修复后重新验证；最新结果见 [验证记录](store-foundation-validation.md)。[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## 第二阶段：发行可行性与功能验证

| 验证项 | 通过标准 |
| --- | --- |
| 真实网页登录 | 选定服务可使用其支持的方式登录；弹窗、跳转、验证码、多因素认证可由用户正常完成；不会把页面加载成功误报成已登录 |
| 会话保持 | 应用重启后会话按服务规则保持；一个平台退出不破坏其他平台会话；登录失效可被识别 |
| 原生文件访问 | 系统文件选择、拖拽、粘贴在目标权限下可用，所选文件的访问权限覆盖完整上传过程 |
| 安装与升级 | 同一正式或测试包身份下，从较低版本升级到较高版本，配置及可保留会话不会意外丢失；卸载行为明确 |
| 数据迁移 | 旧 Mac 非沙盒数据与新容器、旧 Edge 扩展与 Windows 原生 profile 分别制定迁移边界，不自动复制凭据或承诺免登录迁移 |
| 故障恢复 | 网页或浏览进程失败有可理解的状态与恢复入口；恢复不会自动重复发送消息 |
| 实际提交判定 | 文件解析完成和消息确实提交后才显示成功，不能把调用网页按钮当成发送成功 |
| 附件共同能力 | 当前已勾选模型在当前登录态与账户实际权限下支持类型取交集；所有入口一致执行，既有附件不兼容时阻止发送 |

部分身份提供方限制嵌入式登录。应使用服务支持的认证方式并实测；系统浏览器认证不等于任意网页登录状态都能自动转移到 WebView。[WebView2 身份认证边界](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2) · [Apple 网页认证会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/)

## 第三阶段：账户与正式提审

先确定以个人还是组织发行，再注册对应账户并创建应用记录。Mac 需要 Apple Developer Program、App ID、分发签名及匹配的 profile；Windows 需要 Microsoft Store 开发者账户及应用身份。不要复用 tune Translate 的 Bundle ID、App Group 或产品级凭据。

[Apple 注册与主体要求](https://developer.apple.com/help/account/membership/program-enrollment) · [Microsoft 开发者开户](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account)

随后完成：

- Mac：正式签名与 Archive → Validate → TestFlight → App Review → 发布。
- Windows：正式 MSIX 身份 → Windows App Certification Kit 与目标设备测试 → 商店测试分发 → 正式提交 → 发布。
- 商店材料：准确描述、截图、支持与隐私政策地址、数据处理说明、审核可使用的演示方式。
- 第三方服务访问和展示方式应符合服务条款，准备必要的授权证明。Apple 对网站包装的功能价值和第三方服务访问有明确审核条款；统一输入与并排比较可作为产品价值说明，但不构成过审保证。[审核指南 4.2 与 5.2.2](https://developer.apple.com/app-store/review/guidelines/)

正式商店更新还需要真实商店测试渠道验证。本地包升级测试通过，不能写成商店更新服务已通过。

## 本阶段交付边界

本阶段交付为隔离分支上的商店工程准备与可复核的验证结果。现有已安装应用继续保留，不对外发布或替换。Windows 样机不等于完整新版本；Mac 构建成功不等于沙盒功能全通过；两个平台均未因新增工程文件而自动取得上架资格。

工程入口：[Mac 商店构建](../macOS/Store/README.md) · [Windows 原生验证工程](../Windows/native-preview/README.md) · [本阶段验证记录](store-foundation-validation.md)
