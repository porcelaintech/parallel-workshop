# 隐私政策：智囊 · Braintrust（Parallel Workbench）

**生效日期：2026-01-01（随商店上架生效）**
**适用于**：macOS 应用（Mac App Store / DMG 直发）、Windows 原生应用（Microsoft Store）、Edge 浏览器扩展。

## 一句话版

智囊**不运营自己的中转服务器、不收集、不上传你的任何个人数据**。它只是一个窗口：
把你输入的问题同步发给你自己已登录的 AI 平台官方网页。

## 我们处理什么

| 数据 | 处理方式 |
|---|---|
| 你输入的问题与附件 | 仅在你的设备上，从应用输入框复制到同一设备上你已登录的平台官方网页（ChatGPT / DeepSeek / 豆包 / Kimi / 通义 / 文心）；本地进程内存中转后即丢弃，**不上传到任何自有服务器** |
| 登录态（Cookie/会话） | 保存在你设备的应用专属存储（macOS：`~/Library/WebKit/`；Windows 原生：`%LOCALAPPDATA%\ParallelWorkbench\`；Edge 扩展：浏览器配置）；**绝不离开你的设备**。备份功能生成的文件由你选择存放位置 |
| 语音输入 | macOS 使用 Apple 语音识别、Windows 使用 Microsoft 语音识别，音频按 Apple/Microsoft 各自隐私政策处理；转写文本只填入你的输入框 |
| 崩溃/遥测 | **无**。应用不含任何分析、广告或遥测 SDK |

## 第三方网站

每个窗格内展示的是**第三方平台官方网页**。你在窗格内登录、提问、对话时，数据由这些平台
按其各自隐私政策处理——这与你在浏览器里直接使用它们完全相同。智囊只是把这些官方页面
并排放在一个窗口里。

## 权限用途

- **网络**：加载各平台官方网页（必需）
- **麦克风**：语音输入功能（可选，拒绝不影响打字）
- **文件**：你主动选择/拖入的附件（可选）

## 数据删除

卸载应用即删除本机全部数据；或使用「备份/恢复登录态」菜单/命令自行管理。
如需彻底清除：macOS 删除 `~/Library/WebKit/` 下对应目录，Windows 原生删除
`%LOCALAPPDATA%\ParallelWorkbench\`，Edge 扩展在浏览器中清除站点数据。

## 联系我们

- 仓库：https://github.com/porcelaintech/parallel-workshop
- 问题请提交 Issue
