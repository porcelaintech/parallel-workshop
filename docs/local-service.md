# 智囊本地浏览器服务

本地服务是 Windows 和 macOS 的无原生 GUI 发行路线。它不要求 Microsoft Store、Apple Developer、会员、订阅或第三方 API 权限。用户只在各 AI 平台官方网页中完成自己的登录。

## 用户入口

Release 提供两个压缩包：

- `Braintrust-local-service-windows-x64.zip`
- `Braintrust-local-service-macos-universal.zip`

Windows 解压后双击 `install.bat`；macOS 解压后双击 `install.command`。两个平台使用独立安装包、独立下载链接和独立 SHA-256。安装器写入当前用户目录并创建“智囊”桌面/开始菜单入口，不需要管理员权限。正式轻量包不内置大型运行时，首次点击时在本地数据目录下载并校验 Node 22；macOS 没有可用浏览器时再按架构下载并校验 Chromium，因此安装包保持在 50MB 以下。

## 运行模型

启动器运行本地 Node 服务。服务只监听 `127.0.0.1`，生成一次性 API 令牌并启动独立的 Chromium/Edge Profile。工作台由本地静态网页提供，平台页面通过浏览器控制协议打开和操作。数据目录为：

- Windows：`%LOCALAPPDATA%\Braintrust\data`
- macOS：`~/Library/Application Support/Braintrust/data`

浏览器 Profile 在同一台机器上持久化。服务不读取用户平时浏览器的 Cookie，也不上传 Cookie、Token 或对话内容。

## 更新

服务启动后可以检查公开 `local-service-update.json`，下载包并校验 SHA-256。更新文件先写入临时目录，验证通过后才启用；失败保留旧版本。公开 Release 是免费的发布源，不需要应用商店账户。

## 当前验证边界

`scripts/local-service-contract-test.mjs` 覆盖本地服务启动、令牌保护、健康检查、六个 adapter 加载和静态工作台。真实浏览器启动、登录、平台页面改版、附件上传和跨平台重启矩阵仍需在 Windows/macOS 机器上运行；这类外部网页行为不能由本地合同测试替代。

Windows 目标机可运行 `powershell.exe -ExecutionPolicy Bypass -File scripts/local-service-windows-smoke.ps1 -ServiceRoot <解压后的 local-service>`，验证随包 Node 运行时、服务启动、未授权请求拒绝和六个平台加载。

仓库的 `.github/workflows/local-service.yml` 还提供 Windows 2022 和 macOS 14 的可重复 smoke job；它们只做本地服务和脚本验证，不访问 AI 平台、不读取真实账户，也不发布商店版本。
