// Runs in an extension's world in a page, before the extension's content scripts (ExtensionStage puts it first).
// Chromium does not know which of Cosmos's tabs the page is in, so Cosmos tells this script (it reaches the extension's
// world from outside, where the page cannot), and the extension's messages and ports go out with that tab. What the
// extension's worker sends to the tab (chrome.tabs.sendMessage) comes in through Cosmos.
(function () {
  'use strict';
  if (self.__cosmosContent) return;
  self.__cosmosContent = true;
  const runtime = chrome.runtime;

  // { tab, frameId }, from Cosmos. At most a second is waited for it: a frame Cosmos does not know goes without.
  let me = self.__cosmosTab || null;
  const waiting = [];
  self.__cosmosSetTab = (info) => { me = info; while (waiting.length) waiting.shift()(); return true; };
  const known = () => me ? Promise.resolve() : new Promise(r => { waiting.push(r); setTimeout(r, 1000); });
  const isExtensionID = (s) => typeof s === 'string' && /^[a-p]{32}$/.test(s);

  const event = () => {
    const listeners = [];
    return {
      addListener(f) { if (typeof f === 'function' && !listeners.includes(f)) listeners.push(f); },
      removeListener(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
      hasListener(f) { return listeners.includes(f); },
      hasListeners() { return listeners.length > 0; },
      dispatch(...args) { for (const f of listeners.slice()) { try { f(...args); } catch (e) { console.error(e); } } },
    };
  };

  // chrome.runtime.sendMessage([extensionId,] message [, options] [, callback]): to another extension it goes as it is;
  // in order, once the tab is known.
  const nativeSend = runtime.sendMessage.bind(runtime);
  let queue = Promise.resolve();
  runtime.sendMessage = function (...args) {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const target = args.length >= 2 && isExtensionID(args[0]) ? args.shift() : null;
    const [message, options] = args;
    if (target && target !== runtime.id) return nativeSend(target, ...args, ...(callback ? [callback] : []));
    const sent = queue.then(known).then(() => {
      const wrapped = { __cosmosMessage: { message, tab: me && me.tab, frameId: me ? me.frameId : undefined } };
      return options === undefined ? nativeSend(wrapped) : nativeSend(wrapped, options);
    });
    queue = sent.catch(() => {});
    if (!callback) return sent;
    sent.then(r => callback(r), () => callback());
    return undefined;
  };

  // chrome.runtime.connect: the port's name carries the tab. Before Cosmos has said which tab this is, the port is one
  // that connects as soon as it knows, keeping what was posted.
  const nativeConnect = runtime.connect.bind(runtime);
  runtime.connect = function (...args) {
    const target = isExtensionID(args[0]) ? args.shift() : null;
    const info = args[0] || {};
    if (target && target !== runtime.id) return nativeConnect(target, info);
    const open = () => nativeConnect({ name: '__cosmos:' + JSON.stringify({ name: info.name || '', tab: me && me.tab, frameId: me ? me.frameId : undefined }) });
    if (me) return open();
    let real = null, pending = [], gone = false;
    const onMessage = event(), onDisconnect = event();
    const port = {
      name: info.name || '',
      onMessage, onDisconnect,
      postMessage(m) {
        if (gone) throw new Error('Attempting to use a disconnected port object');
        if (real) real.postMessage(m); else pending.push(m);
      },
      disconnect() { gone = true; if (real) real.disconnect(); },
    };
    known().then(() => {
      if (gone) return;
      real = open();
      real.onMessage.addListener(m => onMessage.dispatch(m, port));
      real.onDisconnect.addListener(() => { gone = true; onDisconnect.dispatch(port); });
      for (const m of pending) real.postMessage(m);
      pending = [];
    });
    return port;
  };

  // What the extension sends to this tab: Cosmos hands it here, and takes back the first answer.
  const listeners = [];
  const onMessage = runtime.onMessage;
  onMessage.addListener = f => { if (typeof f === 'function' && !listeners.includes(f)) listeners.push(f); };
  onMessage.removeListener = f => { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); };
  onMessage.hasListener = f => listeners.includes(f);
  onMessage.hasListeners = () => listeners.length > 0;
  self.__cosmosDeliver = (message, sender) => new Promise((resolve) => {
    let answered = false, keep = false;
    const respond = (v) => { if (!answered) { answered = true; resolve(v); } };
    for (const f of listeners.slice()) {
      let r;
      try { r = f(message, sender, respond); } catch (e) { console.error(e); continue; }
      if (r === true) keep = true;
      else if (r && typeof r.then === 'function') { keep = true; r.then(respond, () => respond(undefined)); }
    }
    if (!keep && !answered) respond(undefined);
  }).then(value => JSON.stringify({ heard: listeners.length > 0, value: value === undefined ? null : value }));
})();
