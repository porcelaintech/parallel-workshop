# Mac App Store 工程

这是独立的 macOS application 工程，复用现有 SwiftUI 和 WKWebView 产品源码。站外 SwiftPM、DMG 构建仍使用原有流程。本目录不意味着应用已经上架，也不保证审核通过。

## 无开发者账户也可以执行

要求 Xcode、XcodeGen 2.46+、Python 3。仓库根目录运行：

```bash
bash scripts/macos-store-build.sh unsigned archive
bash scripts/macos-store-test.sh
swift test --scratch-path .build/store-foundation-regression
```

首条命令生成 Xcode 工程和图标，构建 Apple 芯片与 Intel 通用归档，并检查实际包内资源和自更新代码排除情况。产物位于 `build/macos-store-unsigned/ParallelWorkbench.xcarchive`；应用在归档的 `Products/Applications/ParallelWorkbench.app`。仅构建应用可将 `archive` 改为 `build`。

默认版本读取已有的 Edge manifest。可显式设置 `PWB_APP_VERSION` 和 `PWB_BUILD_NUMBER`；默认构建号为 `1`，正式版本必须按发布记录递增。无签名验证使用 `local.braintrust.storepreview` 占位身份，避免与旧版 `ParallelWorkbench` 的标识混淆。它不是已注册的正式 Bundle ID。

脚本不会安装到 Applications、注册账号、读取凭据或上传。Xcode 运行环境只保留工具链与系统所需的普通变量，避免无关 shell 密钥被诊断附件收集。无签名归档只验证构建与打包，不能证明沙盒运行、证书配置、商店校验或审核已通过。

## 工程与更新渠道

- `project.yml` 是 XcodeGen 输入；生成的 `.xcodeproj` 和图标被本目录 `.gitignore` 排除。运行构建脚本后可以在 Xcode 打开工程。
- `WorkbenchCore` 为内嵌 framework，直接携带 `adapters/` 和 `injection/`。资源加载通过 framework bundle 定位；商店构建不回退到源码目录。
- 商店 framework 的源文件列表排除 `Updater.swift`、`UpdaterRelaunch.swift`、`UpdateCoordinator.swift`。`APP_STORE` 构建使用 `StoreUpdateCoordinator.swift`，没有 GitHub 版本查询、安装包下载替换、隔离属性移除或重启脚本。
- 顶部和菜单将用户带到配置好的 Mac App Store 页面；后台与回到前台不会打开商店。未配置数字 App Store ID 时，界面明确说明页面尚未配置，不伪造链接，也不会声称“已经是最新版”。
- `macos-store-test.sh` 链接归档中的真实 framework，在源码目录外测试资源加载、空/非法 ID、手动打开、打开失败、后台不打开和不虚报更新状态；不会联网或打开真实商店。

## 权限

`ParallelWorkbenchStore.entitlements` 声明 App Sandbox、网络客户端、用户选择文件只读，以及沙盒麦克风与 Hardened Runtime 音频输入权限。Info.plist 包含麦克风和语音识别用途说明。不申请全盘、相机或用户选择文件写权限。

这些声明仍需签名后的真实环境验证，尤其是登录 Cookie 持久化、文件选择/拖拽/粘贴、页面内上传、语音许可和权限拒绝行为。不要将“编译成功”写成这些行为已经通过。由于正式 Bundle ID 与旧版不同，旧版登录与偏好数据迁移需要独立设计、测试；本轮没有访问或迁移原有数据。

## 正式签名前置检查

由实际发布主体取得 Apple Developer Program 会员，并创建 App Store Connect 应用记录后，需要提供：

| 环境参数 | 内容 |
| --- | --- |
| `PWB_STORE_BUNDLE_ID` | 发布主体注册的正式 Bundle ID |
| `PWB_APPLE_TEAM_ID` | 10 位 Team ID |
| `PWB_APP_VERSION` | 三段正式版本号 |
| `PWB_BUILD_NUMBER` | 递增的正整数构建号 |
| `PWB_APP_STORE_ID` | 应用记录中的数字 Apple ID，用于更新页面 |
| `PWB_COPYRIGHT` | 实际权利人的版权声明 |

设置好真实公开参数后执行：

```bash
python3 scripts/macos-store-preflight.py
bash scripts/macos-store-build.sh signed archive
```

缺失或无效参数明确失败，本地/示例 Bundle ID 也会被拒绝。格式检查不证明 ID 归属或会员资格；Xcode 仍须能使用正式 Team 的签名与描述文件。脚本不自动创建标识，不传入 `-allowProvisioningUpdates`，也不导出或上传。签名归档保存在 `build/macos-store-signed/`，后续由 Xcode Organizer 校验并选择 TestFlight & App Store 分发。

`signed archive` 可以使用开发签名；它不是已经完成分发签名的商店安装包。最终 distribution export 和上传由后续 Organizer 流程完成。

## 本轮验证记录（2026-09-08）

- XcodeGen 2.46.0 已成功生成真实 application/framework 工程，并验证源文件排除和资源复制配置。
- 站外 SwiftPM 测试：28 项，0 失败，其中 1 项显式联网探测按默认设置跳过。
- 公开参数前置校验：空参数、占位标识、无效 Team、零构建号、非法商店 ID、非正式版本号都被拒绝。
- Xcode 26.6 的归档尝试在编译前失败：系统 `DVTDownloads.framework` 与 `IDESimulatorFoundation` 缺失符号；`-checkFirstLaunchStatus` 返回 69。官方 `-runFirstLaunch` 无交互完成结果；非交互管理员重试返回 `sudo: a password is required`。没有改动系统私有框架或读取密码，尚无成功的 Xcode archive。
- 为继续验证源码，增加了 `bash scripts/macos-store-preview.sh`。它使用现有 Swift 编译器生成 `build/macos-store-preview/ParallelWorkbench.app`，Info 中显式标记为 **swiftc 本地预览，非 Xcode archive**。应用和 framework 的 arm64/x86_64 构建、包内资源一致性、实际资源加载、二进制自更新排除、商店更新行为检查均通过。

该预览没有完成正式签名或沙盒运行认证，不可作为 App Store 提交包。完成 Xcode 首次初始化后，应重新运行正式的 `unsigned archive` 和对应测试。

另外已在独立临时副本中完成 ad-hoc App Sandbox 的启动、三个网页加载、商店更新提示与本地文件读取检查；该副本未启用 Hardened Runtime，不能代替正式签名验证。具体边界见 [第一阶段验证记录](../../docs/store-foundation-validation.md)。

## 仍需完成的发布验证

真实签名与沙盒运行、登录/上传兼容性、第三方平台访问条款与授权、隐私披露、品牌图标和商店元数据、旧版迁移、TestFlight 与 App Review 均未由此工程准备自动完成。尤其是内嵌第三方网站的产品价值和许可，应单独审查。

官方依据：[App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)、[Mac 商店更新规则 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)、[分发归档与校验](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。
