# 本地工作台分发（Phase 0）

这是智囊本地工作台的**分发外壳**：官网、安装器、图标、GitHub Release 流水线、更新索引。
它不包含 0.6.0 的设计版工作台 UI；当前安装包仍然是 `local-service/public` 的极简控制页，Phase 1 才做前端移植。先把这个边界说清楚，避免把 Phase 0 当成完整产品发布。

## 架构

```text
GitHub 仓库
  ├─ 源码（main）
  └─ Release：两个独立资产 + SHA256
       ├─ Braintrust-local-service-macos-0.6.0.zip
       └─ Braintrust-local-service-windows-0.6.0.zip

braintrust.chat（Cloudflare Pages，纯静态）
  ├─ /                         官网
  ├─ /download/macos/          macOS 专用下载入口
  ├─ /download/windows/        Windows 专用下载入口
  ├─ /docs/                    安装/使用/数据/故障排查
  └─ /updates/local-service-update.json   更新索引

用户电脑
  ├─ 安装器（macOS install.command / Windows install.bat）
  ├─ 本地生成的「智囊.app」/「智囊」快捷方式
  ├─ 内置 Node 22 运行时
  ├─ 系统 Edge/Chrome/Chromium（独立 Profile）
  └─ 登录态、附件、日志只在本机
```

**macOS 与 Windows 不共用安装包，也不共用下载链接或 SHA-256。** 官网的两个入口分别读取 `darwin-universal` 和 `win32-x64`，文件名和校验值都不同。

## 目录

```text
distribution/
  macos/install.command       安装器：复制服务 + 在本机生成 智囊.app
  macos/launcher.sh           .app 内的启动器（服务发现/打开/找回）
  windows/install.bat         双击入口
  windows/install.ps1         复制服务 + 创建带图标快捷方式
  windows/launcher.ps1        启动/找回/错误提示
  assets/AppIcon.icns         macOS 图标
  assets/AppIcon.ico          Windows 图标
  scripts/build-release.sh    构建两个平台包 + SHA256 + 更新索引
  spike/                      iframe/CDP 可行性验证（不是生产代码）
```

## 构建

```sh
# 版本必须和 local-service/package.json 一致
VERSION=0.6.0 bash distribution/scripts/build-release.sh

# 产物
build/local-service-release/0.6.0/artifacts/
  Braintrust-local-service-macos-0.6.0.zip
  Braintrust-local-service-windows-0.6.0.zip
  local-service-update.json
  SHA256SUMS
  RELEASE_NOTES.md
```

构建会通过 `scripts/package-local-service.sh` 把 Node 22 运行时打进包；浏览器使用系统 Edge/Chrome/Chromium，不下载 Node。

## 发布

推荐用 `.github/workflows/release-local-service.yml` 手动触发：

1. Actions → “Release local service” → Run workflow，输入版本号。
2. 流水线跑合同测试、构建、`unzip -t`，创建一个 **Draft** GitHub Release。
3. 审阅 zip 和 Release notes；上传/发布。
4. 把 `local-service-update.json` 复制到 `website/updates/` 并重新部署站点。
5. 用一台干净的 macOS 和一台 Windows 分别下载对应入口，按文档走一遍首次安装。

发布前必须确认：
- macOS zip 和 Windows zip 的文件名、大小、SHA-256 不同；
- 更新索引里的 `darwin-universal` / `win32-x64` 分别指向对应资产；
- 首页下载按钮分别指向 `/download/macos/` 和 `/download/windows/`；
- 不要把 0.5.0 的极简控制页当正式 UI 发布。

## 无公证的边界

- macOS：Release 里不放 `.app`（放进去会被 quarantine，Gatekeeper 拦）。`install.command` 在本机生成 `~/Applications/智囊.app`，再 ad-hoc 签名；不需要 Apple Developer 会员。
- Windows：不放 `.exe`、不买代码签名证书。`install.bat` + 带 `.ico` 的 `.lnk`；首次运行可能遇到 SmartScreen/MOTW，文档写明“更多信息 → 仍要运行”。
- 想做到零提示，只有 Apple 公证 / Windows 代码签名两条路；当前产品选择不做。

## 入口/找回

- `install.command` / `install.bat` 只写当前用户目录，不需要管理员/sudo。
- 服务启动后写 `data/service.json`（端口 + token，权限 600）；启动器先读它，服务已经在跑就直接 `POST /api/browser/open` 把工作台带到前台，不会再起第二个 Node。
- 服务端新增 `POST /api/quit`；工作台有“退出”按钮。
- macOS 启动器日志：`~/Library/Logs/Braintrust/service.log`；Windows：`%LOCALAPPDATA%\Braintrust\logs\service.log`。
- 当前安装器还在 Phase 0：`.app` 是 shell 启动壳，不是完整的常驻原生应用；Dock 图标/菜单栏体验在 Phase 1 继续打磨。

## 官网部署

见 `website/README.md`。推荐 Cloudflare Pages + `braintrust.chat` 自定义域名；`/updates/*` 设置 `no-store`，避免旧索引。域名目前在阿里云注册局审核中，DNS 生效后再配。

## 已知限制（Phase 0）

- 安装包内还是极简控制页，不是设计版工作台；Phase 1 需要把 Edge 版 `workbench.html/css/js` 移植进来，并实现 iframe/CDP 浏览器桥。
- 更新目前只支持“检查 + 下载”；自动替换/重启还没实现。
- Windows 安装器只做了静态审查，还没有在 Windows 真机跑过。
- 没有做 Apple 公证/Windows 签名，首次安装会有一次系统提示。
- 官网下载按钮在更新索引不存在时显示“准备中”，这是预期，不是坏链接。
