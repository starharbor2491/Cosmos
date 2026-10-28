// Cosmos page agent: runs in Cosmos's own isolated world in every frame and reports page facts to the browser.
// It never modifies page content and exposes nothing to the page's own scripts: `__cosmosPost` only exists in this world.
(function () {
  'use strict';
  const post = (m) => { try { __cosmosPost(JSON.stringify(m)); } catch (e) { /* Cosmos is not listening */ } };
  const isTop = window.top === window;
  let config = { peekCrossSite: false };
  window.__cosmosConfig = (c) => { config = Object.assign(config, c || {}); };
  if (isTop) post({ type: 'ready' });

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

  // Media: is anything audible / is there playable video? Each frame reports for itself, under its own name.
  const frameName = isTop ? 'top' : 'sub-' + Math.random().toString(36).slice(2);
  const media = new Set();
  function reportMedia() {
    let playing = false, video = false;
    media.forEach(el => {
      if (!el.isConnected) { media.delete(el); return; }
      if (!el.paused && !el.ended && el.readyState > 2) {
        if (el.tagName === 'VIDEO') video = true;
        if (!el.muted && el.volume > 0) playing = true;
      }
    });
    post({ type: 'media', playing, video, frame: frameName });
  }
  const mediaEvents = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'waiting'];
  mediaEvents.forEach(ev => document.addEventListener(ev, e => {
    if (e.target instanceof HTMLMediaElement) { media.add(e.target); reportMedia(); }
  }, true));

  // The address of the link the node is in: an HTML <a>, or an SVG <a> (whose href is an animated string).
  function linkHref(node) {
    for (; node && node !== document; node = node.parentNode) {
      if (node.tagName === 'A' && node.href) return node.href;
      if (typeof SVGAElement !== 'undefined' && node instanceof SVGAElement && node.href && node.href.baseVal) {
        try { return new URL(node.href.baseVal, document.baseURI).href; } catch (err) { /* not an address */ }
      }
    }
    return null;
  }
  const linkTarget = (node) => { for (; node && node !== document; node = node.parentNode) if (node.tagName === 'A') return (node.getAttribute('target') || '').toLowerCase(); return ''; };

  // What is under the pointer on right click, for the menu Cosmos draws. Reported once the page's own handlers have run:
  // a site that draws its own right-click menu says so with preventDefault, and Cosmos then shows none.
  const editableOf = (n) => !!(n && (n.isContentEditable || (n.closest && n.closest('input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]), textarea, [contenteditable=""], [contenteditable="true"]'))));
  const mediaOf = (n) => (n && n.closest) ? n.closest('video, audio') : null;
  let contextMedia = null;
  window.addEventListener('contextmenu', e => {
    if (!e.isTrusted) return;
    const href = linkHref(e.target);
    const img = e.target && e.target.tagName === 'IMG' ? e.target.currentSrc || e.target.src : null;
    const m = mediaOf(e.target);
    contextMedia = m;
    const report = { type: 'context', link: href, image: img, selection: String(window.getSelection() || '').slice(0, 2000),
                     editable: editableOf(e.target), media: !!m, mediaSrc: m ? (m.currentSrc || m.src || '') : '', x: e.clientX, y: e.clientY };
    setTimeout(() => { report.handled = e.defaultPrevented; post(report); }, 0);
  }, true);
  window.__cosmosMedia = (what) => {
    const m = contextMedia;
    if (!m || !m.isConnected) return;
    if (what === 'controls') m.controls = !m.controls;
    if (what === 'loop') m.loop = !m.loop;
  };

  let lastHover = null;
  document.addEventListener('mouseover', e => {
    const h = linkHref(e.target);
    if (h !== lastHover) { lastHover = h; post({ type: 'hover', href: h }); }
  }, true);
  document.addEventListener('mouseleave', () => { if (lastHover) { lastHover = null; post({ type: 'hover', href: null }); } }, true);

  // Clicks on links Cosmos opens itself: ⌘, ⇧, ⌥ and middle clicks, a link to another app, and (in a pinned tab) a link
  // to another site. Only real clicks count, and only once the page's own handlers have had them: a page that handled the
  // click itself (and said so with preventDefault) keeps it.
  const webScheme = /^(https?|about|data|blob|file|javascript|view-source|chrome-extension):/i;
  const sameHost = (a, b) => a.replace(/^www\./, '') === b.replace(/^www\./, '');
  // A Force Click opened the link in Peek: the click that ends the press does not follow it too.
  let holdClickUntil = 0;
  window.__cosmosHoldClick = () => { holdClickUntil = Date.now() + 2000; };
  function onClick(e) {
    if (!e.isTrusted || e.defaultPrevented || (e.button !== 0 && e.button !== 1)) return;
    const href = linkHref(e.target);
    if (!href) return;
    if (Date.now() < holdClickUntil) { holdClickUntil = 0; e.preventDefault(); return; }
    if (!webScheme.test(href)) {
      e.preventDefault();
      post({ type: 'external', href });
      return;
    }
    if (!/^https?:/i.test(href)) return;
    const middle = e.button === 1;
    if (e.metaKey || e.shiftKey || e.altKey || middle) {
      e.preventDefault();
      post({ type: 'link', href, meta: e.metaKey || middle, shift: e.shiftKey, alt: e.altKey && !e.metaKey });
      return;
    }
    const target = linkTarget(e.target);
    if (isTop && config.peekCrossSite && (target === '' || target === '_self' || target === '_top')) {
      let host = '';
      try { host = new URL(href).hostname; } catch (err) { return; }
      if (!sameHost(host, location.hostname)) { e.preventDefault(); post({ type: 'link', href }); }
    }
  }
  window.addEventListener('click', onClick);
  window.addEventListener('auxclick', onClick);

  // Per-tab mute (the sidebar speaker button). Media elements only: WebAudio-only pages are not affected.
  let muted = false;
  const applyMute = () => document.querySelectorAll('video, audio').forEach(el => { if (muted) { el.dataset.cosmosWasMuted = el.muted ? '1' : '0'; el.muted = true; } else if (el.dataset.cosmosWasMuted !== undefined) { el.muted = el.dataset.cosmosWasMuted === '1'; delete el.dataset.cosmosWasMuted; } });
  window.__cosmosMute = (v) => { muted = !!v; applyMute(); };
  document.addEventListener('play', e => { if (muted && e.target instanceof HTMLMediaElement) applyMute(); }, true);

  // Escape closes overlays the browser owns even while a page has focus. After the page's own handlers have run: a site
  // that used Escape for something of its own (a modal, a menu) and said so with preventDefault keeps it. A key the page
  // made up itself does not count.
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && isTop && e.isTrusted) setTimeout(() => { if (!e.defaultPrevented) post({ type: 'escape' }); }, 0);
  }, true);
})();
