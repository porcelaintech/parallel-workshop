智囊 · Braintrust — Windows 本地工作台

1. 把 zip 解压到一个普通文件夹（不要在压缩包预览里直接运行）。
2. 双击 install.bat。
   如果 Windows 提示“Windows 已保护你的电脑”，点“更多信息” → “仍要运行”。
3. 安装器会把程序复制到：
   %LOCALAPPDATA%\Braintrust\service
   并在桌面和开始菜单创建带图标的「智囊」快捷方式，不需要管理员权限。
4. 以后双击「智囊」即可打开。第一次启动会打开独立的 Edge/Chrome Profile；
   如果找不到浏览器，会提示你先安装 Microsoft Edge 或 Google Chrome。
5. 日志：%LOCALAPPDATA%\Braintrust\logs\service.log

不需要 Windows 代码签名证书，也没有 SmartScreen 认证；首次运行会提示一次。
智囊不会读取你日常浏览器的 Cookie；登录态和本地数据只保存在你的电脑上。

卸载：删除桌面和开始菜单的「智囊」快捷方式；
彻底清除登录态请再删除 %LOCALAPPDATA%\Braintrust。
