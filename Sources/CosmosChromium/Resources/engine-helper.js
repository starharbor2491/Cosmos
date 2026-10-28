// Runs in Cosmos's isolated world next to the page agent. It covers what Chromium draws itself when it has a window and
// does not draw headless: the pointer's shape, <select> menus, where the text caret is, and the page's title (Chromium
// only reports it when the page loads, not when the page changes it). Pages cannot see it.
(function () {
  'use strict';
  if (window.__cosmosEngine) return;
  window.__cosmosEngine = true;
  const post = (m) => { try { __cosmosPost(JSON.stringify(m)); } catch (e) {} };
  const isTop = window.top === window;

  const editable = 'input:not([type=button]):not([type=submit]):not([type=reset]):not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]):not([type=file]), textarea';
  let lastCursor = '';
  document.addEventListener('mousemove', e => {
    const t = e.target;
    let c = 'auto';
    try { c = getComputedStyle(t).cursor; } catch (err) { /* not an element */ }
    if (c === 'auto') {
      if (t && (t.isContentEditable || (t.closest && t.closest(editable)))) c = 'text';
      else if (t && t.closest && t.closest('a[href]')) c = 'pointer';
      else c = 'default';
    }
    if (c !== lastCursor) { lastCursor = c; post({ type: '__cursor', value: c }); }
  }, true);

  // A drop-down <select> opens a menu Cosmos draws. Only a real press does (a page can send mousedown itself).
  const selects = new Map();
  let nextSelect = 1;
  document.addEventListener('mousedown', e => {
    const s = e.target && e.target.closest ? e.target.closest('select') : null;
    if (!s || s.multiple || s.size > 1 || s.disabled || e.button !== 0 || !e.isTrusted) return;
    e.preventDefault();
    s.focus();
    const id = nextSelect++;
    selects.clear();
    selects.set(id, new WeakRef(s));
    const r = s.getBoundingClientRect();
    const options = Array.from(s.options).map(o => {
      const group = o.parentElement && o.parentElement.tagName === 'OPTGROUP' ? o.parentElement : null;
      return { label: o.label || o.text, disabled: o.disabled || !!(group && group.disabled), group: group ? group.label : null };
    });
    post({ type: '__select', id, options, selected: s.selectedIndex, x: r.left, y: r.bottom, width: r.width, top: isTop });
  }, true);
  window.__cosmosChoose = (id, index) => {
    const ref = selects.get(id);
    const s = ref && ref.deref();
    selects.clear();
    if (!s || index < 0 || index >= s.options.length || s.selectedIndex === index) return;
    s.selectedIndex = index;
    s.dispatchEvent(new Event('input', { bubbles: true }));
    s.dispatchEvent(new Event('change', { bubbles: true }));
  };

  if (isTop) {
    let lastTitle = null;
    const reportTitle = () => { const t = document.title; if (t !== lastTitle) { lastTitle = t; post({ type: '__title', value: t }); } };
    const watchTitle = () => {
      reportTitle();
      new MutationObserver(reportTitle).observe(document.head || document.documentElement, { subtree: true, childList: true, characterData: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchTitle, { once: true }); else watchTitle();
    document.addEventListener('fullscreenchange', () => post({ type: '__fullscreen', value: !!document.fullscreenElement }));
    document.addEventListener('focusin', e => {
      const t = e.target;
      if (!t || !t.getBoundingClientRect) return;
      const r = t.getBoundingClientRect();
      post({ type: '__caret', x: r.left, y: r.top, height: Math.min(r.height, 40) });
    }, true);
  }

  // The selected text, for Copy (a text field's own selection is not in getSelection()).
  window.__cosmosSelection = () => {
    const a = document.activeElement;
    if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') && typeof a.selectionStart === 'number') {
      return a.value.substring(a.selectionStart, a.selectionEnd);
    }
    return String(window.getSelection() || '');
  };
})();
