# Windows 下载、安装与使用验证（2026-10-26）

结论：官网下载已恢复，修复候选的受控 Windows 安装和本地功能通过；真实 AI 问答尚未取得成功证据，不能宣称整条使用链路已经验收。

## 工程进度与分发决策

本轮接续 DeepSeek 会话附件和 `release/local-service` 分支，历史基线提交为 `4e621a8`。当前产品已具备设计版工作台、本地 Node 服务、独立浏览器 Profile、Windows NSIS EXE 与 Mac ARM64/Intel DMG；旧目录里的“极简控制页、只提供扩展或 ZIP”说明已落后。

Windows 按官网下载 EXE 分发，不以 Microsoft Store 上架、开发者计划或代码签名为前提。Apple 签名单独处理：本机未发现可用 Developer ID 签名身份或公证凭据，会员状态不能由此推断；用户已决定先完成 Windows 验证。

## 当前官网包与修复候选

| 身份 | 官网现有历史包 | 本轮修复候选 |
|---|---|---|
| 文件 | `Braintrust-Setup-0.6.0.exe` | `Braintrust-Setup-0.6.0-rc.2.C.exe` |
| 字节数 | 24,181,479 | 22,479,825（约 22.48 MB） |
| SHA-256 | `5b25f75d70ce9c20c5aa11513048e47af475258b488f8cab5be6463229a5ac65` | `7d336aa0e1e609e0dc73a4a49eede2dd04b39de276aeccfb8e45d063e30253a9` |
| 源码 | 保留历史 Release `v0.6.0-rc.1` 的原身份，文件/运行时字段为 `0.6.0` | `643ecc0bf748df5ad4c157484567a8a052e5f3d3` |

候选从上述干净 commit 构建，内置 Node 22.23.4；官方运行时 ZIP 经 SHA-256 校验。`build-proof.json` 记录源码、版本、运行时及安装包身份，本机下载后的候选再次通过哈希校验。候选保持低于 50,000,000 字节。

**本轮没有替换官网安装包、上传新 Release 或改变正式版本。** 官网仍提供上表的历史包。

## 官网恢复与当前包结果

