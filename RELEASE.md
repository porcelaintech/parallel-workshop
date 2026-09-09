# 发布手册：智囊 · Braintrust

目标用户体验：

| 平台 | 即插即用形态 | 用户操作 | 更新方式 |
|---|---|---|---|
| macOS（直发） | 签名公证的 DMG | 下载 → 拖入 Applications → 双击 | 应用内自动更新 |
| macOS（商店） | Mac App Store | 商店点「获取」 | App Store 自动 |
| Windows（商店） | Microsoft Store 原生应用 | 商店点「获取」 | Store 自动 |
| Windows（补充） | Edge 加载项 | 商店页点「获取」→ 工具栏点图标 | 商店自动 |

> 注册与实名验证只能由你本人完成（平台政策）。其余一切——打包、签名/公证、MSIX、
> CI 自动化、商店材料——均已备齐。本手册只讲打包与上架，不涉及产品功能改动。

## 路线 A：Edge 加载项商店（免费，建议先做）

**成本**：注册免费（Microsoft 官方确认"向 Microsoft Edge 计划提交扩展不收取注册费"）。

1. 注册微软账号 → [Microsoft Partner Center](https://partner.microsoft.com/) → 注册「Microsoft Edge 计划」（个人/公司，需身份验证，可能数天）
2. 本地准备：`bash scripts/build-edge-extension.sh`（生成用户下载包与 manifest 位于根目录的 `build/edge-extension-store.zip`）
3. Partner Center 提交扩展包（zip）：
   - 名称：智囊（Braintrust）
   - 简短说明：多模型平行问答：一次提问，ChatGPT/DeepSeek/豆包/Kimi/通义/文心并排回答
   - 详细说明：见 `Windows/edge-extension/STORE_LISTING.md`
   - 隐私政策：扩展不运营自己的中转服务器；问题和附件只发送到用户勾选的第三方 AI 平台，登录态保存在浏览器配置中
   - 权限说明：activeTab（工具栏从空白页启动时原地复用）、declarativeNetRequest（仅工作台 tab 内的 iframe）、storage、scripting、webNavigation、debugger（尽力而为的附件拖放）
   - 注意：提交前按 Partner Center 提示处理 manifest 中的 `key` 字段（商店会分配正式 ID）
4. 审核通过后：用户在商店一键安装

## 路线 B：macOS DMG（$99/年 Apple Developer）

1. 注册 [Apple Developer Program](https://developer.apple.com/programs/)（$99/年）
2. Xcode → Settings → Accounts 登录，确保证书 `Developer ID Application` 已在钥匙串
3. 生成 App 专用密码：appleid.apple.com → 登录与安全 → App 专用密码
4. 一条命令签名公证：
   ```sh
   DEVELOPER_ID_APPLICATION="Developer ID Application: 你的名字 (TEAMID)" \
   APPLE_ID="you@example.com" APPLE_TEAM_ID="TEAMID" APP_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
   bash scripts/sign-release.sh
   ```
5. `VERSION=X.Y.Z bash scripts/package-dmg.sh` → `build/ParallelWorkbench-X.Y.Z.dmg`
6. 分发 DMG（网盘/网站/IM 均可），用户拖入即用，无任何警告

## 路线 C：Mac App Store（沙盒变体，审核风险见下）

**前置**：路线 B 的账号；App Store Connect（appstoreconnect.apple.com）→ 我的 App →
新建 App → Bundle ID 填 **com.porcelaintech.braintrust**（与打包脚本一致）→ 完成信息页；
Xcode 中创建「3rd Party Mac Developer Application / Installer」两类证书。

**打包与提审**：
```sh
APPSTORE_APP_IDENTITY="3rd Party Mac Developer Application: 你的名字 (TEAMID)" \
APPSTORE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 你的名字 (TEAMID)" \
bash scripts/package-appstore.sh
# 产物 build/ParallelWorkbench-appstore.pkg → 用 Transporter 上传 → 商店后台提审
```

**与直发版的关键差异（已自动处理，零产品改动）**：
- Bundle ID 使用反向域名 `com.porcelaintech.braintrust`（直发版保持 `ParallelWorkbench`，
  不破坏存量用户登录态；两渠道登录态各自独立，迁移用户需重新登录一次）
- 应用沙盒（`macOS/ParallelWorkbench.entitlements`）：网络客户端 + 用户选择文件只读
- 自助更新自动禁用（App Store 政策禁止；`PWBChannel=appstore` 标记，更新检查自动关闭）

**⚠️ 审核风险（如实告知）**：本应用为「嵌入第三方平台官方网页 + 注入发送」的工具形态，
Apple 可能以 4.2（最低功能）或沙盒/审核指南条款拒绝。提审备注建议说明：不调 API、
不自动化登录验证、不存储凭证、内容全部展示于官方站点内。**若 App Store 被拒，路线 B
（公证 DMG）即为正式分发渠道，用户体验不受影响。**

## 路线 D：Microsoft Store（Windows 原生应用）

**成本**：Partner Center 个人注册约 $19（一次性，与路线 A 的 Edge 计划共用账号）。

Windows 原生应用（WinUI 3 + WebView2 + MSIX，工程在 `Windows/native/`）只做打包与上架，
产品核心与 Edge 扩展共用同一份适配器/注入脚本。完整提交流程（注册 → 保留应用名 →
替换 `Package.appxmanifest` 身份 → 构建 MSIX → 商店一览材料）见
**`Windows/native/STORE_LISTING.md`**。隐私政策 URL 用
`https://github.com/porcelaintech/parallel-workshop/blob/main/PRIVACY.md`。

## CI 自动化（GitHub Actions）

`.github/workflows/release.yml`（与产品 CI `ci.yml` 并存，不冲突）：
- **手动触发（workflow_dispatch）**：macOS 构建 + QA 门禁 + DMG；Windows 同步核心 + 构建 MSIX（测试签名）；产物可下载
- **推送 `v*` tag**：双平台构建后自动创建 draft Release（附 SHA256）

**配置签名 secrets（可选，配置后直发版签名公证全自动）**，仓库 Settings → Secrets and variables → Actions：

| Secret | 值 |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application 证书导出的 p12，base64 编码：`base64 -i cert.p12` |
| `MACOS_CERT_PASSWORD` | p12 导出时设置的密码 |
| `MACOS_KEYCHAIN_PASSWORD` | 任意新密码（CI 临时钥匙串用） |
| `DEVELOPER_ID_APPLICATION` | 证书全名，如 `Developer ID Application: 名字 (TEAMID)` |
| `APPLE_ID` | Apple 账号邮箱 |
| `APPLE_TEAM_ID` | 团队 ID |
| `APP_APP_PASSWORD` | App 专用密码 |

## 发布前检查清单

- [ ] `bash scripts/qa.sh` 全绿（含 Windows 原生资源同步校验）
- [ ] 六平台回归通过（可发送平台真发、需登录平台 probe；运行前先退出 GUI）
- [ ] Windows 原生：Windows 机器安装 MSIX 实测六平台（首次发布必测）
- [ ] 版本号统一（`bash scripts/bump-version.sh x.y.z`，覆盖 MSIX manifest）
- [ ] 商店截图：Edge 与 Microsoft Store 1366×768+；Mac App Store 1280×800 / 2560×1600 两档
- [ ] 隐私政策 URL 可访问（公开仓库 `PRIVACY.md`）

## 说明

- 开发者注册与实名验证只能由你本人完成（平台政策），其余一切（打包、签名脚本、商店材料）已备齐
- 若暂不注册：本机/亲友小范围可用「开发者模式侧载扩展」和「未签名 .app」（Gatekeeper 右键打开），体验略打折扣
