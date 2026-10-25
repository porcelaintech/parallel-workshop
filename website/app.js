(() => {
  const $ = (id) => document.getElementById(id);
  const manifestURL = 'updates/local-service-update.json';
  const releasePage = 'https://github.com/porcelaintech/parallel-workshop/releases';
  const isInternal = (version) => /^0\.(?:0|5)\./.test(String(version || ''));
  const buttonsFor = (platform) => platform === 'macos'
    ? ['download-macos', 'download-macos-card']
    : ['download-windows', 'download-windows-card'];
  const labelFor = (platform) => platform === 'macos' ? 'macOS' : 'Windows';

  const header = document.querySelector('.site-header');
  const onScroll = () => header?.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  const toggle = document.querySelector('.nav-toggle');
  const links = document.querySelector('.nav-links');
  toggle?.addEventListener('click', () => {
    const open = links.classList.toggle('open');
    toggle.setAttribute('aria-expanded', String(open));
  });
  links?.querySelectorAll('a').forEach((a) => a.addEventListener('click', () => links.classList.remove('open')));

  const setPreparing = (message) => {
    for (const platform of ['macos', 'windows']) {
      for (const id of buttonsFor(platform)) {
        const el = $(id);
        if (!el) continue;
        el.classList.add('is-disabled');
        el.setAttribute('aria-disabled', 'true');
        el.removeAttribute('href');
        el.textContent = `${labelFor(platform)} 准备中`;
      }
      const state = $(`state-${platform}`);
      if (state) {
        state.classList.add('preparing');
        state.innerHTML = `<span class="dot"></span>${message}`;
      }
    }
    const note = $('release-note');
    if (note) {
      note.textContent = '当前为 0.6.0 预览站。macOS 和 Windows 安装包分别发布到 GitHub Release 后，这里的两个下载入口会自动开放。';
      note.classList.add('show');
    }
  };

  const setAvailable = (manifest) => {
    const version = String(manifest.version || '');
    const artifacts = { macos: manifest.artifacts?.['darwin-universal'], windows: manifest.artifacts?.['win32-x64'] };
    for (const platform of ['macos', 'windows']) {
      const artifact = artifacts[platform];
      const state = $(`state-${platform}`);
      if (!state) continue;
      if (!artifact?.url) {
        state.classList.add('preparing');
        state.innerHTML = `<span class="dot"></span>暂无 ${labelFor(platform)} 安装包`;
        for (const id of buttonsFor(platform)) {
          const el = $(id);
          if (!el) continue;
          el.classList.add('is-disabled');
          el.setAttribute('aria-disabled', 'true');
          el.removeAttribute('href');
          el.textContent = '暂不可用';
        }
        continue;
      }
      state.classList.remove('preparing');
      state.innerHTML = `<span class="dot"></span>v${version} · 已发布`;
      for (const id of buttonsFor(platform)) {
        const el = $(id);
        if (!el) continue;
        el.classList.remove('is-disabled');
        el.removeAttribute('aria-disabled');
        el.href = `download/${platform}/`;
        el.textContent = `下载 ${labelFor(platform)} 版`;
      }
      const file = $(`file-${platform}`);
      if (file) file.textContent = artifact.url.split('/').pop();
      const sha = $(`sha-${platform}`);
      if (sha && artifact.sha256) {
        sha.textContent = `SHA-256 ${artifact.sha256.slice(0, 12)}…${artifact.sha256.slice(-8)}`;
        sha.title = artifact.sha256;
      }
    }
    const versionLabel = $('version-label');
    if (versionLabel) versionLabel.textContent = `v${version}`;
    const note = $('release-note');
    if (note && manifest.publishedAt) {
      note.textContent = `v${version} 发布于 ${new Date(manifest.publishedAt).toLocaleDateString('zh-CN')}。macOS 与 Windows 使用独立安装包，更新索引由 braintrust.chat 提供。`;
      note.classList.add('show');
    }
  };

  (async () => {
    try {
      const response = await fetch(`${manifestURL}?t=${Date.now()}`, { cache: 'no-store' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const manifest = await response.json();
      if (!manifest?.version || isInternal(manifest.version)) {
        setPreparing('内测版，暂不公开下载');
        return;
      }
      setAvailable(manifest);
    } catch {
      setPreparing('0.6.0 正在准备中');
    }
  })();

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const text = button.getAttribute('data-copy');
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        const old = button.textContent;
        button.textContent = '已复制';
        setTimeout(() => { button.textContent = old; }, 1400);
      } catch {}
    });
  });

  document.querySelectorAll('[data-release-link]').forEach((a) => {
    a.href = releasePage;
  });
})();
