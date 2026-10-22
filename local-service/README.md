# 智囊 · Braintrust 本地浏览器服务

本目录是跨 Windows/macOS 的本地服务入口。它不创建原生 GUI，不提供账户、会员、订阅或第三方平台权限；用户在平台官方网页中使用自己的登录态。

服务只绑定回环地址，启动一个独立的 Chromium/Edge Profile，网页工作台通过本地 HTTP 服务运行。浏览器 Profile 位于用户本地数据目录，重启电脑后保留。

## 本地开发

需要 Node.js 22+：

```sh
node server.mjs --no-browser --print-ready
```

浏览器启动时会优先使用包内 Chromium for Testing，再使用 `BRAINTRUST_BROWSER_PATH` 指定的 Chromium/Edge，最后寻找系统浏览器。发布包用 `BRAINTRUST_FETCH_RUNTIME=1 BRAINTRUST_FETCH_BROWSER=1 bash scripts/package-local-service.sh` 可携带 Node 22 和 Chromium 运行时，因此用户无需自行安装运行环境。

## 安装入口

- Windows：`launchers/windows/install.ps1`，完成后双击桌面或开始菜单的“智囊”。
- macOS：`launchers/macos/install.sh`，完成后双击 `Applications/Braintrust.command` 或桌面入口。

更新索引、更新包和 SHA-256 校验由本地服务处理；安装包可以从公开 GitHub Release 下载，不需要应用商店账户。
