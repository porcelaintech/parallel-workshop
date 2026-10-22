(() => {
  const cfg = window.__BRAINTRUST_CONFIG__ || {};
  const headers = { authorization: `Bearer ${cfg.token}`, 'content-type': 'application/json' };
  const $ = id => document.getElementById(id);
  const state = { platforms: [], selected: [], update: null };
  async function api(path, options = {}) {
    const response = await fetch(path, { ...options, headers: { ...headers, ...(options.headers || {}) } });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
    return body;
  }
  function render() {
    $('version').textContent = `v${cfg.version || ''}`;
    $('platforms').innerHTML = state.platforms.map(p => `<label><input type="checkbox" data-id="${p.id}" ${state.selected.includes(p.id) ? 'checked' : ''}> ${p.name}</label>`).join('');
    $('platforms').querySelectorAll('input').forEach(input => input.addEventListener('change', () => { state.selected = [...$('platforms').querySelectorAll('input:checked')].map(i => i.dataset.id); localStorage.setItem('braintrust.selectedPlatforms', JSON.stringify(state.selected)); renderCards(); }));
    renderCards();
  }
  function renderCards() {
    $('cards').innerHTML = state.platforms.map(p => `<article class="card"><h3>${p.name}</h3><p>${new URL(p.origin).hostname}</p><p id="badge-${p.id}">尚未打开</p><button class="secondary" data-open="${p.id}">打开平台</button></article>`).join('');
    $('cards').querySelectorAll('[data-open]').forEach(button => button.addEventListener('click', () => openPlatform(button.dataset.open, button)));
  }
  async function openPlatform(id, button) {
    button.disabled = true; button.textContent = '正在打开…';
    try { await api(`/api/platforms/${id}/open`, { method: 'POST', body: '{}' }); $(`badge-${id}`).textContent = '已在浏览器打开'; button.textContent = '重新打开'; }
    catch (error) { $(`badge-${id}`).textContent = error.message; button.textContent = '重试'; }
    finally { button.disabled = false; }
  }
  async function refreshProbes() {
    for (const platform of state.platforms) {
      try { const result = await api(`/api/platforms/${platform.id}/probe`); const badge = $(`badge-${platform.id}`); if (badge && result.state !== 'not-open') badge.textContent = ({ ready: '就绪', 'login-required': '需要登录', challenge: '需要人工验证', 'input-not-found': '未找到输入框', 'no-response': '无响应' })[result.state] || result.state; } catch {}
    }
  }
  $('open-all').addEventListener('click', async () => { for (const id of state.selected) { const button = document.querySelector(`[data-open="${id}"]`); if (button) await openPlatform(id, button); } });
  $('send').addEventListener('click', async () => {
    const text = $('question').value.trim(); if (!text) return;
    $('send').disabled = true; $('send').textContent = '发送中…';
    try {
      const attachments = await Promise.all([...$('attachments').files].map(file => new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve({ name: file.name, mime: file.type || 'application/octet-stream', data: String(reader.result).split(',', 2)[1] || '' }); reader.onerror = reject; reader.readAsDataURL(file); })));
      const result = await api('/api/send', { method: 'POST', body: JSON.stringify({ text, platforms: state.selected, attachments }) }); $('log').textContent = JSON.stringify(result.results, null, 2);
    }
    catch (error) { $('log').textContent = error.message; }
    finally { $('send').disabled = false; $('send').textContent = '发送'; }
  });
  $('question').addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') $('send').click(); });
  $('check-update').addEventListener('click', async () => {
    const button = $('check-update');
    button.disabled = true; $('update-text').textContent = '检查中…';
    try {
      if (state.update?.state === 'available') {
        $('update-text').textContent = '下载中…';
        const downloaded = await api('/api/update/download', { method: 'POST', body: JSON.stringify({ manifest: state.update.manifest, artifact: state.update.artifact }) });
        $('update-text').textContent = `已下载到本地：${downloaded.path}`;
        state.update = null; button.textContent = '检查更新';
      } else {
        const result = await api('/api/update/check', { method: 'POST', body: '{}' });
        state.update = result;
        if (result.state === 'available') { $('update-text').textContent = `发现 v${result.latestVersion}`; button.textContent = '下载更新'; }
        else { $('update-text').textContent = `当前 v${result.currentVersion} 已是最新`; button.textContent = '检查更新'; }
      }
    } catch (error) { $('update-text').textContent = error.message; }
    finally { button.disabled = false; }
  });
  async function boot() { try { const health = await api('/api/health'); $('status-text').textContent = health.browser.running ? '本地服务和浏览器已就绪' : '本地服务已就绪'; $('status-dot').className = 'status-dot'; const data = await api('/api/platforms'); state.platforms = data.platforms; try { state.selected = JSON.parse(localStorage.getItem('braintrust.selectedPlatforms') || 'null') || data.selected; } catch { state.selected = data.selected; } render(); refreshProbes(); setInterval(refreshProbes, 7000); } catch (error) { $('status-text').textContent = error.message; $('status-dot').className = 'status-dot bad'; } }
  boot();
})();
