// DeepSeek model preference bridge.
//
// DeepSeek's current model switcher exposes stable semantic attributes:
//   [data-model-type][role="radio"][aria-checked="true|false"]
// The app's in-memory store intentionally resets to the default model for a new
// session, so preserve only the opaque model_type (never labels, prompts or auth).
(() => {
  if (location.hostname !== 'chat.deepseek.com' ||
      window.__pwbModelPreferenceBridgeInstalled) return;
  window.__pwbModelPreferenceBridgeInstalled = true;

  const STORAGE_KEY = '__parallelWorkbench.deepseekModelPreference.v1';
  const ITEM_SELECTOR = '[data-model-type][role="radio"]';
  const TYPE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
  let savedModelType = null;
  let userInteractionUntil = 0;
  let lastRestoreAttempt = 0;
  let mutationTimer = 0;

  function validType(value) {
    return typeof value === 'string' && TYPE_PATTERN.test(value) ? value : null;
  }

  function readSaved() {
    try {
      const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
      return parsed && parsed.version === 1 ? validType(parsed.modelType) : null;
    } catch {
      return null;
    }
  }

  function selectedItem() {
    return document.querySelector(`${ITEM_SELECTOR}[aria-checked="true"]`);
  }

  function saveCurrentSelection() {
    const modelType = validType(selectedItem()?.dataset?.modelType);
    if (!modelType) return;
    savedModelType = modelType;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: 1, modelType }));
    } catch {}
  }

  function withinModelSwitcher(target) {
    const element = target instanceof Element ? target : null;
    if (element?.closest(ITEM_SELECTOR)) return true;
    const group = element?.closest('[role="radiogroup"]');
    return !!group?.querySelector(ITEM_SELECTOR);
  }

  function noteTrustedChoice(event) {
    if (!event.isTrusted || !withinModelSwitcher(event.target)) return;
    userInteractionUntil = Date.now() + 1200;
    // React commits aria-checked synchronously or on the next microtask/frame.
    setTimeout(saveCurrentSelection, 0);
    setTimeout(saveCurrentSelection, 120);
  }

  function restoreSavedSelection() {
    if (!savedModelType || Date.now() < userInteractionUntil) return;
    const items = Array.from(document.querySelectorAll(ITEM_SELECTOR));
    const target = items.find(item => validType(item.dataset?.modelType) === savedModelType);
    if (!target || target.getAttribute('aria-checked') === 'true') return;
    const now = Date.now();
    if (now - lastRestoreAttempt < 600) {
      setTimeout(restoreSavedSelection, 610 - (now - lastRestoreAttempt));
      return;
    }
    lastRestoreAttempt = now;
    target.click();
  }

  function scheduleRestore() {
    clearTimeout(mutationTimer);
    mutationTimer = setTimeout(restoreSavedSelection, 60);
  }

  savedModelType = readSaved();
  document.addEventListener('click', noteTrustedChoice, true);
  document.addEventListener('pointerup', noteTrustedChoice, true);
  document.addEventListener('keyup', noteTrustedChoice, true);

  const observer = new MutationObserver(scheduleRestore);
  const observeRoot = () => {
    if (!document.documentElement) {
      setTimeout(observeRoot, 0);
      return;
    }
    observer.observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['aria-checked', 'data-model-type']
    });
    scheduleRestore();
  };
  observeRoot();
  // Keep a low-frequency guard because DeepSeek resets its in-memory selection
  // after creating a new session without necessarily replacing the DOM nodes.
  setInterval(restoreSavedSelection, 2500);
})();
