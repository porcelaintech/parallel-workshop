# iframe / CDP 可行性 spike

这是 Phase 0 的验证脚本，不是生产代码。它验证两件事：

1. 普通 `http://127.0.0.1` 页面能否嵌入平台页面（会被 `X-Frame-Options` / CSP 拦）。
2. 用 CDP `Fetch` 在响应阶段改写 `x-frame-options` / `content-security-policy`，再用 `Target.setAutoAttach` 在 iframe 的 OOPIF 会话里执行 probe/send，是否可行。

## 运行

```sh
# 终端 1
node distribution/spike/server.mjs

# 终端 2：基线（应该看到 blocked iframe 变成 chrome-error）
node distribution/spike/cdp.mjs plain

# 终端 3：改写响应头（blocked iframe 应加载成功）
node distribution/spike/cdp.mjs strip http://127.0.0.1:48081/parent.html

# 真实平台：通义 → 千问（需要网络）
node distribution/spike/cdp.mjs strip http://127.0.0.1:48081/real.html
```

脚本使用 macOS 的 Google Chrome 路径和 `--no-sandbox`（仅测试环境；生产不能加）。输出 JSON 包含 frame/target、iframe 内 `location/title/textarea/contenteditable` 和 Fetch 事件。

## 结论（2026-10-25）

- 基线：`x-frame-options: DENY` + `frame-ancestors 'none'` 会让 iframe 变成 `chrome-error://chromewebdata/`，`net::ERR_BLOCKED_BY_RESPONSE`。
- 只加 `Fetch.continueResponse` **不够**；浏览器仍按原响应头拦截。
- 用 `Fetch.getResponseBody` + `Fetch.fulfillRequest`（过滤 `x-frame-options` / `content-security-policy`，原 body 回填）后，本地测试页和真实通义/千问都能在 iframe 中加载。
- `Target.setAutoAttach({ flatten: true })` 能拿到 iframe 的 OOPIF 会话；在会话里 `Runtime.evaluate` 能读到 `location/title/contenteditable`，说明按帧 probe/send 可行。
- 真实千问页面（重定向到 `www.qianwen.com`）加载后能读到 `contenteditable=true` 和页面文本；未登录，所以是登录页。
- 代价：要拦截/回填所有文档响应，处理 301（`getResponseBody` 不可用，改走 `continueRequest`）、登录跳转、Cookie/OAuth、平台反爬和性能。这是“浏览器桥”项目，不是 CSS 移植。
