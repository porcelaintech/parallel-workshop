(() => {
  'use strict';
  // 本地入口页：file:// 页面在 Edge 冷启动（含首屏同步弹窗竞争）时也能稳定加载。
  // 它轮询扩展资源是否就绪（fetch 成功或导航探测），然后导航到扩展启动页；
  // launch.html 在 web_accessible_resources 中，跨源导航合法。
  const launchURL = 'chrome-extension://mklpdfdkbchlahfahofajchfjphlpkek/launch.html';
  const status = document.getElementById('launch-status');
  const progress = document.getElementById('launch-progress');
  const retry = document.getElementById('launch-retry');
  const help = document.getElementById('launch-help');
  let active = false;

  async function connect() {
    if (active) return;
    active = true;
    retry.hidden = true;
    help.hidden = true;
    progress.value = 1;
    status.textContent = '正在连接 Edge 中的智囊…';
    const deadline = Date.now() + 15000;
    do {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 1500);
      try {
        const response = await fetch(launchURL, { cache: 'no-store', signal: controller.signal });
        if (response.ok) {
          progress.value = 2;
          status.textContent = '智囊已就绪，正在打开…';
          window.location.replace(launchURL);
          return;
        }
      } catch { /* Retry only until extension registration is ready. */ }
      finally { clearTimeout(timer); }
      await new Promise(resolve => setTimeout(resolve, 200));
    } while (Date.now() < deadline);
    // 兜底：扩展此刻必已由命令行加载；直接尝试导航，失败则给出明确指引。
    progress.value = 2;
    status.textContent = '正在打开智囊…';
    window.location.replace(launchURL);
    setTimeout(() => {
      if (document.visibilityState !== 'hidden') {
        progress.value = 0;
        status.textContent = '暂未连接到智囊，请确认通过桌面「智囊」图标启动';
        retry.hidden = false;
        help.hidden = false;
        active = false;
      }
    }, 2000);
  }

  retry.addEventListener('click', connect);
  connect();
})();
