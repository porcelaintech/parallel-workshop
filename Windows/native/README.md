# Windows 原生应用（WinUI 3 + WebView2 + MSIX）

「智囊 · Braintrust」Windows 原生应用：与 macOS 版功能对齐的多模型平行问答工作台。
顶部统一输入一键同步发送，回答在各平台官方网页客户端中平行展示。
**本目录只做打包与上架，不修改产品本身**；产品核心（适配器/注入脚本）由
`scripts/sync-windows-native.sh` 从 `Sources/WorkbenchCore/Resources/` 同步而来。

## 技术栈与设计

- **WinUI 3（Windows App SDK）+ .NET 8 + WebView2**：真原生微软生态（与 Edge 扩展同引擎，同一份适配器/注入核心）
- **登录态持久（应用内）**：WebView2 专用数据目录 `%LOCALAPPDATA%\ParallelWorkbench\WebView2`，每个平台登录一次后持久；菜单「登录态 → 备份/恢复」防存储损坏/系统重装
- **不调 API、无付费依赖**：嵌入各平台官方网页客户端，注入 = 定位输入框→设值→发送
- **语音输入**：Windows 系统语音识别（Windows.Media.SpeechRecognition）
- **附件**：文件选择/拖拽 → base64 → 页面内重建 File → 文件输入框或拖放通道（共用 inject.js）
- **更新**：Microsoft Store 分发，商店负责签名与自动更新

## 本地开发（Windows + Visual Studio 2022）

前置：Visual Studio 2022（「Windows 应用开发」工作负载），.NET 8 SDK。

```powershell
# 1) 同步共享核心（仓库根目录，git-bash 或 WSL）
bash scripts/sync-windows-native.sh

# 2) 打开解决方案
start Windows\native\ParallelWorkbench.sln

# 3) x64 + ParallelWorkbench 项目，F5 运行（VS 用本地证书部署 MSIX）
```

命令行构建（VS 2022 Build Tools + Windows 11 SDK + msbuild）：

```powershell
$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=ParallelWorkbenchDev" `
  -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
$pwd = ConvertTo-SecureString -String "pwb-dev" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath cert.pfx -Password $pwd

msbuild Windows\native\ParallelWorkbench\ParallelWorkbench.csproj /restore `
  /p:Configuration=Release /p:Platform=x64 `
  /p:SelfContained=true /p:RuntimeIdentifier=win-x64 `
  /p:AppxBundle=Never `
  /p:AppxPackageDir=artifacts\ /p:GenerateAppxPackageOnBuild=true `
  /p:AppxPackageSigningEnabled=true `
  /p:PackageCertificateKeyFile=cert.pfx /p:PackageCertificatePassword=pwb-dev
# 产物：artifacts\HanchengQiao.ParallelWorkbench_0.4.0.0_x64.msix
```

> `SelfContained=true` 把 .NET 运行时打进包（约 +80MB），目标机器无需预装 .NET，
> 是商店分发的正确形态；本地 F5 调试用 VS 默认（框架依赖）即可。

安装测试包：双击 MSIX → 「安装」→ 若提示信任证书，先在 certmgr 中把生成的证书导入「受信任人」。

## CI 构建

GitHub Actions（`.github/workflows/release.yml`）在 windows-latest 上自动同步核心、
生成测试证书、构建 MSIX 并上传产物；推送 `v*` tag 时自动创建 draft Release。
本地无需 Windows 环境也能完成日常打包。

## 上架 Microsoft Store

见 [STORE_LISTING.md](STORE_LISTING.md)。流程：注册 Partner Center（个人 $19 一次性）
→ 保留应用名 → 把 `Package.appxmanifest` 的 Identity 换成正式值 → CI 或本地构建 MSIX
→ Partner Center 提交（商店签名）。

## 与 macOS 版功能对照

| 功能 | macOS | Windows 原生 |
|---|---|---|
| 多窗格平行 + 一键同步发送 | ✅ | ✅ |
| 平台勾选 + 分页（最多 3 窗格） | ✅ | ✅ |
| 状态角标（就绪/未登录/验证/无输入框/不可达） | ✅ | ✅ |
| 放大单窗格 / 缩放 / 刷新 | ✅ | ✅ |
| 登录态持久 + 备份/恢复 | ✅（--backup-auth） | ✅（菜单） |
| 附件（文件/图片） | ✅ | ✅ |
| 语音输入 | ✅（SFSpeechRecognizer） | ✅（SpeechRecognizer） |
| URL 漂移治理（回到对话） | ✅ | ✅ |
| 自动更新 | ✅（GitHub Releases） | ✅（Store 自动） |
