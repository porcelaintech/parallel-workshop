// 智囊内嵌网页适配（WKUserScript，documentStart 注入，主框架）：
// 1) 字体统一：英文字母/数字/ASCII 标点用 Helvetica；中文汉字与全角标点用宋体（SimSun，
//    缺失时按序回退 Songti SC（macOS 内置宋体-简）→ sans-serif）。
//    只作用于继承链上的文本元素与表单控件，不覆盖站点自身的图标字体/SVG 图标/公式字体。
// 2) 站点级推广内容精简：只隐藏明确的推广/装饰区块（display:none，随时可恢复），
//    保留登录、对话输入、模型切换、附件与模型设置等功能入口。
// 样式节点被 SPA 重建移除时由 MutationObserver 自动恢复；规则表暴露给验收审计。
(() => {
  'use strict';
  const STYLE_ID = '__wb_theme_style__';

  // html body 前缀提高优先级（站点样式的类选择器带 !important 时仍可能压过，属可接受残留）
  const BASE_CSS = [
    "html body { font-family: Helvetica, SimSun, 'Songti SC', sans-serif !important; }",
    // 表单控件直接给定字体（inherit 会继承到站点给父级设置的字体，形同虚设）；
    // 图标 span 仍用自己的字体规则
    "html body input, html body textarea, html body select { font-family: Helvetica, SimSun, 'Songti SC', sans-serif !important; }",
    "html body input::placeholder, html body textarea::placeholder { font-family: Helvetica, SimSun, 'Songti SC', sans-serif !important; }",
    "html body button { font-family: inherit !important; }",
    "html body [contenteditable='true'], html body [role='textbox'] { font-family: inherit !important; }"
  ].join('\n');

  // 站点级精简规则：host → 规则数组。
  // css：CSS 隐藏（选择器稳定时使用）；text：按叶子元素可见文本精确匹配后，
  // 隐藏该元素及其上层 up 级祖先（应对动态类名）。只匹配叶子节点，避免把含登录等
  // 功能入口的大容器误伤；登录、对话输入、模型切换、附件、项目/插件入口一律保留。
  const SITE_RULES = {
    'www.doubao.com': {
      css: [],
      text: [
        // 「下载电脑版」推广按钮：叶子(文案 span) → button → div.relative → container 容器
        { text: '下载电脑版', exact: true, up: 3 },
        // 弹窗推广「下载电脑版 新用户领 30 天订阅权益」：从标题起隐藏整个弹层
        { text: '新用户领', exact: false, up: 3, all: true },
        // 空白首页「为你推荐」推荐问题区域：从标题叶子起隐藏其所在区块
        { text: '为你推荐', exact: true, up: 1 }
      ]
    },
    'www.kimi.com': {
      css: [
        // 「Download for Desktop」推广入口（类名稳定，仅桌面下载相关；不动项目/插件入口）
        'button.desktop-download-entry'
      ],
      text: []
    },
    'www.tongyi.com': {
      css: [],
      text: [
        // 头部「下载电脑端」推广按钮（保留旁边的 API 服务入口）
        { text: '下载电脑端', exact: true, up: 2 },
        // 首页 Qwen4 宣传卡片（每张卡片独立隐藏）
        { text: 'Qwen4', exact: false, up: 4, all: true }
      ]
    },
    'www.qianwen.com': {
      css: [],
      text: [
        { text: '下载电脑端', exact: true, up: 2 },
        { text: 'Qwen4', exact: false, up: 4, all: true }
      ]
    },
    'chatgpt.com': {
      css: [
        // 输入框字体（站点对 composer 有高优先级规则；含未登录首页的移动端输入框）
        'html body textarea#prompt-textarea[class], html body textarea#mobile-composer-prompt[class], html body textarea[id*="composer"][class] { font-family: inherit !important; }',
        'html body textarea#prompt-textarea[class]::placeholder, html body textarea#mobile-composer-prompt[class]::placeholder, html body textarea[id*="composer"][class]::placeholder { font-family: inherit !important; }'
      ],
      text: [],
      fontInline: ['textarea#prompt-textarea', 'textarea#mobile-composer-prompt', 'textarea[id*="composer"]']
    },
    'wenxin.baidu.com': {
      css: [
        // 文心输入框与按钮（站点规则带 !important，用 id/属性叠层提高优先级；直接给字体而非 inherit）
        'html body textarea#chat-textarea[class], html body textarea.ci-textarea[class] { font-family: Helvetica, SimSun, \'Songti SC\', sans-serif !important; }',
        'html body textarea#chat-textarea[class]::placeholder, html body textarea.ci-textarea[class]::placeholder { font-family: Helvetica, SimSun, \'Songti SC\', sans-serif !important; }',
        'html body button[class][class][class], html body a[class][class][class], html body span[class][class][class] { font-family: Helvetica, SimSun, \'Songti SC\', sans-serif !important; }'
      ],
      text: [],
      fontInline: ['textarea#chat-textarea', 'textarea.ci-textarea', 'button', 'a']
    }
  };

  function siteRules() {
    return SITE_RULES[location.hostname] || { css: [], text: [], fontInline: [] };
  }

  function siteCSS() {
    const rules = siteRules();
    return rules.css.map((sel) => {
      // 含 '{' 视为完整 CSS 规则；否则视为选择器 → display:none
      return sel.includes('{') ? sel : sel + '{display:none !important;}';
    }).join('\n');
  }

  // 内联字体兜底：站点规则带 !important 或更高优先级时，直接对目标元素写内联
  // font-family（内联样式优先于一切样式表），保证输入框/按钮文字逐字命中 Helvetica/宋体。
  function enforceInlineFonts(root) {
    const selectors = siteRules().fontInline || [];
    if (!selectors.length) return;
    const family = "Helvetica, SimSun, 'Songti SC', sans-serif";
    for (const sel of selectors) {
      let els = [];
      try { els = Array.from(root.querySelectorAll(sel)); } catch (e) { continue; }
      for (const el of els) {
        if (el.style && el.style.fontFamily !== family) {
          el.style.setProperty('font-family', family, 'important');
        }
      }
    }
  }

  // 文本匹配隐藏：
  // - 单条规则：取文本命中的最深小元素（子元素最多者，通常是实际按钮），隐藏它及上层 up 级祖先；
  // - all 规则：每个叶子候选各自隐藏（用于多张同构卡片）。
  // 已隐藏的跳过，避免误伤含登录等功能入口的大容器。
  function hideMatched(root) {
    const rules = siteRules().text || [];
    if (!rules.length) return;
    const singles = new Map();   // rule -> best element
    const allTargets = [];       // {el, up} 逐条应用
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let n;
    while ((n = walker.nextNode())) {
      if (n.dataset.wbPromoHidden) continue;
      const t = (n.textContent || '').trim();
      if (!t || t.length > 80) continue;
      for (const r of rules) {
        const hit = r.exact ? t === r.text : t.includes(r.text);
        if (!hit) continue;
        if (r.all) {
          if (n.children.length <= 1) allTargets.push({ el: n, up: r.up || 0 });
        } else if (n.children.length <= 2) {
          const prev = singles.get(r);
          if (!prev || n.children.length > prev.children.length) singles.set(r, n);
        }
        break;
      }
    }
    const applyHide = (start, up) => {
      let target = start;
      for (let i = 0; i < up && target.parentElement
           && target.parentElement !== document.body
           && target.parentElement !== document.documentElement; i++) {
        target = target.parentElement;
      }
      // 安全守卫：绝不隐藏 body/html，也绝不隐藏包含输入编辑器/文本框的容器
      // （防止规则走位过远把整个应用根节点藏掉）
      if (!target || target === document.body || target === document.documentElement) return;
      if (typeof target.querySelector === 'function'
          && target.querySelector('textarea, [contenteditable="true"], input[type="text"], input:not([type])')) return;
      if (target.dataset.wbPromoHidden) return;
      target.dataset.wbPromoHidden = '1';
      target.style.setProperty('display', 'none', 'important');
    };
    for (const [rule, el] of singles) applyHide(el, rule.up || 0);
    for (const item of allTargets) applyHide(item.el, item.up);
  }

  function apply() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = BASE_CSS + '\n' + siteCSS();
    (document.head || document.documentElement).appendChild(style);
  }

  apply();
  if (document.body) {
    hideMatched(document.body);
    enforceInlineFonts(document.body);
  }

  // SPA 渲染：防抖监听子树变化，对新出现的节点执行文本规则与内联字体
  let timer = null;
  const bodyObs = new MutationObserver(() => {
    apply();
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      if (document.body) {
        hideMatched(document.body);
        enforceInlineFonts(document.body);
      }
    }, 400);
  });
  bodyObs.observe(document.documentElement, { childList: true, subtree: true });

  // 验收审计接口
  try { window.__wbThemeRules = SITE_RULES; } catch (_) {}
})();
