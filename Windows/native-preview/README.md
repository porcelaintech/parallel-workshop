# Windows 原生发行验证工程

这是独立工程小样，验证 `WinUI 3 + WebView2 + MSIX` 是否适合下一版 Windows 产品。现有 Edge 扩展不受它影响。本工程没有统一发送、附件分发、自动登录识别，也不是完整的下一版产品。

**2026-09-08 状态：源文件与打包基础已准备；当前机器为 Mac，没有 Windows/.NET/PowerShell。Windows 编译、实际安装、登录与升级均尚未验证。CI 首次运行结果待记录。**

## 当前范围

- 一个原生 Windows 窗口，显示 ChatGPT、DeepSeek、豆包三个独立 WebView2。
- 主页和平台域名来自 `Sources/WorkbenchCore/Resources/adapters/*.json`。只复制名称、URL 与域名，不运行旧扩展或共享注入脚本，不剥离网页安全响应头，不使用 iframe 嵌入方案。
- 应用私有 `LocalState/WebView2` 目录内使用固定的 `platform-chatgpt-v1`、`platform-deepseek-v1`、`platform-doubao-v1` profiles。应用升级保持包身份和 profile 名称；会话能否持久保留仍须实测。
- 站点用户触发的已允许域名弹窗使用同平台 profile、相同 environment，并保留 opener 关系。未知跳转先阻止，用户可明确选择在系统浏览器打开；不会把外部浏览器的登录导回应用。
- 页面加载与进程失败有可见提示；渲染问题可手动重新加载。浏览器进程退出后提示关闭并重开应用，不自动重发内容。
- 本地文件选择按钮仅验证 Windows 文件选择器；文件不读取、不上传、不交给网页。真实平台附件测试需手动使用该平台自己的上传入口。

页面加载成功不等于已登录，也不等于支持上传。所有状态文字保留此区分。部分第三方 OAuth 不支持嵌入式浏览器；此工程不读取或转移 cookies/token，也不绕过身份提供方限制。认证域名清单是验证候选，不是兼容性承诺。Google 等清单之外的身份入口、非用户触发弹窗、弹窗中的嵌套弹窗暂会被阻止，必须将真实失败记录后再决定支持方式。

## 构建基础

| 项目 | 固定值 | 说明 |
| --- | --- | --- |
| .NET | `net10.0`，SDK `10.0.100` 起、`latestFeature` | CI 安装当前稳定 `10.0.x`；禁止预览 SDK |
| WinUI component | `Microsoft.WindowsAppSDK.WinUI 1.8.260803003` | 属于 Windows App SDK **1.8.11** 稳定服务版本；并非声明使用最新主版本 |
| WebView2 SDK | `1.0.4191.47` | SDK 固定；客户机器使用 Evergreen Runtime |
| SDK BuildTools | `10.0.26100.9169` | 由 NuGet 恢复，无需自建安装器 |
| 目标 | Windows x64，最低 Windows 10 build 19041 | 只声明工程最低 API 边界；尚未完成该系统版本实测 |
| 打包 | MSIX，.NET/WinUI 自包含 | Evergreen WebView2 Runtime 仍为单独依赖 |

版本存在性已通过微软官方发布说明以及 NuGet 索引/包元数据核查。使用 WinUI 组件包避免把无关的 AI/ML SDK 带入验证工程。NuGet 的间接依赖图尚未通过真实 restore 固化，首次 CI 需审查 restore/build 结果。

Windows 环境需要 .NET 10 SDK、PowerShell 7，以及可用的 WinUI/MSIX 构建依赖。推荐已安装 Windows 应用开发工作负载的 Visual Studio 2026。CI 先使用 Windows 2022 runner + `dotnet build`；其首次实际编译是待过的关卡，不能将配置文件的存在视为编译通过。

从本目录执行：

```powershell
python scripts/validate-preview.py
dotnet run --project Tests/PolicyChecks.csproj -- Config/platforms.json
./scripts/Build-Preview.ps1 -PackageVersion 0.1.0.0
./scripts/Build-Preview.ps1 -PackageVersion 0.1.1.0
```

输出为 `artifacts/packages/<版本>/` 下的 **未签名** MSIX，包含 build-evidence.json；源清单不被改写。脚本会在隔离构建目录中生成版本，并校验实际 MSIX 里的身份/版本。它只编译和打包，不安装或发布。

平台配置变动后运行 `python scripts/prepare-preview.py` 更新工程快照。`--check` 只读比对。当前三个包图标是代码生成的验证标记，需要在正式发布前替换为审核后的商店素材。

