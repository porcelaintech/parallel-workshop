# 智囊 · Braintrust — macOS 版

v0.4.1 是当前稳定版。

> 本目录是 **macOS 产品入口**。Windows/Edge 用户请使用仓库根目录下 `Windows/` 目录。

一键安装脚本自动获取最新稳定 Release。让 Agent 帮忙安装时，复制 [macOS 极简 Prompt](../AGENT_INSTALL_PROMPT.md#macos--复制以下整段) 即可。

本版（v0.4.1）修复更新断链（仓库更名所致）并把更新链路做厚：

- 顶部固定显示 `Update` 和当前版本，每次点击都有明确反馈（检查中 / 已是最新 / 发现新版 / 失败原因）
- 更新检查按「官方 API → 发布索引 `update.json` → CDN 镜像 → 历史仓库名索引」多级回退，任一来源可用即成功
- 失败时除「重试」外提供「前往下载页」直达 GitHub Releases
- 发现新版后点击 `Update` 下载、强校验 SHA-256、原子替换并重启新版；任何一步失败都保留旧版
- 兼容仓库更名前的旧仓库名（`HanchengQiao/parallel-workshop` 的 301 资产链接）

> **v0.4.0 及更早版本无法自助更新**（更新检查指向更名前的仓库名/尚不存在的仓库路径）。请用上方一键安装命令重装一次 v0.4.1，之后更新按钮恢复可用。App Store 渠道构建的更新由 App Store 提供，应用内自动关闭自助更新。

## 从 GitHub 直接下载安装（命令行）

**方式一：一键安装脚本（推荐）**

```bash
curl -fsSL https://raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install.sh | bash
```

脚本会自动下载并校验最新版 DMG，安装到 `/Applications/ParallelWorkbench.app`，然后启动「智囊」。更新保留原有应用标识、登录数据与使用偏好。

**方式二：手动下载 DMG**

```bash
VERSION=0.4.1
curl -LO "https://github.com/porcelaintech/parallel-workshop/releases/download/v${VERSION}/ParallelWorkbench-${VERSION}.dmg"
open "ParallelWorkbench-${VERSION}.dmg"
# 把 ParallelWorkbench.app 拖进 Applications 即可
```

> npm 包与 Homebrew tap 尚未发布；请勿使用仓库旧文档中出现过的 npx/brew 命令。

## 首次打开提示

v0.4.1 起应用带 ad-hoc 签名（无 Apple Developer 账号下的 Gatekeeper 缓解）：

- **推荐（完全无弹窗）**：用上方一键安装命令安装。curl 下载不写隔离属性，安装器会移除 quarantine，安装完成后双击即可直接打开，不会出现任何提示。
- **手动下载 DMG**：把「智囊」拖进 Applications 后首次双击若提示「无法验证开发者」，**右键点击应用 → 打开 → 再点打开** 即可，只需一次（DMG 内附有「请先读我 - 安装说明.txt」）。
- 想要彻底消除手动下载的提示，需要 Apple Developer Program 账号做 Developer ID 签名 + 公证（`scripts/sign-release.sh`，见 RELEASE.md 路线 B）。

## 使用要点

- 登录：在工作台各窗格内直接登录（登录流程被围栏圈禁在窗格内，不会跳出应用），登录态持久保存
- 附件：📎 选择 / 拖入 / ⌘V 粘贴；部分平台（通义/文心）自动注入受限时会明确提示手动添加
- 语音：🎤 开始/停止，首次需授权麦克风与语音识别
- 更新：顶部 `Update` 可随时检查；发现新版后点击即可下载、校验 SHA-256、安装并重启。检查失败会显示原因，可点击重试。

## 源码与构建

macOS 源码位于仓库根目录（`Sources/`、`Package.swift`），构建：

```bash
swift build -c release --arch arm64
bash scripts/package-app.sh
```

详见仓库根 `README.md` 与 `交付说明/产品说明与代码解读.md`。
