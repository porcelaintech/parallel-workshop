智囊 · Braintrust — macOS 本地工作台

1. 双击 install.command。
   如果 macOS 提示“无法验证开发者”，右键点击 install.command → 打开 → 再点“打开”。
2. 安装器会把程序复制到：
   ~/Library/Application Support/Braintrust/service
   并在 ~/Applications 生成本地「智囊.app」，桌面也会出现「智囊」。
3. 以后双击「智囊.app」即可打开。第一次启动会打开独立的浏览器 Profile；
   如果系统没有 Edge/Chrome/Chromium，会提示你先安装一个。
4. 日志：~/Library/Logs/Braintrust/service.log

不需要 Apple Developer 会员，也没有公证。智囊不会读取你日常浏览器的 Cookie；
登录态和本地数据只保存在你的电脑上。

卸载：把 ~/Applications/智囊.app 拖到废纸篓；
彻底清除登录态请再删除 ~/Library/Application Support/Braintrust。
