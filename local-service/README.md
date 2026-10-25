# 智囊 · Braintrust 本地浏览器服务

本目录是跨 Windows/macOS 的本地服务入口。它不创建原生 GUI，不提供账户、会员、订阅或第三方平台权限；用户在平台官方网页中使用自己的登录态。

服务只绑定回环地址，启动一个独立的 Chromium/Edge Profile，网页工作台通过本地 HTTP 服务运行。浏览器 Profile 位于用户本地数据目录，重启电脑后保留。

## 本地开发

需要 Node.js 22+：

```sh
node server.mjs --no-browser --print-ready
```

启动器会优先使用包内或系统 Node/浏览器；轻量发布包没有把它们塞进压缩包。缺少 Node 时，启动器会在用户数据目录下载并校验 Node 22；macOS 缺少 Edge/Chrome/Chromium 时，还会按架构下载并校验 Chromium。用户第一次点击可能需要等待运行时下载，后续启动使用本地缓存。

开发者若需要构建自包含大包，可使用 `BRAINTRUST_FETCH_RUNTIME=1 BRAINTRUST_FETCH_BROWSER=1 bash scripts/package-local-service.sh`；正式分发默认使用轻量包。

## 安装入口

- Windows：`launchers/windows/install.ps1`，完成后双击桌面或开始菜单的“智囊”。
- macOS：`launchers/macos/install.sh`，完成后双击 `Applications/Braintrust.command` 或桌面入口。

更新索引、更新包和 SHA-256 校验由本地服务处理；安装包可以从公开 GitHub Release 下载，不需要应用商店账户。
