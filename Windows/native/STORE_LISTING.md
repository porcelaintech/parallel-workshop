# 上架 Microsoft Store：智囊 · Braintrust（Windows 原生应用）

> 注册与实名验证只能由你本人完成；其余（清单、包、材料）均已就绪。

## 0. 费用与时间

- **Microsoft Partner Center 个人开发者注册：约 $19（一次性）**；公司注册需额外法务验证
- Edge 加载项计划注册免费（与 Windows 应用计划共用账号，可与扩展同时提交）
- 审核周期：通常 1–3 个工作日

## 1. 注册 Partner Center（个人）

1. https://partner.microsoft.com/ → 「成为合作伙伴」→ 用微软账号登录
2. 注册「Windows 和 Edge 计划」→ 账户类型选「个人」→ 支付一次性注册费（约 $19）
3. 完成身份验证（可能 1–3 天）→ 通过后进入 https://partner.microsoft.com/dashboard →「应用和游戏」

## 2. 保留应用名（决定包身份）

1. 仪表板 →「应用和游戏」→「创建新应用」→ 名称填 **智囊 · Braintrust**（备选：Braintrust）
2. 进入应用 →「产品管理 → 产品标识」，记下三项值替换 `Windows/native/ParallelWorkbench/Package.appxmanifest`：
   - **包标识名称** → `<Identity Name="...">`（如 `12345PorcelainTech.Braintrust`）
   - **发布者** → `<Identity Publisher="CN=...">`
   - **发布者显示名称** → `<Properties><PublisherDisplayName>`
3. `<Identity Version>` 改为提审版本（如 `0.4.0.0`；`bash scripts/bump-version.sh` 会统一更新）

## 3. 构建 MSIX

```powershell
# 本地（Windows + VS 2022 Build Tools）
msbuild Windows\native\ParallelWorkbench\ParallelWorkbench.csproj /restore `
  /p:Configuration=Release /p:Platform=x64 /p:SelfContained=true /p:RuntimeIdentifier=win-x64 `
  /p:AppxBundle=Never /p:AppxPackageDir=artifacts\ /p:GenerateAppxPackageOnBuild=true `
  /p:AppxPackageSigningEnabled=true `
  /p:PackageCertificateKeyFile=cert.pfx /p:PackageCertificatePassword=pwb-dev
```

或 GitHub 手动触发 Actions「构建与发布」（workflow_dispatch）下载 MSIX 产物。
**CI 产物是测试证书签名的，只能本地安装；提交商店必须用第 2 步改好正式身份后重新构建。**
商店提审的包不需要自己签名——提交时 Partner Center 会重新签名。

## 4. 提交审核

1. 仪表板 → 应用 →「开始提交」
2. 各节填写：

| 节 | 内容 |
|---|---|
| 定价和可用性 | 免费；市场全选或按需 |
| 属性 | 类别：生产力 |
| 年龄分级 | 按问卷如实填写（无用户生成内容、无购买） |
| **程序包** | 上传第 3 步的 .msix → 提交选项：允许公众下载 |
| **商店一览** | 见下 |
| 提交选项 | 认证说明（Certification notes）：“应用在窗格内嵌入 ChatGPT/DeepSeek/豆包/Kimi/通义/文心官方网页客户端，用户在官方站内自行登录；不调 API、不自动化登录验证、不收集不上传任何数据；登录态仅保存在本机。” |

3. **商店一览**（Store listings）材料：
   - 说明：`多模型平行问答：一次提问，ChatGPT、DeepSeek、豆包、Kimi、通义千问、文心一言并排回答。`
   - 截图：**至少 1 张（建议 4–6 张）1366×768 或更大**：工作台全景、并排回答效果、附件、语音输入
   - **隐私策略 URL**：`https://github.com/porcelaintech/parallel-workshop/blob/main/PRIVACY.md`
   - 网站/支持联系人：GitHub 仓库地址
4. 提交 → 等待认证

## 5. 发布与更新

- 通过后应用自动上架；后续发版：改版本号 → 重新构建 MSIX →「更新提交」
- 商店负责：签名、托管、自动更新、SmartScreen 信任（用户无警告）

## 审核风险提示（如实告知）

- 应用功能为“嵌入官方网页客户端 + 注入发送”，属工具类应用；若被认定违反商店政策
  （如 10.1 或商标/仿冒条款），在认证说明里强调：**不调 API、不自动化登录验证、
  不存储账号密码、内容全部展示在官方站点内、界面明确标示各平台名称**
- 若原生应用被拒，Edge 扩展路线（`Windows/edge-extension/STORE_LISTING.md`）作为补充继续上架
