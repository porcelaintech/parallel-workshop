// 本地服务版工作台：复用 Edge 版 workbench.html / workbench.css 的视觉与窗格结构，
// 不依赖 chrome.* 扩展 API；平台页面通过本地服务 + CDP iframe 桥加载。
(() => {
  const cfg = window.__BRAINTRUST_CONFIG__ || {};
  const authHeaders = { authorization: `Bearer ${cfg.token || ''}`, 'content-type': 'application/json' };
  const $ = (id) => document.getElementById(id);
  const MAX_VISIBLE = () => (window.innerWidth >= 1500 ? 3 : window.innerWidth >= 980 ? 2 : 1);
  const state = {
    adapters: [],
    selected: new Set(),
    frames: {},
    windowStart: 0,
    attachments: [],
    zooms: {},
    sending: false,
    probing: false,
    update: null
  };

  const panesEl = $('panes');
  const checksEl = $('checks');
  const pagingEl = $('paging');
  const pageIndEl = $('page-ind');
  const pageLeftEl = $('page-left');
  const pageRightEl = $('page-right');
  const progressEl = $('progress');
  const questionEl = $('question');
  const sendEl = $('send');
  const attachBtnEl = $('attach-btn');
  const fileInputEl = $('file-input');
  const attachChipsEl = $('attach-chips');
  const startupOverlay = $('startup-overlay');
  const startupText = $('startup-text');

  const api = async (path, options = {}) => {
    const response = await fetch(path, {
      ...options,
      headers: { ...authHeaders, ...(options.headers || {}) },
      cache: 'no-store'
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
    return body;
  };

  const setStartup = (text) => { if (startupText) startupText.textContent = text; };
  const finishStartup = () => startupOverlay?.classList.add('done');
  const toast = (id, text) => {
    const el = $(`toast-${id}`);
    if (!el) return;
    el.textContent = text;
    el.style.display = 'block';
    clearTimeout(el.__timer);
    el.__timer = setTimeout(() => { el.style.display = 'none'; }, 5000);
  };
  const setProgress = (text) => { if (progressEl) progressEl.textContent = text || ''; };

  function selectedAdapters() {
    return state.adapters.filter((adapter) => state.selected.has(adapter.id));
  }

  function renderChecks() {
    checksEl.innerHTML = '';
    for (const adapter of state.adapters) {
      const label = document.createElement('label');
      label.className = 'check';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = state.selected.has(adapter.id);
      input.addEventListener('change', () => {
        if (input.checked) state.selected.add(adapter.id);
        else state.selected.delete(adapter.id);
        localStorage.setItem('braintrust.local.selected', JSON.stringify([...state.selected]));
        renderPanes();
      });
      const span = document.createElement('span');
      span.textContent = adapter.name;
      label.append(input, span);
      checksEl.appendChild(label);
    }
  }

  function makePane(adapter) {
    const pane = document.createElement('div');
    pane.className = 'pane offscreen';
    pane.innerHTML = `
      <header>
        <span class="name">${adapter.name}</span>
        <span class="badge loading" id="badge-${adapter.id}">加载中</span>
        <span class="spacer"></span>
        <button class="zoom-btn zoom-out" data-id="${adapter.id}" title="缩小页面">−</button>
        <span class="zoom-val" id="zoom-${adapter.id}" title="点击恢复 100%">100%</span>
        <button class="zoom-btn zoom-in" data-id="${adapter.id}" title="放大页面">＋</button>
      </header>
      <iframe id="frame-${adapter.id}" src="${adapter.origin}" sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-downloads allow-modals allow-storage-access-by-user-activation"></iframe>
      <div class="toast" id="toast-${adapter.id}" style="display:none"></div>`;
    return pane;
  }

  function syncPanes() {
    const list = selectedAdapters();
    panesEl.querySelectorAll('.empty').forEach((el) => el.remove());
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = '未勾选任何模型 — 在上方勾选要参与的平台';
      panesEl.appendChild(empty);
      return;
    }
    for (const adapter of list) {
      if (state.frames[adapter.id]) continue;
      const pane = makePane(adapter);
      panesEl.appendChild(pane);
      const frame = pane.querySelector('iframe');
      state.frames[adapter.id] = { frame, adapter, pane };
      frame.addEventListener('load', () => {
        const badge = $(`badge-${adapter.id}`);
        if (badge && badge.classList.contains('loading')) {
          badge.className = 'badge';
          badge.textContent = '已加载';
        }
      });
      frame.addEventListener('error', () => {
        const badge = $(`badge-${adapter.id}`);
        if (badge) { badge.className = 'badge dead'; badge.textContent = '无法加载'; }
      });
      applyZoom(adapter.id, state.zooms[adapter.id] || 1);
    }
  }

  function layoutPanes() {
    const list = selectedAdapters();
    const capacity = MAX_VISIBLE();
    state.windowStart = Math.min(state.windowStart, Math.max(list.length - capacity, 0));
    const visible = new Set(list.slice(state.windowStart, state.windowStart + capacity).map((adapter) => adapter.id));
    for (const { pane } of Object.values(state.frames)) pane.classList.add('offscreen');
    list.forEach((adapter, index) => {
      const entry = state.frames[adapter.id];
      if (!entry) return;
      entry.pane.classList.toggle('offscreen', !visible.has(adapter.id));
      entry.pane.style.order = String(index);
    });
    const show = list.length > capacity;
    pagingEl.style.display = show ? '' : 'none';
    if (show) {
      pageIndEl.textContent = `${state.windowStart + 1}-${Math.min(state.windowStart + capacity, list.length)} / ${list.length}`;
      pageLeftEl.disabled = state.windowStart === 0;
      pageRightEl.disabled = state.windowStart >= list.length - capacity;
    }
  }

  function renderPanes() {
    syncPanes();
    layoutPanes();
  }

  function applyZoom(id, scale) {
    const entry = state.frames[id];
    if (!entry) return;
    const value = Math.max(0.5, Math.min(1.6, Number(scale) || 1));
    state.zooms[id] = value;
    entry.frame.style.zoom = String(value);
    const label = $(`zoom-${id}`);
    if (label) label.textContent = `${Math.round(value * 100)}%`;
  }

  function badgeFor(id, result) {
    const badge = $(`badge-${id}`);
    if (!badge) return;
    const map = {
      ready: ['ready', '就绪'],
      'login-required': ['loggedOut', '需要登录'],
      challenge: ['challenge', '需要人工验证'],
      'input-not-found': ['inputMissing', '未找到输入框'],
      'no-response': ['dead', '无响应'],
      'not-open': ['loading', '等待加载']
    };
    const [cls, text] = map[result.state] || ['loading', result.state || '未知'];
    badge.className = `badge ${cls}`;
    badge.textContent = text;
  }

  async function probe(id) {
    try {
      const result = await api(`/api/platforms/${id}/probe`);
      badgeFor(id, result);
    } catch (error) {
      const badge = $(`badge-${id}`);
      if (badge) { badge.className = 'badge dead'; badge.textContent = '探针失败'; }
    }
  }

  async function refreshProbes() {
    if (state.probing) return;
    state.probing = true;
    try {
      for (const adapter of selectedAdapters()) await probe(adapter.id);
    } finally {
      state.probing = false;
    }
  }

  function renderAttachments() {
    attachChipsEl.innerHTML = '';
    for (const attachment of state.attachments) {
      const chip = document.createElement('span');
      chip.className = 'chip';
      const name = document.createElement('span');
      name.textContent = `📄 ${attachment.name}`;
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.textContent = '✕';
      remove.addEventListener('click', () => {
        state.attachments = state.attachments.filter((item) => item !== attachment);
        renderAttachments();
        updateSendState();
      });
      chip.append(name, remove);
      attachChipsEl.appendChild(chip);
    }
  }

  function updateSendState() {
    sendEl.disabled = state.sending || (!questionEl.value.trim() && state.attachments.length === 0);
  }

  async function addFiles(files) {
    for (const file of files) {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',', 2)[1] || '');
        reader.onerror = reject;
        reader.readAsDataURL(file);
      }).catch(() => '');
      if (!data) continue;
      state.attachments.push({ name: file.name, mime: file.type || 'application/octet-stream', data });
      if (state.attachments.length >= 10) break;
    }
    renderAttachments();
    updateSendState();
  }

  async function send() {
    if (state.sending) return;
    const text = questionEl.value.trim();
    if (!text && !state.attachments.length) return;
    state.sending = true;
    updateSendState();
    setProgress('发送中…');
    try {
      const result = await api('/api/send', {
        method: 'POST',
        body: JSON.stringify({ text, platforms: [...state.selected], attachments: state.attachments })
      });
      const failed = result.results.filter((item) => !item.ok || item.result?.ok === false);
      setProgress(failed.length ? `部分失败：${failed.map((item) => item.name || item.id).join('、')}` : '已发送');
      setTimeout(() => setProgress(''), 5000);
      refreshProbes();
    } catch (error) {
      setProgress(`发送失败：${error.message}`);
    } finally {
      state.sending = false;
      updateSendState();
    }
  }

  async function checkUpdate() {
    const button = $('update-btn');
    const status = $('update-status');
    const banner = $('update-banner');
    button.disabled = true;
    status.textContent = '检查中…';
    try {
      const result = await api('/api/update/check', { method: 'POST', body: '{}' });
      state.update = result;
      if (result.state === 'available') {
        banner.dataset.state = 'available';
        status.textContent = `发现 v${result.latestVersion}`;
        button.textContent = '下载更新';
      } else {
        banner.dataset.state = 'idle';
        status.textContent = `当前 v${result.currentVersion} 已是最新`;
        button.textContent = '检查更新';
      }
    } catch (error) {
      banner.dataset.state = 'idle';
      status.textContent = error.message;
    } finally {
      button.disabled = false;
    }
  }

  async function boot() {
    try {
      setStartup('正在连接本地服务…');
      const health = await api('/api/health');
      $('update-version').textContent = `v${health.version || cfg.version || ''}`;
      setStartup('正在读取平台…');
      const data = await api('/api/platforms');
      state.adapters = data.platforms || [];
      const stored = (() => { try { return JSON.parse(localStorage.getItem('braintrust.local.selected') || 'null'); } catch { return null; } })();
      const allowed = new Set(state.adapters.map((adapter) => adapter.id));
      const initial = Array.isArray(stored) ? stored.filter((id) => allowed.has(id)) : data.selected;
      state.selected = new Set((initial && initial.length ? initial : data.selected).filter((id) => allowed.has(id)));
      renderChecks();
      setStartup('正在初始化窗格桥…');
      await api('/api/browser/prepare', { method: 'POST', body: '{}' });
      renderPanes();
      finishStartup();
      updateSendState();
      refreshProbes();
      setInterval(refreshProbes, 7000);
    } catch (error) {
      setStartup(`启动失败：${error.message}`);
      finishStartup();
      setProgress(`启动失败：${error.message}`);
    }
  }

  // 输入与发送
  questionEl.addEventListener('input', updateSendState);
  questionEl.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      send();
    }
  });
  sendEl.addEventListener('click', send);

  // 附件
  attachBtnEl.addEventListener('click', () => fileInputEl.click());
  fileInputEl.addEventListener('change', () => {
    addFiles([...fileInputEl.files]);
    fileInputEl.value = '';
  });

  // 翻页
  pageLeftEl.addEventListener('click', () => { state.windowStart = Math.max(0, state.windowStart - 1); layoutPanes(); });
  pageRightEl.addEventListener('click', () => { state.windowStart += 1; layoutPanes(); });

  // 缩放
  panesEl.addEventListener('click', (event) => {
    const button = event.target.closest('.zoom-btn');
    if (button) {
      const id = button.dataset.id;
      const current = state.zooms[id] || 1;
      applyZoom(id, current + (button.classList.contains('zoom-in') ? 0.1 : -0.1));
      return;
    }
    const value = event.target.closest('.zoom-val');
    if (value) {
      const id = value.id.replace('zoom-', '');
      applyZoom(id, 1);
    }
  });

  // 语音：浏览器支持时接入，不支持则保持按钮可见但不阻塞
  $('mic')?.addEventListener('click', () => {
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!Recognition) {
      setProgress('当前浏览器没有语音识别能力');
      setTimeout(() => setProgress(''), 3000);
      return;
    }
    const recognition = new Recognition();
    recognition.lang = 'zh-CN';
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const text = event.results[0][0].transcript;
      questionEl.value = questionEl.value.trim() ? `${questionEl.value.trim()} ${text}` : text;
      updateSendState();
    };
    recognition.onerror = () => setProgress('语音识别失败');
    recognition.start();
    setProgress('正在听…');
  });

  window.addEventListener('resize', () => {
    state.windowStart = Math.min(state.windowStart, Math.max(selectedAdapters().length - MAX_VISIBLE(), 0));
    layoutPanes();
  });

  $('update-btn').addEventListener('click', checkUpdate);
  boot();
})();
