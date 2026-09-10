// 工作台页面：与 macOS 版对齐 —— 平台勾选（参与显示与发送）、按窗口宽度同时显示 1–3 个窗格
// （超出分页导航）、发送给全部勾选平台（不可见的窗格以离屏方式保持活跃）、错误可见化。
(async () => {
  if (window.self !== window.top) return;
  // The local desktop entry uses a resource that older releases already expose.
  // Leave the fragment before registering the exact workbench message origin.
  if (window.location.hash === '#launch') {
    window.location.replace(chrome.runtime.getURL('launch.html'));
    return;
  }
  const adapters = await fetch(chrome.runtime.getURL('lib/adapters/index.json')).then(r => r.json());
  const distributionChannel = await fetch(chrome.runtime.getURL('distribution.json'))
    .then(response => response.ok ? response.json() : {})
    .then(value => value?.channel === 'edge-addons' ? 'edge-addons' : 'sideload')
    .catch(() => 'sideload');
  const MAX_VISIBLE = 3;

  // 平台主域名映射（WB_ATTACH 帧内拖放按 host 定位 frame）
  const FRAME_HOSTS = {};
  for (const a of adapters) {
    try { FRAME_HOSTS[a.id] = new URL(a.origin).hostname; } catch {}
  }

  const panesEl = document.getElementById('panes');
  const checksEl = document.getElementById('checks');
  const pagingEl = document.getElementById('paging');
  const pageIndEl = document.getElementById('page-ind');
  const pageLeftEl = document.getElementById('page-left');
  const pageRightEl = document.getElementById('page-right');
  const progressEl = document.getElementById('progress');
  const questionEl = document.getElementById('question');
  const sendEl = document.getElementById('send');

  const PREFERENCES_KEY = 'parallelWorkbench.preferences.v1';
  const PREFERENCES_VERSION = 1;
  const adapterIDs = adapters.map(a => a.id);
  const knownAdapterIDs = new Set(adapterIDs);
  const enabled = new Set(adapters.map(a => a.id));
  const attachBtnEl = document.getElementById('attach-btn');
  const attachChipsEl = document.getElementById('attach-chips');
  const fileInputEl = document.getElementById('file-input');
  const attachments = [];   // { name, mime, data(base64), size }
  let windowStart = 0;
  const frames = {};    // id -> { frame, adapter }
  const lastSeen = {};  // id -> 最近一次探测响应时间戳
  const zooms = {};     // id -> 缩放倍数（CSS zoom 缩放 iframe，解决平台界面裁切）
  const authChannelToken = crypto.randomUUID();
  let workbenchTab = null;
  let sending = false;
  let preferencesReady = false;
  let preferenceSaveChain = Promise.resolve();

  function defaultPreferences() {
    return {
      version: PREFERENCES_VERSION,
      enabledAdapterIDs: adapterIDs.slice(),
      pageAnchorAdapterID: adapterIDs[0] || null,
      zoomByAdapterID: {}
    };
  }

  function isPlainRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  // Local preferences are untrusted input: extension downgrades, interrupted writes and
  // hand-edited profiles must never break startup. Unknown adapters and invalid zooms are
  // discarded instead of being guessed or clamped into a seemingly valid preference.
  function normalizePreferences(value, exists) {
    if (!exists) return defaultPreferences();
    if (!isPlainRecord(value) || value.version !== PREFERENCES_VERSION ||
        !Array.isArray(value.enabledAdapterIDs) || !isPlainRecord(value.zoomByAdapterID) ||
        !(value.pageAnchorAdapterID === null || typeof value.pageAnchorAdapterID === 'string')) {
      return defaultPreferences();
    }

    const enabledAdapterIDs = [];
    const seen = new Set();
    for (const id of value.enabledAdapterIDs) {
      if (typeof id !== 'string' || !knownAdapterIDs.has(id) || seen.has(id)) continue;
      seen.add(id);
      enabledAdapterIDs.push(id);
    }

    const zoomByAdapterID = {};
    for (const [id, zoom] of Object.entries(value.zoomByAdapterID)) {
      if (!knownAdapterIDs.has(id) || typeof zoom !== 'number' || !Number.isFinite(zoom) ||
          zoom < 0.6 || zoom > 1.3) continue;
      zoomByAdapterID[id] = zoom;
    }

    const enabledSet = new Set(enabledAdapterIDs);
    const pageAnchorAdapterID = enabledSet.has(value.pageAnchorAdapterID)
      ? value.pageAnchorAdapterID
      : (enabledAdapterIDs[0] || null);
    return {
      version: PREFERENCES_VERSION,
      enabledAdapterIDs,
      pageAnchorAdapterID,
      zoomByAdapterID
    };
  }

  async function restorePreferences() {
    let stored;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        stored = await chrome.storage.local.get(PREFERENCES_KEY);
        break;
      } catch {
        if (attempt === 3) {
          // A persistent read failure is not the same as "no saved value". Keep
          // in-memory defaults usable, but never overwrite an unread old record.
          return false;
        }
        await new Promise(resolve => setTimeout(resolve, attempt * 100));
      }
    }
    const exists = Object.prototype.hasOwnProperty.call(stored || {}, PREFERENCES_KEY);
    const prefs = normalizePreferences(stored?.[PREFERENCES_KEY], exists);
    enabled.clear();
    for (const id of prefs.enabledAdapterIDs) enabled.add(id);
    for (const id of Object.keys(zooms)) delete zooms[id];
    Object.assign(zooms, prefs.zoomByAdapterID);
    const list = enabledList();
    const anchorIndex = list.findIndex(a => a.id === prefs.pageAnchorAdapterID);
    windowStart = Math.max(0, anchorIndex);
    return true;
  }

  function currentPageAnchorAdapterID() {
    const list = enabledList();
    if (list.length === 0) return null;
    const start = Math.min(Math.max(windowStart, 0), Math.max(list.length - visibleCapacity(), 0));
    return list[start]?.id || list[0].id;
  }

  function preferenceSnapshot() {
    const zoomByAdapterID = {};
    for (const id of adapterIDs) {
      const zoom = zooms[id];
      if (typeof zoom === 'number' && Number.isFinite(zoom) && zoom >= 0.6 && zoom <= 1.3) {
        zoomByAdapterID[id] = zoom;
      }
    }
    return {
      version: PREFERENCES_VERSION,
      enabledAdapterIDs: adapterIDs.filter(id => enabled.has(id)),
      pageAnchorAdapterID: currentPageAnchorAdapterID(),
      zoomByAdapterID
    };
  }

  function persistPreferences() {
    if (!preferencesReady) return Promise.resolve();
    const snapshot = preferenceSnapshot();
    const save = preferenceSaveChain.then(() => chrome.storage.local.set({ [PREFERENCES_KEY]: snapshot }));
    // Serialize writes so a slower earlier write can never overwrite a newer click.
    preferenceSaveChain = save.catch(() => {});
    return preferenceSaveChain;
  }

  function applyZoom(id, z, save = true) {
    if (!knownAdapterIDs.has(id) || typeof z !== 'number' || !Number.isFinite(z)) return;
    zooms[id] = Math.round(Math.min(1.3, Math.max(0.6, z)) * 1000) / 1000;
    const f = frames[id]?.frame;
    if (f) f.style.zoom = String(zooms[id]);
    const el = document.getElementById('zoom-' + id);
    if (el) el.textContent = Math.round(zooms[id] * 100) + '%';
    if (save) persistPreferences();
  }

  panesEl.addEventListener('click', (e) => {
    const btn = e.target.closest('.zoom-btn');
    if (!btn) return;
    const id = btn.dataset.id;
    const cur = zooms[id] ?? 1;
    if (btn.classList.contains('zoom-in')) applyZoom(id, cur + 0.1);
    else applyZoom(id, cur - 0.1);
  });
  panesEl.addEventListener('click', (e) => {
    if (!e.target.classList?.contains('zoom-val')) return;
    applyZoom(e.target.id.replace('zoom-', ''), 1);
  });

  const enabledList = () => adapters.filter(a => enabled.has(a.id));
  const visibleCapacity = () => {
    const width = panesEl.clientWidth || window.innerWidth;
    if (width >= 1200) return MAX_VISIBLE;
    if (width >= 800) return 2;
    return 1;
  };

  // —— 勾选框 ——
  function renderChecks() {
    checksEl.innerHTML = '';
    for (const a of adapters) {
      const label = document.createElement('label');
      label.className = 'check';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = enabled.has(a.id);
      cb.addEventListener('change', () => {
        const oldList = enabledList();
        const oldStart = Math.min(windowStart, Math.max(oldList.length - visibleCapacity(), 0));
        const oldAnchor = oldList[oldStart]?.id || null;
        if (cb.checked) enabled.add(a.id); else enabled.delete(a.id);
        const newList = enabledList();
        const preservedIndex = oldAnchor ? newList.findIndex(item => item.id === oldAnchor) : -1;
        windowStart = preservedIndex >= 0
          ? preservedIndex
          : Math.min(oldStart, Math.max(newList.length - visibleCapacity(), 0));
        renderPanes();
        persistPreferences();
      });
      const span = document.createElement('span');
      span.textContent = a.name;
      label.appendChild(cb);
      label.appendChild(span);
      checksEl.appendChild(label);
    }
  }

  // —— 窗格渲染 ——
  // 增量策略：首次启用时创建窗格，之后永不删除；翻页只调整可见/离屏布局（不重建 iframe，
  // 平台页面状态、回答位置、草稿全部保留）。

  function makePane(a) {
    const pane = document.createElement('div');
    pane.className = 'pane offscreen';
    pane.innerHTML = `
      <header>
        <span class="name">${a.name}</span>
        <span class="badge loading" id="badge-${a.id}">加载中</span>
        <span class="spacer"></span>
        <button class="zoom-btn zoom-out" data-id="${a.id}" title="缩小页面（适应窗格宽度）">−</button>
        <span class="zoom-val" id="zoom-${a.id}" title="点击恢复 100%">100%</span>
        <button class="zoom-btn zoom-in" data-id="${a.id}" title="放大页面">＋</button>
      </header>
      <iframe id="frame-${a.id}" src="${a.origin}" sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-downloads allow-modals allow-storage-access-by-user-activation"></iframe>
      <div class="toast" id="toast-${a.id}" style="display:none"></div>`;
    return pane;
  }

  // 勾选集合变化时只补建新启用的窗格。取消勾选绝不移除 iframe：模型选择、
  // 草稿和滚动位置继续存活；布局阶段只会把它移到视口外，发送阶段也会跳过它。
  function syncPanes() {
    const list = enabledList();
    // 清理空态提示
    panesEl.querySelectorAll('.empty').forEach(e => e.remove());
    if (list.length === 0) {
      const d = document.createElement('div');
      d.className = 'empty';
      d.textContent = '未勾选任何模型 — 在上方勾选要参与的平台';
      panesEl.appendChild(d);
      return;
    }
    // 新建缺失的窗格
    for (const a of list) {
      if (frames[a.id]) continue;
      const pane = makePane(a);
      panesEl.appendChild(pane);
      frames[a.id] = { frame: pane.querySelector('iframe'), adapter: a };
      lastSeen[a.id] = 0;
      applyZoom(a.id, zooms[a.id] ?? 1, false);
    }
  }

  // 翻页布局：只改 CSS，绝不 remove/append iframe；重挂 DOM 会销毁浏览上下文。
  function layoutPanes() {
    const list = enabledList();
    const capacity = visibleCapacity();
    const start = Math.min(windowStart, Math.max(list.length - capacity, 0));
    windowStart = Math.max(0, start);
    const visibleIds = new Set(list.slice(start, start + capacity).map(a => a.id));
    for (const p of Object.values(frames)) {
      p.frame.closest('.pane')?.classList.add('offscreen');
    }
    for (let index = 0; index < list.length; index += 1) {
      const a = list[index];
      const p = frames[a.id];
      if (!p) continue;
      const paneEl = p.frame.closest('.pane');
      paneEl.classList.toggle('offscreen', !visibleIds.has(a.id));
      paneEl.style.order = String(index);
    }
    updatePaging();
  }

  function renderPanes() {
    syncPanes();
    layoutPanes();
  }

  function updatePaging() {
    const n = enabledList().length;
    const capacity = visibleCapacity();
    const show = n > capacity;
    pagingEl.style.display = show ? '' : 'none';
    if (!show) return;
    const start = Math.min(windowStart, Math.max(n - capacity, 0));
    pageIndEl.textContent = `${start + 1}-${Math.min(start + capacity, n)} / ${n}`;
    pageLeftEl.disabled = windowStart === 0;
    pageRightEl.disabled = windowStart >= n - capacity;
  }

  pageLeftEl.addEventListener('click', () => {
    windowStart = Math.max(0, windowStart - 1);
    layoutPanes();
    persistPreferences();
  });
  pageRightEl.addEventListener('click', () => {
    windowStart += 1;
    layoutPanes();
    persistPreferences();
  });
  let resizeFrame = 0;
  window.addEventListener('resize', () => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      windowStart = Math.min(windowStart, Math.max(enabledList().length - visibleCapacity(), 0));
      layoutPanes();
      persistPreferences();
    });
  });

  // —— 附件交互 ——
  function renderChips() {
    attachChipsEl.innerHTML = '';
    for (const a of attachments) {
      const chip = document.createElement('span');
      chip.className = 'chip';
      const name = document.createElement('span');
      name.textContent = '📄 ' + a.name;
      const remove = document.createElement('button');
      remove.textContent = '✕';
      remove.addEventListener('click', () => {
        const i = attachments.indexOf(a);
        if (i >= 0) attachments.splice(i, 1);
        renderChips();
        sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
      });
      chip.append(name, remove);
      attachChipsEl.appendChild(chip);
    }
  }
  async function addFile(file) {
    if (!file) return;
    if (file.size > 25 * 1024 * 1024 ||
        attachments.reduce((sum, item) => sum + (item.size || 0), 0) + file.size > 50 * 1024 * 1024) {
      progressEl.textContent = '⚠️ 单个附件上限 25MB，总附件上限 50MB';
      setTimeout(() => { progressEl.textContent = ''; }, 5000);
      return;
    }
    const data = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(',')[1] || '');
      r.onerror = () => reject(r.error || new Error('文件读取失败'));
      r.readAsDataURL(file);
    }).catch(() => '');
    if (!data) {
      progressEl.textContent = '⚠️ 文件读取失败：' + file.name;
      return;
    }
    attachments.push({ name: file.name, mime: file.type || 'application/octet-stream', data, size: file.size });
    renderChips();
    sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
  }
  attachBtnEl.addEventListener('click', () => fileInputEl.click());
  fileInputEl.addEventListener('change', async () => {
    for (const f of Array.from(fileInputEl.files || [])) await addFile(f);
    fileInputEl.value = '';
  });
  questionEl.addEventListener('dragover', (e) => { e.preventDefault(); });
  questionEl.addEventListener('drop', async (e) => {
    e.preventDefault();
    for (const f of Array.from(e.dataTransfer?.files || [])) await addFile(f);
  });
  document.addEventListener('paste', async (e) => {
    const items = Array.from(e.clipboardData?.items || []);
    for (const it of items) {
      if (it.type.startsWith('image/')) {
        const f = it.getAsFile();
        if (f) {
          if (!f.name) {
            const named = new File([f], '粘贴图片-' + Date.now() + '.png', { type: f.type });
            await addFile(named);
          } else await addFile(f);
        }
      }
    }
  });

  // —— 语音输入（Web Speech API，Edge/Chrome 内置）——
  const micEl = document.getElementById('mic');
  let recognition = null;
  let voiceBaseline = '';
  micEl.addEventListener('click', () => {
    if (recognition) {
      recognition.stop();
      recognition = null;
      micEl.classList.remove('rec');
      return;
    }
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      progressEl.textContent = '⚠️ 当前浏览器不支持语音识别';
      setTimeout(() => { progressEl.textContent = ''; }, 4000);
      return;
    }
    recognition = new SR();
    recognition.lang = 'zh-CN';
    recognition.interimResults = true;
    recognition.continuous = true;
    voiceBaseline = questionEl.value;
    recognition.onresult = (e) => {
      let t = '';
      for (const r of e.results) t += r[0].transcript;
      questionEl.value = voiceBaseline + (voiceBaseline.trim() ? ' ' : '') + t;
      questionEl.dispatchEvent(new Event('input', { bubbles: true }));
    };
    recognition.onerror = (e) => {
      if (e.error === 'not-allowed') {
        progressEl.textContent = '⚠️ 请允许麦克风权限';
        setTimeout(() => { progressEl.textContent = ''; }, 4000);
      }
      recognition = null;
      micEl.classList.remove('rec');
    };
    recognition.onend = () => {
      recognition = null;
      micEl.classList.remove('rec');
    };
    recognition.start();
    micEl.classList.add('rec');
  });

  // —— 输入与发送 ——
  questionEl.addEventListener('input', () => { sendEl.disabled = !questionEl.value.trim() && attachments.length === 0; });
  questionEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  });
  sendEl.addEventListener('click', send);

  // —— 注入保障：扩展页面直接注入（不经后台消息往返，杜绝 MV3 worker 休眠导致的挂起）——
  const HOSTS = [
    'www.doubao.com', 'doubao.com', 'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
    'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
  ];

  let ensureInFlight = null;
  async function ensureFrames() {
    // 互斥：多轮探测可能重叠触发 ensure，串行化避免并发注入风暴
    if (ensureInFlight) return ensureInFlight;
    ensureInFlight = (async () => {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      window.__wbEnsureLog = window.__wbEnsureLog || [];
      window.__wbEnsureLog.push('getAllFrames…');
      const frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
      window.__wbEnsureLog.push('frames:' + frames.length);
      let injected = 0;
      const errors = [];
      for (const f of frames) {
        let host = '';
        try { host = new URL(f.url || '').hostname; } catch {}
        window.__wbEnsureLog.push('frame:' + (host || '(空)') + ':' + f.frameId);
        if (!HOSTS.some(h => host === h || host.endsWith('.' + h))) continue;
        window.__wbEnsureLog.push('inject:' + host);
        const exec = (file, world) => new Promise((res, rej) => {
          const opts = { target: { tabId: tab.id, frameIds: [f.frameId] }, files: [file] };
          if (world) opts.world = world;
          try {
            chrome.scripting.executeScript(opts, (r) => {
              const err = chrome.runtime.lastError;
              if (err) rej(new Error(err.message)); else res(r);
            });
          } catch (e) { rej(e); }
        });
        const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('注入超时')), ms))]);
        // 功能脚本（隔离世界）：核心功能，单次带超时（互斥已防并发风暴）
        try {
          await withTimeout(exec('content.js', null), 4000);
          injected += 1;
          window.__wbEnsureLog.push('ok:' + host);
        } catch (e) {
          errors.push(host + ':' + String(e).slice(0, 50));
          window.__wbEnsureLog.push('err:' + host + ':' + String(e).slice(0, 60));
        }
      }
      if (errors.length) {
        progressEl.textContent = '⚠️ 注入异常: ' + errors.join('；');
        setTimeout(() => { progressEl.textContent = ''; }, 8000);
      }
      return { ok: errors.length === 0, injected, errors };
    } catch (e) {
      return null;
    }
    })();
    try {
      return await ensureInFlight;
    } finally {
      ensureInFlight = null;
    }
  }

  const probeCfg = (a) => ({ input: { selectors: a.input.selectors }, send: a.send, probe: a.probe || {}, text: '' });
  const sendCfg = (a, text, atts) => {
    const c = probeCfg(a);
    c.text = text;
    c.attachments = atts;
    if (a.attachment) c.attachment = a.attachment;
    return c;
  };

  function updateBadge(id, r) {
    const badge = document.getElementById('badge-' + id);
    if (!badge) return;
    let cls = 'ready', label = '就绪';
    if (r.challenge) { cls = 'challenge'; label = '需人工验证'; }
    else if (r.loggedOut || r.loginModal) { cls = 'loggedOut'; label = '未登录'; }
    else if (!r.input) { cls = 'inputMissing'; label = '未找到输入框'; }
    badge.className = 'badge ' + cls;
    badge.textContent = label;
  }

  function showToast(id, text) {
    const t = document.getElementById('toast-' + id);
    if (!t) return;
    t.textContent = text;
    t.style.display = '';
    setTimeout(() => { t.style.display = 'none'; }, 4000);
  }

  async function probeAll() {
    await ensureFrames();
    await Promise.all(Object.entries(frames).map(async ([id, p]) => {
      try {
        const reply = await sendFrameMessage(id, 'WB_PROBE', { cfg: probeCfg(p.adapter) }, 5000);
        if (reply?.result && reply.result.input !== undefined) {
          lastSeen[id] = Date.now();
          updateBadge(id, reply.result);
        }
      } catch {}
    }));
    // 空白/加载失败可见化：超过 25 秒无任何探测响应 → 标记「无响应」
    const now = Date.now();
    for (const id of Object.keys(frames)) {
      const badge = document.getElementById('badge-' + id);
      if (badge && lastSeen[id] > 0 && now - lastSeen[id] > 25000) {
        badge.className = 'badge dead';
        badge.textContent = '无响应';
      }
    }
  }

  async function postAndWait(id, msg, timeoutMs) {
    const reply = await sendFrameMessage(id, msg.type, msg, timeoutMs);
    return reply?.result || null;
  }

  // 按 host 列表查 OOPIF 帧 ID（webNavigation 全帧可见，含跨域 iframe）。
  // origin host 与实际帧 URL 可能不一致（重定向：tongyi.com → qianwen.com、yiyan → wenxin），按 homeHosts 兜底匹配。
  async function frameIdOfHosts(hosts) {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      const fs = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
      const matches = [];
      for (const f of fs) {
        let h = '';
        try { h = new URL(f.url || '').hostname; } catch {}
        if (hosts.some(x => h === x || h.endsWith('.' + x))) matches.push(f);
      }
      const outer = matches.find(f => f.parentFrameId === 0);
      return outer?.frameId ?? matches[0]?.frameId ?? null;
    } catch {}
    return null;
  }

  // 按适配器查帧 ID（origin host + homeHosts 全尝试）
  function frameIdOfAdapter(id) {
    const a = frames[id] && frames[id].adapter;
    if (!a) return Promise.resolve(null);
    const hosts = [];
    try { hosts.push(new URL(a.origin).hostname); } catch {}
    hosts.push(...(a.homeHosts || []));
    return frameIdOfHosts(hosts);
  }

  async function sendFrameMessage(id, type, payload = {}, timeoutMs = 6000) {
    const frameId = await frameIdOfAdapter(id);
    if (frameId == null) throw new Error('no-frame');
    workbenchTab = workbenchTab || await chrome.tabs.getCurrent();
    if (!workbenchTab?.id) throw new Error('no-tab');
    const message = { ...payload, type, frameId };
    return await Promise.race([
      chrome.tabs.sendMessage(workbenchTab.id, message, { frameId }),
      new Promise((_, reject) => setTimeout(() => reject(new Error('frame-message-timeout')), timeoutMs))
    ]);
  }

  // 帧内编辑器中心（帧坐标）。executeScript func 在目标帧的隔离世界执行，DOM 共享可查询。
  async function editorCenterInFrame(frameId) {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      return await new Promise((resolve) => {
        chrome.scripting.executeScript({
          target: { tabId: tab.id, frameIds: [frameId] },
          func: () => {
            const el = document.querySelector('[contenteditable="true"], textarea');
            if (!el) return null;
            const r = el.getBoundingClientRect();
            if (!r || (r.width === 0 && r.height === 0)) return null;
            return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
          }
        }, (res) => {
          const err = chrome.runtime.lastError;
          if (err) resolve(null);
          else resolve(res && res[0] ? res[0].result : null);
        });
      });
    } catch {}
    return null;
  }

  // 帧内主世界附件投递（替代已移除的 chrome.debugger CDP 通道）：
  // 由 chrome.scripting.executeScript 以 world:'MAIN' 注入目标平台帧执行，
  // 在页面主世界构造真实 File + DataTransfer 并合成 dragenter/dragover/drop。
  // 站点拿到的 dataTransfer.files 与用户真实拖放等价（同样为不可信事件）。
  async function dropFilesInFrame(payload) {
    try {
      const { x, y, items } = payload || {};
      if (!Array.isArray(items) || !items.length || typeof x !== 'number' || typeof y !== 'number') {
        return { ok: false, error: 'bad-args' };
      }
      const dt = new DataTransfer();
      for (const it of items) {
        if (!it || typeof it.name !== 'string' || typeof it.data !== 'string') continue;
        let bytes;
        try {
          const res = await fetch('data:' + (it.mime || 'application/octet-stream') + ';base64,' + it.data);
          bytes = await res.arrayBuffer();
        } catch {
          const raw = atob(it.data);
          bytes = Uint8Array.from(raw, c => c.charCodeAt(0)).buffer;
        }
        dt.items.add(new File([bytes], it.name, { type: it.mime || 'application/octet-stream' }));
      }
      if (!dt.files.length) return { ok: false, error: 'no-files' };
      dt.effectAllowed = 'copy';
      const target = document.elementFromPoint(x, y) ||
        (document.activeElement && document.activeElement.nodeType === 1 ? document.activeElement : null) ||
        document.body;
      const options = { bubbles: true, cancelable: true, composed: true, dataTransfer: dt };
      target.dispatchEvent(new DragEvent('dragenter', options));
      target.dispatchEvent(new DragEvent('dragover', options));
      target.dispatchEvent(new DragEvent('drop', options));
      return { ok: true };
    } catch (error) {
      return { ok: false, error: String((error && error.message) || error) };
    }
  }

  async function send() {
    if (sending) return;
    window.__wbAttachLog = window.__wbAttachLog || [];
    window.__wbAttachLog.push({ step: 'send-start', atts: attachments.length, text: questionEl.value.trim().slice(0, 10) });
    const text = questionEl.value.trim();
    if (!text && attachments.length === 0) return;   // 附件-only 允许发送
    sending = true;
    sendEl.disabled = true;
    attachBtnEl.disabled = true;
    const rid = crypto.randomUUID();
    const sentText = questionEl.value;
    const sentAtts = attachments.slice();
    await ensureFrames();
    window.__wbAttachLog.push({ step: 'after-ensure', atts: sentAtts.length });
    // —— 附件通道规划：有文件输入框选择器的平台走内容脚本文件赋值；其余走帧内主世界拖放 ——
    // 两条通道按平台互斥，杜绝同一附件被注入两次。
    const attPlan = {};        // id -> 'input' | 'drop'
    const dropDispatched = {};  // id -> bool（仅 drop 平台）
    const attNames = sentAtts.map(a => a.name);
    for (const [id, p] of Object.entries(frames)) {
      const sel = p.adapter.attachment && p.adapter.attachment.selectors;
      attPlan[id] = sel && sel.length ? 'input' : 'drop';
    }
    const dropAccepted = {};
    const attachmentBlocked = new Set();
    if (sentAtts.length > 0) {
      try {
        const tab = await chrome.tabs.getCurrent();
        if (tab) {
          const items = sentAtts.map(a => ({ mime: a.mime, data: a.data, name: a.name }));
          for (const [id, p] of Object.entries(frames)) {
            if (!enabled.has(id)) continue;
            const host = FRAME_HOSTS[id];
            if (!host || attPlan[id] !== 'drop') continue;
            try {
              const frameId = await frameIdOfAdapter(id);
              if (frameId == null) throw new Error('no-frame');
              const center = await editorCenterInFrame(frameId);
              if (!center) throw new Error('no-editor');
              // 帧内主世界合成拖放：坐标是帧内局部坐标，无需窗格可见性处理；
              // 直接由 chrome.scripting 把 dropFilesInFrame 注入目标帧执行。
              const injected = await Promise.race([
                chrome.scripting.executeScript({
                  target: { tabId: tab.id, frameIds: [frameId] },
                  world: 'MAIN',
                  func: dropFilesInFrame,
                  args: [{ x: center.x, y: center.y, items }]
                }),
                new Promise((_, rej) => setTimeout(() => rej(new Error('附件注入超时')), 10000))
              ]);
              const res = injected && injected[0] ? injected[0].result : null;
              dropDispatched[id] = !!(res && res.ok);
              window.__wbAttachLog.push({ id, plan: 'drop', dispatched: dropDispatched[id], error: res?.error || '' });
              if (!dropDispatched[id]) {
                showToast(id, '附件拖放失败: ' + (res?.error || 'UNKNOWN'));
                continue;
              }
              // 等平台消化后询问内容脚本是否真正接受（上传卡/文件名可见），诚实反馈
              await new Promise(r => setTimeout(r, 2000));
              const chk = await postAndWait(id, { type: 'WB_ATTACH_CHECK', frameId: id, names: attNames }, 3000);
              const accepted = !!(chk && chk.attached);
              dropAccepted[id] = accepted;
              window.__wbAttachLog.push({ id, plan: 'drop', accepted });
              showToast(id, accepted ? '附件已注入' : '附件未被平台接受，请手动添加');
              if (!accepted) attachmentBlocked.add(id);
            } catch (e) {
              dropDispatched[id] = false;
              window.__wbAttachLog.push({ id, plan: 'drop', dispatched: false, error: e.message });
              showToast(id, '附件失败: ' + e.message);
            }
            await new Promise(r => setTimeout(r, 600));
          }
        }
      } catch (e) {
        progressEl.textContent = '⚠️ 附件注入异常: ' + e;
      }
    }
    const now = Date.now();
    const jobs = [];
    let skipped = 0;
    // 发送前帧域名复核：帧若已漂移到非本平台域名，绝不把问题/附件发过去
    let frameUrlByFrameId = {};
    try {
      const tab2 = await chrome.tabs.getCurrent();
      if (tab2) {
        const fs = await chrome.webNavigation.getAllFrames({ tabId: tab2.id });
        for (const f of fs) {
          if (f && f.frameId !== undefined && f.url) frameUrlByFrameId[f.frameId] = f.url;
        }
      }
    } catch {}
    for (const [id, p] of Object.entries(frames)) {
      try {
        if (!enabled.has(id)) continue;
        if (!p.frame.contentWindow) {
          showToast(id, '失败: 页面未就绪');
          skipped += 1;
          continue;
        }
        // 域名复核：当前帧 URL 必须仍属于该平台
        if (Object.keys(frameUrlByFrameId).length > 0) {
          const fid = await frameIdOfAdapter(id);
          const curUrl = fid != null ? frameUrlByFrameId[fid] : null;
          if (curUrl) {
            const hosts = [];
            try { hosts.push(new URL(p.adapter.origin).hostname); } catch {}
            hosts.push(...(p.adapter.homeHosts || []));
            let host = '';
            try { host = new URL(curUrl).hostname; } catch {}
            if (!hosts.some(x => host === x || host.endsWith('.' + x))) {
              showToast(id, '窗格已跳转到其他页面，已跳过');
              skipped += 1;
              continue;
            }
          }
        }
        // 诚实性检查：最近 20 秒无探测响应的窗格可能尚未加载/注入，明确提示而非静默
        if (lastSeen[id] === 0 || now - lastSeen[id] > 20000) {
          showToast(id, '未就绪（页面加载中），已跳过');
          skipped += 1;
          continue;
        }
        if (attachmentBlocked.has(id)) {
          showToast(id, '附件未被接受，已跳过发送以避免漏附件');
          skipped += 1;
          continue;
        }
        const cfg = sendCfg(p.adapter, text, sentAtts);
        // 附件：仅让规划通道对应的帧保留附件（input 平台走内容脚本；drop 平台仅在拖放派发失败时兜底）
        if (sentAtts.length > 0) {
          const keep = attPlan[id] === 'input' || (attPlan[id] === 'drop' && !dropDispatched[id]);
          if (!keep) { delete cfg.attachments; delete cfg.attachment; }
        }
        jobs.push((async () => {
          try {
            const reply = await sendFrameMessage(id, 'WB_INJECT', { rid, cfg }, 12000);
            const result = reply?.result || { ok: false, error: 'EMPTY_RESULT' };
            let suffix = '';
            const ai = result.attInfo;
            if (ai && ai !== 'none') {
              suffix = ai.startsWith('fileInput') ? ' · 附件已添加'
                : ai.startsWith('drop') ? ' · 附件已拖放'
                : ' · 附件: ' + ai;
            }
            showToast(id, result.ok ? ('已提交' + suffix) : ('失败: ' + (result.error || 'UNKNOWN')));
            return { id, ok: result.ok === true };
          } catch (error) {
            showToast(id, '失败: ' + String(error));
            return { id, ok: false };
          }
        })());
      } catch (e) {
        showToast(id, '失败: ' + e);
        skipped += 1;
      }
    }
    const results = await Promise.all(jobs);
    const succeeded = results.filter(r => r.ok).length;
    const failed = results.length - succeeded;
    if (succeeded > 0) {
      if (questionEl.value === sentText) questionEl.value = '';
      for (const sent of sentAtts) {
        const index = attachments.indexOf(sent);
        if (index >= 0) attachments.splice(index, 1);
      }
      renderChips();
      progressEl.textContent = `已提交 ${succeeded}/${results.length} 个窗口` +
        (failed || skipped ? `，${failed + skipped} 个失败或跳过` : '');
    } else {
      progressEl.textContent = '⚠️ 本轮没有窗口发送成功，问题与附件已保留';
    }
    setTimeout(() => { progressEl.textContent = ''; }, 6000);
    sending = false;
    attachBtnEl.disabled = false;
    sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
  }

  function validatedDeepSeekCallback(raw) {
    try {
      const url = new URL(raw);
      if (url.protocol !== 'https:' || url.hostname !== 'chat.deepseek.com') return null;
      if (url.pathname !== '/api/v0/users/oauth/wechat/callback') return null;
      if (url.username || url.password || url.hash) return null;
      const code = url.searchParams.get('code') || '';
      const state = url.searchParams.get('state') || '';
      if (!code || code.length > 512 || state.length > 512) return null;
      return url.href;
    } catch {
      return null;
    }
  }

  async function verifyDeepSeekLogin() {
    for (let attempt = 0; attempt < 30; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 1000));
      await ensureFrames();
      try {
        const pane = frames.deepseek;
        if (!pane) return false;
        const reply = await sendFrameMessage('deepseek', 'WB_PROBE', { cfg: probeCfg(pane.adapter) }, 5000);
        const result = reply?.result;
        if (!result) continue;
        lastSeen.deepseek = Date.now();
        updateBadge('deepseek', result);
        if (result.input && !result.loggedOut && !result.loginModal && !result.challenge) {
          progressEl.textContent = '✅ DeepSeek 登录状态已同步';
          setTimeout(() => { progressEl.textContent = ''; }, 5000);
          return true;
        }
      } catch {}
    }
    progressEl.textContent = '⚠️ 已接收微信回调，但尚未确认 DeepSeek 登录状态；请刷新该窗格重试';
    setTimeout(() => { progressEl.textContent = ''; }, 8000);
    return false;
  }

  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!msg || msg.type !== 'WB_AUTH_CALLBACK_TRUSTED') return false;
    if (sender.id !== chrome.runtime.id || msg.channelToken !== authChannelToken ||
        msg.tabId !== workbenchTab?.id || msg.provider !== 'deepseek-wechat') return false;
    const callback = validatedDeepSeekCallback(msg.url);
    const pane = frames.deepseek;
    if (!callback || !pane) return false;
    progressEl.textContent = '微信授权完成，正在同步 DeepSeek 登录状态…';
    lastSeen.deepseek = 0;
    const badge = document.getElementById('badge-deepseek');
    if (badge) { badge.className = 'badge loading'; badge.textContent = '登录同步中'; }
    pane.frame.src = callback;
    verifyDeepSeekLogin();
    return false;
  });

  async function registerWorkbenchChannel() {
    workbenchTab = await chrome.tabs.getCurrent();
    if (!workbenchTab?.id) throw new Error('无法识别工作台标签页');
    const result = await chrome.runtime.sendMessage({
      type: 'WB_REGISTER_WORKBENCH',
      channelToken: authChannelToken
    });
    if (!result?.ok || result.tabId !== workbenchTab.id) throw new Error('工作台认证通道注册失败');
  }

  // —— 版本更新：商店版交给 Edge 原生更新；侧载版下载精确用户包并给出最短重载路径。——
  const UPDATE_REPO = 'porcelaintech/parallel-workshop';
  const bannerEl = document.getElementById('update-banner');
  const updateButton = document.getElementById('update-btn');
  const updateStatusEl = document.getElementById('update-status');
  const currentVersion = chrome.runtime.getManifest().version;
  const UPDATE_INTERVAL_MS = 6 * 3600 * 1000;
  const UPDATE_FOCUS_THROTTLE_MS = 15 * 60 * 1000;
  const isStoreBuild = distributionChannel === 'edge-addons';
  let updateState = 'idle';
  let updateTask = null;
  let availableRelease = null;
  let storeReadyVersion = null;
  let retryAction = 'check';
  let lastUpdateCheckAt = 0;
  let storeUpdateRequested = false;
  let storeReloadScheduled = false;
  document.getElementById('update-version').textContent = `v${currentVersion}`;
  let installedVersionCheck = null;
  let activatingInstalledUpdate = false;

  function activateInstalledUpdate() {
    if (activatingInstalledUpdate) return Promise.resolve(true);
    if (isStoreBuild || sending) return Promise.resolve(false);
    if (installedVersionCheck) return installedVersionCheck;
    installedVersionCheck = (async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch(chrome.runtime.getURL('manifest.json'), { cache: 'no-store', signal: controller.signal });
        if (!response.ok) return false;
        const installed = await response.json();
        if (/^\d+\.\d+\.\d+(?:\.\d+)?$/.test(installed.version || '') && installed.version !== currentVersion) {
          if (sending) return false;
          if (questionEl.value.trim() || attachments.length) {
            renderUpdate('installed-pending', `v${installed.version} 已安装。请先发送或清空当前输入和附件，再启用新版。`);
            return true;
          }
          activatingInstalledUpdate = true;
          renderUpdate('reloading', `正在启用已安装的 v${installed.version}…`);
          window.location.replace(chrome.runtime.getURL('launch.html'));
          return true;
        }
      } catch { /* A partial install must not interrupt the running workbench. */ }
      finally { clearTimeout(timer); }
      return false;
    })().finally(() => { installedVersionCheck = null; });
    return installedVersionCheck;
  }

  function releaseVersion(release) {
    const version = String(release?.tag_name || '').replace(/^v/, '');
    return /^\d+\.\d+\.\d+(?:\.\d+)?$/.test(version) && !release?.draft && !release?.prerelease
      ? version : null;
  }

  function renderUpdate(state, message = '') {
    updateState = state;
    bannerEl.dataset.state = state;
    const busy = ['checking', 'downloading', 'installing', 'reloading'].includes(state);
    updateButton.disabled = busy;
    bannerEl.setAttribute('aria-busy', String(busy));
    const latest = storeReadyVersion || releaseVersion(availableRelease);
    const labels = {
      checking: '正在检查…', downloading: '正在下载…', installing: '正在更新…',
      reloading: '正在重启…', error: '重试 / Retry', downloaded: '再次下载更新', 'installed-pending': '启用已安装新版'
    };
    updateButton.textContent = ['available', 'ready'].includes(state)
      ? `Update · v${latest}`
      : (labels[state] || '检查更新 / Check updates');
    updateButton.title = ['available', 'ready', 'downloaded'].includes(state)
      ? (isStoreBuild ? '更新并重新加载工作台' : '下载更新包，安装后自动启用新版本')
      : '检查 GitHub 最新正式版本';
    updateStatusEl.textContent = message;
  }

  function runUpdateTask(task) {
    if (updateTask || storeReloadScheduled) return updateTask;
    updateTask = Promise.resolve().then(task).finally(() => { updateTask = null; });
    return updateTask;
  }

  function isNewer(a, b) {
    const pa = String(a).split('.').map(Number);
    const pb = String(b).split('.').map(Number);
    if (!pa.length || !pb.length) return a !== b;
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const av = i < pa.length ? pa[i] : 0;
      const bv = i < pb.length ? pb[i] : 0;
      if (av !== bv) return av > bv;
    }
    return false;
  }

  function selectEdgeUpdateAsset(assets) {
    const expectedName = 'edge-extension.zip';
    return Array.isArray(assets)
      ? assets.find(asset => asset && asset.name === expectedName)
      : undefined;
  }

  async function fetchWithRetry(url, { attempts = 3, timeoutMs = 30000, responseType = 'json' } = {}) {
    let lastError;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const controller = new AbortController();
      let timedOut = false;
      const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
      try {
        const response = await fetch(url, { signal: controller.signal });
        if (!response.ok) {
          const error = new Error(`HTTP ${response.status}`);
          error.httpStatus = response.status;
          throw error;
        }
        // Consume the complete body while the AbortController timer is active;
        // returning a Response here would leave a half-open body unbounded.
        if (responseType === 'blob') return await response.blob();
        return await response.json();
      } catch (error) {
        lastError = timedOut ? Object.assign(new Error('请求超时'), { name: 'TimeoutError' }) : error;
      } finally {
        clearTimeout(timer);
      }
    }
    throw lastError || new Error('网络请求失败');
  }

  function updateCheckFailureMessage(error) {
    if (navigator.onLine === false) return '网络已断开，请联网后重试';
    if (error?.name === 'TimeoutError' || error?.name === 'AbortError') return '检查更新超时，请稍后重试';
    if (error?.httpStatus) return `更新服务暂时不可用（HTTP ${error.httpStatus}），请稍后重试`;
    if (error?.name === 'TypeError') return '无法连接更新服务，请检查网络后重试';
    return '更新信息暂时不可用，请稍后重试';
  }

  function releaseFromUpdateManifest(manifest) {
    const version = String(manifest?.version || '');
    const expectedURL = `https://github.com/${UPDATE_REPO}/releases/download/v${version}/edge-extension.zip`;
    if (manifest?.schemaVersion !== 1 || !/^\d+\.\d+\.\d+(?:\.\d+)?$/.test(version) ||
        manifest.edgeURL !== expectedURL || !/^[0-9a-f]{64}$/i.test(manifest.edgeSHA256 || '')) {
      throw new Error('发布更新清单无效');
    }
    return {
      tag_name: `v${version}`,
      body: typeof manifest.notes === 'string' ? manifest.notes : '',
      assets: [{
        name: 'edge-extension.zip',
        browser_download_url: expectedURL,
        digest: `sha256:${manifest.edgeSHA256.toLowerCase()}`
      }]
    };
  }

  async function fetchLatestRelease(attempts = 2) {
    try {
      const release = await fetchWithRetry(
        `https://api.github.com/repos/${UPDATE_REPO}/releases/latest`,
        { attempts, timeoutMs: 15000, responseType: 'json' }
      );
      if (!releaseVersion(release)) throw new Error('最新正式版信息无效');
      return release;
    } catch (primaryError) {
      // Release assets do not consume the shared unauthenticated API rate limit.
      // This official fallback is used only after the API failed, never for "no update".
      try {
        const manifest = await fetchWithRetry(
          `https://github.com/${UPDATE_REPO}/releases/latest/download/update.json`,
          { attempts: 1, timeoutMs: 15000, responseType: 'json' }
        );
        return releaseFromUpdateManifest(manifest);
      } catch {
        throw primaryError;
      }
    }
  }

  function expectedEdgeAssetSHA256(release, asset) {
    const direct = String(asset?.digest || '').replace(/^sha256:/i, '').toLowerCase();
    if (/^[0-9a-f]{64}$/.test(direct)) return direct;
    for (const line of String(release?.body || '').split(/\r?\n/)) {
      const match = line.match(/^SHA256\s+edge-extension\.zip\s+([0-9a-f]{64})\s*$/i);
      if (match) return match[1].toLowerCase();
    }
    return null;
  }

  async function sha256Hex(data) {
    const digest = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  }

  function reloadForStoreUpdate(version) {
    if (storeReloadScheduled) return;
    storeReloadScheduled = true;
    renderUpdate('reloading', `Edge 已准备 v${version || '新版'}，正在完成更新…`);
    setTimeout(async () => {
      try {
        const tab = await chrome.tabs.getCurrent();
        if (!Number.isInteger(tab?.id)) throw new Error('无法恢复当前工作台');
        const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
        const entryURLs = [chrome.runtime.getURL('workbench.html'), chrome.runtime.getURL('launch.html')];
        const tabIds = contexts.filter(context => context.frameId === 0 && entryURLs.includes(context.documentUrl))
          .map(context => context.tabId).filter(Number.isInteger).slice(0, 30);
        const workbenchTabIds = contexts.filter(context => context.frameId === 0 && context.documentUrl === entryURLs[0])
          .map(context => context.tabId).filter(id => tabIds.includes(id));
        await chrome.storage.local.set({ 'wb-pending-extension-reload': {
          tabId: tab.id, tabIds, workbenchTabIds, version, createdAt: Date.now()
        } });
        chrome.runtime.reload();
      } catch {
        storeReloadScheduled = false;
        storeUpdateRequested = false;
        retryAction = 'store';
        renderUpdate('error', '暂时无法准备更新，请重试');
      }
    }, 250);
  }

  chrome.runtime.onUpdateAvailable?.addListener((details) => {
    if (!isStoreBuild || storeReloadScheduled) return;
    storeReadyVersion = /^\d+\.\d+\.\d+(?:\.\d+)?$/.test(details?.version || '')
      ? details.version : (releaseVersion(availableRelease) || currentVersion);
    if (storeUpdateRequested) {
      reloadForStoreUpdate(storeReadyVersion);
      return;
    }
    renderUpdate('ready', 'Edge 已下载更新，点击完成安装');
  });

  async function requestStoreUpdate(latest) {
    storeUpdateRequested = true;
    renderUpdate('installing', '正在通过 Edge 检查并安装更新…');
    let timer;
    try {
      const result = await Promise.race([
        chrome.runtime.requestUpdateCheck(),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Edge 更新检查超时')), 15000); })
      ]);
      if (storeReloadScheduled) return;
      if (result?.status === 'update_available') {
        reloadForStoreUpdate(result.version || latest);
      } else {
        storeUpdateRequested = false;
        retryAction = 'store';
        renderUpdate('error', result?.status === 'throttled'
          ? 'Edge 正在同步更新，请稍后再试'
          : 'Edge 商店版本正在同步，请稍后再试');
      }
    } catch {
      storeUpdateRequested = false;
      if (!storeReloadScheduled) {
        retryAction = 'store';
        renderUpdate('error', 'Edge 更新检查暂时不可用，请稍后再试');
      }
    } finally {
      clearTimeout(timer);
    }
  }

  async function downloadUpdate() {
    renderUpdate('downloading', '正在下载新版本并校验…');
    try {
      const zrel = await fetchLatestRelease(3);
      const latest = releaseVersion(zrel);
      if (!latest || !isNewer(latest, currentVersion)) throw new Error('没有可安装的新版正式包');
      const asset = selectEdgeUpdateAsset(zrel.assets);
      if (!asset) throw new Error('Release 缺少 edge-extension.zip');
      const expectedSHA256 = expectedEdgeAssetSHA256(zrel, asset);
      if (!expectedSHA256) throw new Error('Release 缺少有效 SHA-256');
      const blob = await fetchWithRetry(asset.browser_download_url, {
        attempts: 3,
        timeoutMs: 60000,
        responseType: 'blob'
      });
      const actualSHA256 = await sha256Hex(await blob.arrayBuffer());
      if (actualSHA256 !== expectedSHA256) throw new Error('更新包 SHA-256 不匹配');
      const a = document.createElement('a');
      const objectURL = URL.createObjectURL(blob);
      a.href = objectURL;
      a.download = asset.name;
      a.click();
      setTimeout(() => URL.revokeObjectURL(objectURL), 60000);
      availableRelease = zrel;
      renderUpdate('downloaded', `v${latest} 已下载并校验。解压后运行 install.bat，或直接重启智囊（桌面图标）自动完成更新。`);
    } catch (error) {
      retryAction = 'download';
      renderUpdate('error', '下载失败，请重试。未安装任何文件。');
      console.warn('更新包下载失败', error);
    }
  }

  function checkUpdate({ automatic = false } = {}) {
    if (storeReadyVersion || storeReloadScheduled || updateTask) return updateTask;
    if (automatic && lastUpdateCheckAt && Date.now() - lastUpdateCheckAt < UPDATE_FOCUS_THROTTLE_MS) return;
    lastUpdateCheckAt = Date.now();
    return runUpdateTask(async () => {
      if (await activateInstalledUpdate()) return;
      renderUpdate('checking', '正在检查最新版本…');
      try {
        const rel = await fetchLatestRelease();
        if (storeReadyVersion || storeReloadScheduled) return;
        const latest = releaseVersion(rel);
        if (!latest) throw new Error('最新正式版信息无效');
        availableRelease = isNewer(latest, currentVersion) ? rel : null;
        if (availableRelease) {
          renderUpdate('available', isStoreBuild
            ? '发现新版本，点击通过 Edge 更新'
            : '发现新版本，重启智囊（桌面图标）将自动更新；也可点击下载更新包');
        } else {
          renderUpdate('current', '已是最新版');
        }
      } catch (error) {
        if (!storeReadyVersion && !storeReloadScheduled) {
          retryAction = 'check';
          renderUpdate('error', updateCheckFailureMessage(error));
        }
      }
    });
  }

  updateButton.addEventListener('click', () => {
    if (storeReloadScheduled) return;
    if (storeReadyVersion) { reloadForStoreUpdate(storeReadyVersion); return; }
    if (updateTask) return;
    if (['available', 'downloaded'].includes(updateState) || (updateState === 'error' && retryAction !== 'check')) {
      runUpdateTask(() => isStoreBuild
        ? requestStoreUpdate(releaseVersion(availableRelease))
        : downloadUpdate());
    } else {
      checkUpdate();
    }
  });

  function checkUpdateOnForeground() {
    if (document.visibilityState === 'visible') {
      activateInstalledUpdate().then(activating => {
        if (!activating) checkUpdate({ automatic: true });
      });
    }
  }
  window.addEventListener('focus', checkUpdateOnForeground);
  document.addEventListener('visibilitychange', checkUpdateOnForeground);
  renderUpdate('idle');

  // —— 启动：立即显示品牌加载层；完成本地初始化后淡出，不做人为延迟。——
  const startupOverlay = document.getElementById('startup-overlay');
  const startupText = document.getElementById('startup-text');
  try {
    await activateInstalledUpdate();
    if (activatingInstalledUpdate) return;
    const [, preferencesRestored] = await Promise.all([registerWorkbenchChannel(), restorePreferences()]);
    renderChecks();
    renderPanes();
    preferencesReady = preferencesRestored;
    if (preferencesReady) {
      persistPreferences(); // Canonicalize first-use, legacy-corrupt and unknown-adapter data.
    } else {
      console.warn('偏好存储读取失败：本次运行不会覆盖原记录');
    }
    setInterval(probeAll, 8000);
    setTimeout(probeAll, 3000);
    setTimeout(() => checkUpdate({ automatic: true }), 5000);
    setInterval(() => checkUpdate({ automatic: true }), UPDATE_INTERVAL_MS);
    requestAnimationFrame(() => {
      startupOverlay?.classList.add('done');
      setTimeout(() => startupOverlay?.remove(), 260);
    });
  } catch (error) {
    if (startupText) startupText.textContent = '启动失败，请在 edge://extensions 重新加载扩展';
    startupOverlay?.classList.add('startup-error');
    console.error('Parallel Workbench startup failed', error);
  }
})();