## 开发签名与安装

本地身份为 `Braintrust.NativePreview.Development` / `CN=Braintrust Native Preview Development`，**没有在 Partner Center 注册，不可拿来提交商店**。正式包必须使用账户中的真实应用身份，并另行验证会话迁移；更换身份会更换应用数据位置，不能承诺开发版登录自动迁往正式版。

有 Windows 测试环境后，可以显式创建一把不可导出的本地开发签名密钥，给两份包一起签名：

```powershell
$previewPackages = Get-ChildItem artifacts/packages -Filter '*.msix' -Recurse
./scripts/Sign-Preview.ps1 -PackagePaths $previewPackages.FullName -CreateDevelopmentCertificate
```

脚本只接受本工程身份，输出公钥证书和签名后的校验信息，不添加系统信任，不导出私钥，也不安装应用。下次构建复用输出的证书指纹：`-CertificateThumbprint '<指纹>'`。不要把私钥放到仓库或 CI artifact。

仅在自用 Windows 测试机，核对证书主体/指纹后，由测试者把导出的 `.cer` 安装到“本地计算机 → 受信任人”证书存储。这一步可能需要管理员权限。然后双击**已签名**的 `0.1.0.0` MSIX 安装；关闭应用后再双击 `0.1.1.0` MSIX 测试更新。测试结束可卸载开发版并移除仅为本验证导入的开发证书。卸载可能清除开发版的数据；不要以卸载重装代替升级验证。

此签名流程不适合公共分发。Microsoft Store 的 MSIX 签名、下载和更新是后续独立关卡；传统 EXE/MSI 商店收录仍由开发者更新，不能替代我们的目标。

## 待完成的真实验证

| 关卡 | 通过证据 | 当前状态 |
| --- | --- | --- |
| C# 与打包 | 成功编译日志、两份 MSIX、实际清单/版本/摘要 | 待 Windows/CI |
| 干净安装 | 新用户环境能启动；缺 Runtime 时提示明确，安装 Runtime 后恢复 | 待 Windows |
| 登录与会话 | 各平台手动登录、重启应用仍登录；退出一平台不退出其他平台 | 待 Windows + 测试账户 |
| 登录兼容性 | 各登录方式、弹窗与重定向的实际成功/失败记录 | 待 Windows + 测试账户 |
| 文件入口 | 本地选择/取消、平台自己的选择/上传入口可用；不同登录权限如实记录 | 待 Windows |
| 运行时异常 | 仅关闭该验证应用相关的渲染进程，显示失败，可手动恢复 | 待 Windows |
| 包升级 | `0.1.0.0 → 0.1.1.0` 同身份升级、版本变化且会话保留 | 待 Windows |
| 商店路径 | 真实 Partner Center 身份、受控分发、商店更新、认证结果 | 待账户与前述关卡 |

源码包含可单独运行的 C# 导航策略检查（伪装域名、凭据 URL、scheme/port、跨平台隔离和诊断脱敏）。Mac 的 Python 校验仅能证明 XML、版本配置、元数据与资源结构，不代替 C# 测试或 Windows 运行。CI 不访问 AI 网站、不登录、不签名、不安装、不上传至商店。它支持手动触发，另仅在 `codex/store-foundation-20260908` 分支的本目录或该 workflow 变动时触发首次验证；不会自动在 `main` 运行。CI 只保存包目录，二进制构建日志留在执行机，不上传。`build-evidence.json` 中没有执行的关卡始终是 `pending`。

本地 MSIX 升级通过也不等于商店更新通过。正式准备阶段还要完成 ARM64 决策、窗口布局/无障碍/性能实测、下载和权限交互、诊断与故障恢复，以及后续的“登录与实际权限下共同支持类型交集”能力模块。

## 官方依据

- [Windows App SDK 1.8.11 发布说明](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-1-8)
- [WinUI 固定组件包](https://www.nuget.org/packages/Microsoft.WindowsAppSDK.WinUI/1.8.260803003)、[WebView2 固定 SDK](https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4191.47)、[固定构建工具](https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools/10.0.26100.9169)
- [单工程 MSIX](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/single-project-msix)、[MSIX 商店包与签名要求](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)
- [会话隔离](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/multi-profile-support)、[应用数据目录](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/user-data-folder)
- [WebView2 安全边界](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/security)、[OAuth 注意事项](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2)
- [Runtime 分发](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)、[进程故障](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-related-events)
