# 设计版前端复用与本地浏览器桥

## 结论

**设计不用重做。** `Windows/edge-extension/workbench.html` + `workbench.css` 是现成的视觉与布局源，可以直接作为本地服务工作台的 UI 基底；`workbench.js` 里“窗格布局 / 勾选 / 分页 / 缩放 / 附件状态 / 发送反馈”这些状态代码也大部分可以复用。

不能直接复制的是 `workbench.js` 里的 **扩展宿主 API**：`chrome.tabs`、`chrome.runtime`、`chrome.scripting`、`chrome.webNavigation`、`chrome.storage`、`chrome.debugger`、`chrome.declarativeNetRequest`。这些必须换成本地服务的 HTTP API + CDP 桥。

所以准确说法是：**HTML/CSS 100% 复用，JS 的 UI/状态层大部分复用，只有 transport/frame 层需要重写。**

## 映射表

| 扩展侧 | 本地服务桥 |
|---|---|
| `chrome.runtime.getURL('lib/adapters/index.json')` | `/data/adapters/*.json` 或 `/api/platforms` |
| `chrome.storage.local.get/set` | `localStorage` / `/api/preferences` |
| `chrome.tabs.getCurrent` | `window.__BT_TAB__`（本地页面无需 tab 概念） |
| `chrome.webNavigation.getAllFrames` | 新 `/api/browser/frames`（CDP `Target.getTargets` + `Target.setAutoAttach`） |
| `chrome.scripting.executeScript({frameIds})` | 新 `/api/browser/eval`（按 frame session 执行 `Runtime.evaluate`） |
| `chrome.tabs.sendMessage` / `chrome.runtime.sendMessage` | 新 `/api/browser/message`，或直接走 eval |
| `chrome.debugger`（附件拖放） | 本地服务已经直连 CDP，直接用 `Input.dispatchDragEvent` |
| `chrome.declarativeNetRequest` 去 XFO/CSP | CDP `Fetch.enable` + `Fetch.fulfillRequest` 改写响应头 |
| content script（`content-template.js` / `inject.js`） | CDP 注入 `data/inject.js`，按 frame 执行 |
| `chrome.runtime.requestUpdateCheck` | `/api/update/check` |

## iframe 窗格

设计版的 `<iframe src="${adapter.origin}" sandbox="...">` 可以原样保留。普通本地页面会被 `X-Frame-Options` / CSP 拦住；Phase 0 spike 已证明：

- 只 `Fetch.continueResponse` 不够，浏览器仍按原头拦截；
- `Fetch.getResponseBody` + `Fetch.fulfillRequest`（过滤 `x-frame-options` / `content-security-policy`，回填原 body）后，真实通义/千问能加载；
- `Target.setAutoAttach({flatten:true})` 能拿到 iframe 的 OOPIF 会话，`Runtime.evaluate` 能读 `location/title/contenteditable`。

## 改造顺序

1. 把 `workbench.html/css` 拷到 `local-service/public/`，先保留原设计，不改视觉。
2. 在 `workbench.js` 外套一层 `LocalBridge`，按上表替换 `chrome.*`；先跑通“平台列表 + 窗格渲染 + probe”。
3. 后端加 `/api/browser/frames`、`/api/browser/eval`、`/api/browser/message`，用 CDP frame session 实现 probe/send/附件。
4. 加 `Fetch` 响应改写；保留扩展版 DNR 作为对照。
5. 用真实账号跑六平台矩阵；保留 `data/inject.js` 的 120/150/700ms 等待和 `openSelectors` 行为，不要用 0.5.0 的简化内联版。

## 不要做的事

- 不要重新设计一套 UI；`workbench.html/css` 是唯一视觉源。
- 不要把 `workbench.js` 直接丢进 `public/` 就发；`chrome.*` 不存在，会白屏。
- 不要把 0.5.0 的极简控制页当正式 UI。