当日早先，官网与 OSS 下载端点返回 HTTP 403 / `UserDisable`，代码 `0003-00000801`。用户完成充值后，官网与 Windows 安装包恢复可访问；下载后的 EXE 与历史哈希一致。Windows Edge 已实际打开官网、点击 Windows 链接并完成下载，文件哈希通过。充值后的浏览器下载文件安装重测在启动阶段未完成并触发工作流熔断；此超时不单独作为产品质量失败。文件有 `ZoneId=3` 的互联网来源标记且未签名；[限时观察 40287855225](https://github.com/porcelaintech/parallel-workshop/actions/runs/40287855225) 已在截图和窗口信息中确认经典 **Open File - Security Warning**：Publisher 为 Unknown Publisher，按钮为 Run / Cancel。未把它误称为 SmartScreen，也未移除来源标记。随后 [40288641495](https://github.com/porcelaintech/parallel-workshop/actions/runs/40288641495) 只对该哈希、该启动子进程和该文件名的 Run 按钮派发一次确认，45 秒内启动调用仍未返回，未进入已确认的安装器进程。记录中的 `runAcknowledged` 是点击派发标记，不代表系统已放行；此完整链路仍未验收。没有移除来源标记、修改系统安全设置或重复点击其他提示。

当前历史包已验证安装文件、桌面/开始菜单入口、自动发现 Edge、工作台基础交互、重复打开与应用退出重启。更深的生命周期检查复现了缺陷：运行中覆盖安装没有停止旧服务，运行中卸载未能清完程序文件。该缺陷证据来自 `40283324486/public-before-recharge/baseline/lifecycle.json`，绑定上表相同的历史包哈希；不是把充值后的未完成重测当作新产品失败。下载恢复不等于这些旧包问题已修复。

## 修复候选的 Windows 结果

使用 GitHub 托管的 Windows Server 2022 / 2025 虚拟机。最终候选验证运行：[40284433327](https://github.com/porcelaintech/parallel-workshop/actions/runs/40284433327)。应看各 job 和 JSON 结果；其中官网历史包的失败不会被候选测试通过覆盖。

| 检查 | Windows Server 2022 / Edge 156，无窗口 | Windows Server 2025 / Edge 155，有窗口 |
|---|---|---|
| 用户目录安装、桌面及开始菜单快捷方式、图标 | 通过 | 通过 |
| 实际 `.lnk → wscript → launcher → 内置 Node` 启动链 | 通过 | 通过 |
| 不预设浏览器路径，自动找到系统 Edge | 通过 | 通过 |
| 六平台控件、窗格、分页、缩放、发送反馈 | 通过 | 通过 |
| 确定性页面上的六平台文本、文件及回复显示 | 通过 | 通过 |
| 缺失输入框时显示失败 | 通过 | 通过 |
| 重复打开复用服务，不重复建立工作台 | 通过 | 通过 |
| 退出、重新启动、平台勾选恢复 | 通过 | 通过 |
| 运行中覆盖安装同一候选，停止旧进程并保留数据 | 通过 | 通过 |
| 运行中卸载，移除程序/入口/注册表并保留数据 | 通过 | 通过 |
| 无残留的本产品服务与浏览器进程 | 通过 | 通过 |
| 安装路径 | 默认路径 | `测试 用户\Braintrust App` |

独立有窗口 job 还实际操作了 NSIS 的 **Install / Finish** 按钮，确认安装器正常退出并自动打开工作台，安装后的同一套 UI 检查通过。这里的中文路径是安装目录，不能称为已测试中文 Windows 用户名或中文用户数据目录。

文本/附件确定性测试使用明确标注的测试页面，只替代第三方 AI 页面；产品前端、API、浏览器启动器、注入代码均为已安装包内的真实代码。它验证通道，不等于真实 AI 回答或真实平台附件接受。

## 真实网页与使用边界

Windows 候选已建立全部六个真实平台 iframe，包括通义/文心重定向后的域名；ChatGPT 探针曾返回 ready，其余当时为 input-not-found 或仍在加载。未登录探针仅作加载观察，不能据此判定已完成平台登录或产品失败。

Mac 独立 Profile 的生产桥正反对照也通过：同一跨站页面带 X-Frame-Options/CSP 禁止嵌入，关闭桥时进入浏览器错误页，启用实际生产桥后正常显示。真实六平台能建立 iframe；ChatGPT 可能遇到人工验证，其他平台可见登录或游客界面。探针对部分登录/验证页面分类仍不准确。

真实 Windows 游客问答另用不改变字节的同一候选取证。前两轮 `40285450526`、`40286120525` 均未验证成功：首轮在页面 loading 时发出动作；第二轮已等待 complete 和稳定输入框，文本进入正确输入框，API 返回动作派发成功，但 60 秒内没有用户消息或助手回复，文字仍留在输入框。不能将 API `ok:true` 当作真实问答成功。后续 [40287255348](https://github.com/porcelaintech/parallel-workshop/actions/runs/40287255348) 使用两个独立干净虚拟机，分别通过产品 API 与浏览器原生输入/发送按钮键盘操作提交；两条路径都未得到回复。网络记录显示 `/unauth-mweb/conversation/prepare` 返回 200，但没有获得新增用户/助手消息。不能据此确定是匿名会话策略、嵌入环境还是其他请求条件，也不能直接认定只是产品脚本点击的问题；记录为未验证，未绕过验证或使用个人账号。每次独立、干净环境测试至多发送一条无私人信息的 ChatGPT 连通性问题，无自动重发，只认新增 assistant 回复，遇登录/验证/限流不绕过。

仍未完成：六平台真实账号的登录、真实回答与附件矩阵；消费者 Windows 10/11 的 SmartScreen/Defender/企业策略；Windows 系统重启与休眠；中文用户名/用户数据目录；不同历史版本之间的完整迁移矩阵；自动更新安装替换及重启；旧双端 Release 流水线仍引用已移除的 `public/app.js`，Mac 更新索引的 `darwin-universal` 实为 ARM64 包，均需另行修复；Mac Developer ID 签名、公证与新下载用户首次打开。

## 本轮修复与测试工具

- 安装器不再寻找错误的根目录 `stop.ps1`，而使用安装包自带的新停止工具并传入实际服务路径；可先正常退出，必要时限时清理属于本安装的进程树。
- 卸载默认保留本地数据和浏览器 Profile；停止失败会中止覆盖或卸载。
- 浏览器冷启动合并并发请求；重启清理旧桥；连接和命令有超时；默认 Windows 浏览器路径覆盖 Program Files (x86)。
- 等待发送按钮启用；附件不可投递时明确失败；API 不再把注入失败报告为成功。
- Windows 构建支持完整 RC 字符串和独立数值元数据；构建证明绑定干净源码 commit。
- 验收脚本等待浏览器/页面真正就绪；直接读取 `.lnk` 的 Unicode StringData，避免 WScript COM 将中文显示为 `??` 造成误报。中文图标实际启动、原始字符串及独立重测均已取证。

相关工具：`distribution/scripts/build-windows-candidate.mjs`、`scripts/windows-installed-lifecycle-test.ps1`、`scripts/windows-installed-ui-test.mjs`、`scripts/windows-installer-wizard-test.ps1`、`scripts/windows-guest-send-test.mjs`。候选源码 `643ecc0` 的普通 CI、服务合同、更新校验和独立真实浏览器回归均通过。所有完成修改均已在本分支提交；测试产物与 Profile 不写入源码库。

本地源码工作树为 `/Users/qiaohancheng/braintrust/repo`，分支为 `release/local-service`；候选的实际构建来自 Actions 运行 40284433327 的干净 checkout，而非当前文档提交后的默认目录。

本地证据保存在工程旁的 `windows-validation/`；候选 proof 与 Windows 原始 JSON/截图同时保留在上述 Actions 的 artifacts。早期候选里测试工具的就绪判断、中文 COM 读取误报保留原记录，不作为当前候选的产品失败。
