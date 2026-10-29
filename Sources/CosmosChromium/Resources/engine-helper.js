// Runs in Cosmos's isolated world next to the page agent: the page's title (Chromium only reports it when the page loads,
// not when the page changes it), element fullscreen, and what Copy and Picture in Picture need. Pages cannot see it.
(function () {
  'use strict';
  if (window.__cosmosEngine) return;
  window.__cosmosEngine = true;
  const post = (m) => { try { __cosmosPost(JSON.stringify(m)); } catch (e) {} };
  const isTop = window.top === window;

  if (isTop) {
    let lastTitle = null;
    const reportTitle = () => { const t = document.title; if (t !== lastTitle) { lastTitle = t; post({ type: '__title', value: t }); } };
    const watchTitle = () => {
      reportTitle();
      new MutationObserver(reportTitle).observe(document.head || document.documentElement, { subtree: true, childList: true, characterData: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchTitle, { once: true }); else watchTitle();
    document.addEventListener('fullscreenchange', () => post({ type: '__fullscreen', value: !!document.fullscreenElement }));
  }

  // The selected text, for Copy (a text field's own selection is not in getSelection()).
  window.__cosmosSelection = () => {
    const a = document.activeElement;
    if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') && typeof a.selectionStart === 'number') {
      return a.value.substring(a.selectionStart, a.selectionEnd);
    }
    return String(window.getSelection() || '');
  };

  // Questions from the page's own world (page-bridge.js: permissions, Picture in Picture) go to Cosmos, and Cosmos's answer
  // goes back. Only this frame's own: another frame (an ad, say) can post the same shape to this window.
  window.addEventListener('message', e => {
    const d = e.data;
    if (e.source !== window || !d || typeof d.__cosmosAsk !== 'string' || typeof d.id !== 'number' || typeof d.kind !== 'string') return;
    post({ type: '__ask', what: d.__cosmosAsk, id: d.id, kind: d.kind });
  });
  window.__cosmosAnswer = (id, value) => window.postMessage({ __cosmosAnswer: id, value }, '*');
  // What the page's own world reports without a question (a notification shown, one taken back). Any script in the frame
  // can post that shape too, so a notification goes on only with the site's permission and under this frame's own site,
  // both read here, where the page cannot change them.
  window.addEventListener('message', e => {
    const d = e.data;
    if (e.source !== window || !d || typeof d.__cosmosTell !== 'string' || !d.note || typeof d.note.id !== 'string') return;
    if (d.__cosmosTell === 'notification') {
      if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
      post({ type: '__tell', what: 'notification', note: { id: d.note.id, title: String(d.note.title || ''), body: String(d.note.body || ''), origin: location.hostname } });
    } else {
      post({ type: '__tell', what: d.__cosmosTell, note: { id: d.note.id } });
    }
  });

  // The video in Picture in Picture: where it is in the frame (Cosmos's window shows that part of the page), until it goes.
  let pipTimer = null;
  window.__cosmosTrackPictureInPicture = () => {
    clearInterval(pipTimer);
    let last = '';
    const check = () => {
      const v = document.querySelector('video[data-cosmos-pip]');
      if (!v || !v.isConnected) { clearInterval(pipTimer); pipTimer = null; post({ type: '__pipGone' }); return; }
      const r = v.getBoundingClientRect();
      const now = [r.left, r.top, r.width, r.height].map(Math.round).join();
      if (now !== last) { last = now; post({ type: '__pipRect', x: r.left, y: r.top, width: r.width, height: r.height }); }
    };
    pipTimer = setInterval(check, 200);
    check();
  };
  window.__cosmosStopPictureInPicture = () => { clearInterval(pipTimer); pipTimer = null; };
})();
