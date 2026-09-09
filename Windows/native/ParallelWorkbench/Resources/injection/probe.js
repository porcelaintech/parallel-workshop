// 状态探测核心：判定 输入框可用 / 需人工验证 / 未登录 / 登录弹窗
// __CFG__ 由宿主注入为 JSON：{ input: { selectors }, probe: { loggedOut, challenge, loginModal } }
// 选择器支持 CSS 与 "xpath:" 前缀两种写法。
(() => {
  const cfg = __CFG__;
  const has = (sels) => (sels || []).some((s) => {
    try {
      if (s.startsWith('xpath:')) {
        const r = document.evaluate(s.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
        return !!r.singleNodeValue;
      }
      return !!document.querySelector(s);
    } catch { return false; }
  });
  return {
    input: has(cfg.input.selectors),
    challenge: has(cfg.probe && cfg.probe.challenge),
    loggedOut: has(cfg.probe && cfg.probe.loggedOut),
    loginModal: has(cfg.probe && cfg.probe.loginModal),
    url: location.href
  };
})();
