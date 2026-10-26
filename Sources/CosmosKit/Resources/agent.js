// Cosmos page agent: runs in an isolated world in every frame, reports page facts to the browser.
// It never modifies page content and exposes nothing to the page's own scripts.
(function () {
  'use strict';
  const post = (m) => { try { window.webkit.messageHandlers.cosmos.postMessage(m); } catch (e) {} };
  const isTop = window.top === window;

  // Icons + theme colour, reported once the document is usable and again when <head> changes.
  function reportMeta() {
    if (!isTop) return;
    const icons = Array.from(document.querySelectorAll('link[rel~="icon" i], link[rel="apple-touch-icon" i], link[rel="apple-touch-icon-precomposed" i], link[rel="mask-icon" i]'))
      .map(l => ({ href: l.href, sizes: l.getAttribute('sizes') || '', rel: l.getAttribute('rel') || '', type: l.getAttribute('type') || '' }))
      .filter(i => i.href);
    const theme = document.querySelector('meta[name="theme-color"]');
    post({ type: 'meta', icons, themeColor: theme ? theme.content : null, title: document.title });
  }
  let metaTimer = null;
  const scheduleMeta = () => { clearTimeout(metaTimer); metaTimer = setTimeout(reportMeta, 150); };
  document.addEventListener('DOMContentLoaded', () => {
    reportMeta();
    if (isTop && document.head) new MutationObserver(scheduleMeta).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'content', 'rel'] });
  });
  window.addEventListener('load', reportMeta);

  // Media: is anything audible / is there playable video?
  const media = new Set();
  function reportMedia() {
    let playing = false, video = false, pip = false;
    media.forEach(el => {
      if (!el.isConnected) { media.delete(el); return; }
      if (!el.paused && !el.ended && el.readyState > 2) {
        if (el.tagName === 'VIDEO') video = true;
        if (!el.muted && el.volume > 0) playing = true;
      }
    });
    post({ type: 'media', playing, video, frame: isTop ? 'top' : 'sub' });
  }
  const mediaEvents = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'waiting'];
  mediaEvents.forEach(ev => document.addEventListener(ev, e => {
    if (e.target instanceof HTMLMediaElement) { media.add(e.target); reportMedia(); }
  }, true));

  // What is under the pointer on right click / hover (for the context menu and the status bubble).
  function linkOf(node) { while (node && node !== document) { if (node.tagName === 'A' && node.href) return node; node = node.parentNode; } return null; }
  // Capturing, so it runs before the page's own handlers; it only reports and never calls preventDefault, so a site
  // that draws its own right-click menu keeps it (and then WebKit shows no system menu for Cosmos to replace).
  const editableOf = (n) => !!(n && (n.isContentEditable || (n.closest && n.closest('input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]), textarea, [contenteditable=""], [contenteditable="true"]'))));
  const mediaOf = (n) => !!(n && n.closest && n.closest('video, audio'));
  document.addEventListener('contextmenu', e => {
    const a = linkOf(e.target);
    const img = e.target && e.target.tagName === 'IMG' ? e.target.currentSrc || e.target.src : null;
    post({ type: 'context', link: a ? a.href : null, image: img, selection: String(window.getSelection() || '').slice(0, 2000),
           editable: editableOf(e.target), media: mediaOf(e.target), x: e.clientX, y: e.clientY });
  }, true);
  // Force Touch: pressing hard on a link opens it in Peek, like ⇧-click. Only real presses count (a page can
  // dispatch these events itself), and the system's own link preview is switched off for links.
  document.addEventListener('webkitmouseforcewillbegin', e => { if (e.isTrusted && linkOf(e.target)) e.preventDefault(); }, true);
  document.addEventListener('webkitmouseforcedown', e => {
    const a = e.isTrusted ? linkOf(e.target) : null;
    if (a) post({ type: 'peekLink', href: a.href });
  }, true);
  let lastHover = null;
  document.addEventListener('mouseover', e => {
    const a = linkOf(e.target);
    const h = a ? a.href : null;
    if (h !== lastHover) { lastHover = h; post({ type: 'hover', href: h }); }
  }, true);
  document.addEventListener('mouseleave', () => { if (lastHover) { lastHover = null; post({ type: 'hover', href: null }); } }, true);

  // Per-tab mute (the sidebar speaker button). Media elements only: WebAudio-only pages are not affected.
  let muted = false;
  const applyMute = () => document.querySelectorAll('video, audio').forEach(el => { if (muted) { el.dataset.cosmosWasMuted = el.muted ? '1' : '0'; el.muted = true; } else if (el.dataset.cosmosWasMuted !== undefined) { el.muted = el.dataset.cosmosWasMuted === '1'; delete el.dataset.cosmosWasMuted; } });
  window.__cosmosMute = (v) => { muted = !!v; applyMute(); };
  document.addEventListener('play', e => { if (muted && e.target instanceof HTMLMediaElement) applyMute(); }, true);

  // Modified clicks are handled natively; plain clicks on target=_blank links go through createWebView.
  // Keyboard: Escape closes overlays the browser owns even while a page has focus.
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && isTop) post({ type: 'escape' });
  }, true);
})();
