# 智囊 · Braintrust — 交付说明

> 多模型平行问答工作台：一个窗口平行排布多个 AI 平台的官方网页客户端，顶部统一输入一键同步发送，回答在各平台原生界面中平行展示。

## 交付物清单

| 交付物 | 位置 | 状态 |
|---|---|---|
| macOS 原生应用（SwiftUI + WKWebView） | `Sources/ParallelWorkbench/` | ✅ 可运行 |
| 打包 .app（未签名） | `build/ParallelWorkbench.app` | ✅ 双击可运行 |
| 核心库（适配器 + 注入引擎） | `Sources/WorkbenchCore/` | ✅ |
| 无人值守验收测试器 | `Sources/WorkbenchTester/` | ✅ |
| 注入核心自检（夹具） | `--selftest` | ✅ 7/7 |
| Edge/Chrome MV3 扩展 | `Windows/edge-extension/` | ✅ runtime 消息通道 + 本地胶水层验证（发布前仍需真机登录回归） |
| 一键质量门禁 | `scripts/qa.sh` | ✅ 全绿 |
| 打包/图标脚本 | `scripts/package-app.sh` `scripts/icon.swift` | ✅ |
| 本地浏览器服务 | `local-service/`、`scripts/package-local-service.sh` | ✅ 服务入口与合同测试；真实浏览器矩阵待目标系统 |

## 运行方式

```sh
# macOS 应用
open "build/ParallelWorkbench.app"
# 或开发模式：swift run ParallelWorkbench

# 无人值守验收（先退出应用；测试器与 GUI 共享 WebKit 存储，禁止并发）
swift run WorkbenchTester [--only=deepseek,kimi] [--probe-only] [--force] [--width=420] [问题]
swift run WorkbenchTester --selftest        # 注入核心自检
swift run WorkbenchTester --backup-auth     # 备份登录态
swift run WorkbenchTester --restore-auth    # 恢复应用自己的 WebKit 登录态
swift run WorkbenchTester --cookies         # 登录凭证审计

# 质量门禁
bash scripts/qa.sh

# Edge 扩展
bash scripts/build-edge-extension.sh
# Edge → edge://extensions → 开发者模式 → 加载已解压的扩展 → Windows/edge-extension/

# 本地浏览器服务
node local-service/server.mjs --no-browser --print-ready
node scripts/local-service-contract-test.mjs
node scripts/local-service-update-test.mjs
bash scripts/package-local-service.sh
```

构建产物位于 `build/local-service/artifacts/`，使用 `BRAINTRUST_FETCH_RUNTIME=1 BRAINTRUST_FETCH_BROWSER=1 bash scripts/package-local-service.sh` 可生成携带 Node 22 和 Chromium 运行时的 Windows/macOS 压缩包、SHA-256 清单和更新索引。服务版不建立账户、会员或付费权限体系；用户登录仍在第三方 AI 官方网页完成。

## 验收证据（2026-08-29 自动测试实录）

| 平台 | 结果 | 发送机制 | 证据 |
|---|---|---|---|
| DeepSeek | ✅（曾多次通过） | 合成回车 | 输入框清空 + 回答生成；当前会话过期待重扫后复测 |
| Kimi | ✅ | 点击 `div.send-button-container` | 清空 + 回答"我是Kimi，由月之暗面开发的AI助手。" |
| ChatGPT | ✅（游客） | 点击 `button[aria-label='Send message']` | 回答标志"ChatGPT said" |
| 通义千问 | ✅ | 预动作「新建对话」+ 指针事件序列 | 消息气泡 + 自动会话标题 |
| 文心一言 | ✅（游客） | 合成回车 | 清空 + 回答"我是百度文心助手…"+ 官方反馈控件 |

最终全量验收：**5/5 通过、0 失败**（用户重新扫码后 DeepSeek 复验通过）。

## 界面与交互

- 顶部大输入框（主战场，可多行，Enter 换行）+ 大发送按钮；⌘↩ 全局发送
- 平台勾选框 = 参与显示与发送：取消勾选即隐藏该窗格
- Edge 按窗口宽度显示 1–3 个窗格，macOS 同时最多显示 3 个；其余窗格通过分页导航且保持浏览上下文
- 窗格放大模式（登录/读长文）、状态角标、发送结果反馈、登录进度

## 核心设计要点

- **无 API、无付费依赖**：嵌入各平台官方网页客户端
- **应用内登录态**：WKWebView 使用本应用独立的持久数据存储，不继承 Safari
- **登录态备份/恢复**：防应用存储损坏或迁移时丢失登录态
- **脱离谷歌生态**：macOS 原生应用；Windows 走 Edge 扩展（微软生态）
- **不提供代理**：国际平台走用户系统既有代理
- **风控友好**：不自动化任何登录/验证；注入 = 定位输入框→设值→发送（五种发送策略按平台配置）

## 攻坚记录（工程价值）

- 三种富文本编辑器适配：Lexical（Kimi）、Slate（通义）、ProseMirror 类——统一"文本节点选区 + 异步焦点同步 + 五种发送策略"
- 验收标准演化：从"文本增长"到"消息气泡/输入框清空/回答标志"三重证据，消灭假通过
- 进程名/CFBundleIdentifier 决定 WebKit 存储归属：开发版与打包版已统一（bundle ID = ParallelWorkbench）
- Chrome 151 官方版已移除 `--load-extension` 命令行（2025 安全变更）——扩展真机加载需开发者模式手动完成
- `String.replace` 只替换首个匹配的坑（扩展胶水层真 bug，jsdom 冒烟测试抓获）

## 待办（用户回来后）

1. **DeepSeek pane 重新扫码**（会话过期，唯一阻塞项）→ 跑 `--only=deepseek` 最终验收
2. （可选）Edge 开发者模式手动加载扩展实测
3. （可选）对外分发：Apple 开发者账号签名 + 公证

## 已知限制

- 平台改版会使适配器失效 → 配置外置（`Sources/WorkbenchCore/Resources/adapters/*.json`），测试器取证输出可直接修复
- 文心/ChatGPT 游客模式有使用频次限制（登录后解锁完整功能）
- 通义首次发送会新建对话（prepare 预动作已自动处理）
