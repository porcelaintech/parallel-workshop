# 原生商店工程第一阶段验证记录

日期：2026-09-08。源码起点 `338a2fb` / v0.4.0，开发分支 `codex/store-foundation-20260908`。

## Mac：已完成的验证

| 检查 | 结果与适用范围 |
| --- | --- |
| 原有 SwiftPM 回归 | 28 项测试，0 失败，1 项主动联网探测跳过；不代表真实平台发送测试已完成 |
| 商店通道编译 | 使用现有 swiftc 独立编译 APP_STORE 通道；应用和内嵌 framework 均包含 arm64、x86_64 |
| 资源加载 | 从生成的真实 framework 加载 6 个适配器、3 个注入脚本 |
| 自更新隔离 | Xcode 商店目标物理排除三个站外更新源码；预览二进制检查未发现 GitHub 更新查询、DMG 安装、隔离标记移除、安装目标或重启脚本路径 |
| 更新状态行为 | 缺失/非法 Store ID、手动打开商店失败、后台不自动打开商店、不虚报已是最新版等检查通过 |
| 发行参数检查 | 缺失参数、占位 Bundle ID、非法公开配置被拒绝；检查不证明账户归属或签名已经有效 |
| 本地界面启动 | 独立临时副本以 ad-hoc 签名并启用 App Sandbox 后正常显示工作台；ChatGPT 游客页、DeepSeek 登录页、豆包游客页可加载 |
| 本地文件访问 | 通过系统文件选择器读取本次生成的 76 字节 TXT，附件栏正确显示文件名与大小；随后移除，没有向任何平台发送 |
| 缺少商店编号的界面行为 | 点击更新后明确提示尚未配置 App Store 页面，没有打开伪造商店链接或显示已更新 |
| 原安装隔离 | 验证副本使用独立本地身份，测试结束后已退出；未替换现有已安装应用、未迁移旧 Cookie 或凭据 |

本地预览由 `scripts/macos-store-preview.sh` 生成，输出位于 `build/macos-store-preview/`。它在包中标记为 `swiftc-local-preview-not-xcode-archive`，不是 Xcode Archive，也不能直接交付 App Store。

### 本地沙盒启动的签名边界

界面测试使用临时副本、ad-hoc 签名和 App Sandbox。此副本没有启用 Hardened Runtime，正式 Xcode 工程仍保持 `ENABLE_HARDENED_RUNTIME=YES`，没有加入禁用库校验的 entitlement。

先前给临时副本同时启用 Hardened Runtime 时，系统因主程序和自有 framework 都没有 Team ID 而拒绝加载。Apple 的库校验要求 Apple 签名或与主程序相同 Team ID 的库；因此上述本地界面结果不能代替正式 Team 签名及 Hardened Runtime 验证。[Apple 库校验说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)

尚未验证：真实账户登录/登出/失效、登录保持、真实附件上传、语音权限与转写、旧版数据迁移、正式签名、TestFlight 和商店更新。

### Xcode Archive 的实际阻塞

Xcode 26.6 在加载自身 `IDESimulatorFoundation` / 系统 `DVTDownloads.framework` 时报告缺失符号，尚未开始项目编译。

- `xcodebuild -checkFirstLaunchStatus` 返回 69，表明首次初始化未完成。
- 普通初始化未完成；非交互管理员初始化返回 `sudo: a password is required`。
- 未读取或代填管理员密码，未删除或替换系统私有框架。

需要本机管理员完成 Xcode 官方首次初始化，再重新执行 `bash scripts/macos-store-build.sh unsigned archive`。初始化后仍须以真实归档结果判断，不能预先宣称问题已经解决。

## Windows：真实云端验证

原生验证工程采用 WinUI 3 / WebView2，三个平台使用应用自己的持久数据目录和分别命名的 profile。工程不包含统一发送或自动附件分发。

- 本机结构检查已通过，包括固定依赖、XML、资源、平台元数据及开发包身份。
- [首轮 Windows 构建](https://github.com/porcelaintech/parallel-workshop/actions/runs/34177684285) 在源码配置检查时发现默认编码差异；已改为显式 UTF-8，并验证 CRLF 文本不造成误报。
- [第二轮 Windows 构建](https://github.com/porcelaintech/parallel-workshop/actions/runs/34177824078)（`c22ed17`）已成功完成：真实 C# 编译、导航与 profile 策略测试、PowerShell 解析，以及 `0.1.0.0` / `0.1.1.0` 两个未签名 x64 MSIX 包生成和包内身份检查全部通过。
- [最终代码的 Windows 构建](https://github.com/porcelaintech/parallel-workshop/actions/runs/34178056063)（`80ae37a`，包含外部自定义协议拦截）再次全部通过；包与构建证据保存为 `windows-native-preview-unsigned-x64`。该结果对应本阶段最终产品代码，之后的本记录补充仅为文档变更。
- 编译和打包已取得 Windows 环境证据；安装、登录、会话保留、实际升级和商店分发仍待验证。后续源码变更需对应提交的 CI 结果。
- 工作流仅针对独立测试分支相关文件或手动触发，不发布 Release、不上传商店、不使用真实平台账户。上传范围限包目录，不包含应用会话数据和二进制构建日志。

Windows 本地开发包即使成功生成，仍需真实交互环境验证安装、退出重开、网页登录、文件上传、升级保留和进程故障恢复。两个不同版本的包只为后续升级测试提供输入，不等于升级测试已经通过。

## 下一阶段的进入条件

1. 完成 Xcode 首次初始化，得到真实 Mac Archive 并验证正式签名路径。
2. 保持 Windows 云端编译与 MSIX 构建通过，按最终提交保留结果。
3. 接入可交互的 Windows 测试环境，执行产品级验证；不要求必须购买实体 Windows 电脑。
4. 确定发行主体并开通 Apple Developer / Microsoft Store 账户，配置正式应用身份。
5. 按正式版需求接入登录态、账户实际上传权限与附件类型交集，再完成商店测试分发和审核。
