// Runs before the extension's own code in its service worker (the worker Chromium starts imports this first) and in its
// pages (the first script of each), see ExtensionStage. Cosmos's pages are not Chrome tabs, so Chromium knows of no tabs
// here: what the extension asks of tabs and windows (chrome.tabs, chrome.windows, chrome.scripting) Cosmos answers, and
// what Chrome would show in its toolbar and menus (the button, its badge and popup, menu items, shortcuts, notifications,
// side panels) Cosmos is told of and draws. Everything else is Chromium's own. Cosmos speaks to the worker only; a page
// goes through it.
(function () {
  'use strict';
  if (self.__cosmosShim) return;
  self.__cosmosShim = true;
  // Whatever goes wrong here, the extension's own code still runs after (an exception would stop the worker's imports).
  try { cosmos(); } catch (e) { self.__cosmosShimError = String((e && e.stack) || e); console.error(e); }
  function cosmos() {
  const inWorker = typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope;

  // Cosmos hears through a binding it adds once it is attached to the worker, a moment after the worker started: what
  // is said before then waits for it.
  const waiting = [];
  const post = (m) => {
    const json = JSON.stringify(m);
    if (typeof self.__cosmosExt === 'function') { try { self.__cosmosExt(json); } catch (e) { /* Cosmos is not listening */ } }
    else waiting.push(json);
  };
  self.__cosmosReady = () => {
    while (waiting.length) { try { self.__cosmosExt(waiting.shift()); } catch (e) { /* Cosmos is not listening */ } }
    return true;
  };
  const report = inWorker ? post : (m) => { chrome.runtime.sendMessage({ __cosmosReport: m }).catch(() => {}); };

  // What Cosmos answers: each call is answered once, by __cosmosAnswer.
  const calls = new Map();
  let nextCall = 1;
  // `from`: the address of the extension's page or content script that asked, when it was not this worker.
  const callFrom = (from, api, args) => new Promise((resolve, reject) => {
    const id = nextCall++;
    calls.set(id, { resolve, reject });
    post({ kind: 'call', id, api, args, from });
  });
  const relay = (api, args) => chrome.runtime.sendMessage({ __cosmosCall: { api, args } }).then(r => {
    if (r && r.ok) return r.value;
    throw new Error((r && r.error) || 'Cosmos did not answer');
  });
  const call = (api, ...args) => inWorker ? callFrom(null, api, args) : relay(api, args);
  self.__cosmosAnswer = (id, ok, value) => {
    const c = calls.get(id);
    if (!c) return false;
    calls.delete(id);
    if (ok) c.resolve(value); else c.reject(new Error(value || 'Failed'));
    return true;
  };

  // An API function as Chrome's are: a promise, or the callback given last.
  const api = (fn) => function (...args) {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    let result;
    try { result = Promise.resolve(fn(...args)); } catch (e) { result = Promise.reject(e); }
    if (!callback) return result;
    result.then(v => callback(v), () => callback());
    return undefined;
  };

  // An event Cosmos fires, in place of a native one that never fires here.
  const event = () => {
    const listeners = [];
    return {
      listeners,
      addListener(f) { if (typeof f === 'function' && !listeners.includes(f)) listeners.push(f); },
      removeListener(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
      hasListener(f) { return listeners.includes(f); },
      hasListeners() { return listeners.length > 0; },
      dispatch(...args) { for (const f of listeners.slice()) { try { f(...args); } catch (e) { console.error(e); } } },
    };
  };
  // Takes over a native event object: its listeners are Cosmos's to call.
  const own = (native) => {
    const ours = event();
    if (native) for (const k of ['addListener', 'removeListener', 'hasListener', 'hasListeners']) native[k] = ours[k].bind(ours);
    return ours;
  };
  const wrap = (obj, name, after) => {
    if (!obj || typeof obj[name] !== 'function') return;
    const original = obj[name].bind(obj);
    obj[name] = function (...args) {
      const result = original(...args);
      try { after(...args); } catch (e) { /* reporting never breaks the extension */ }
      return result;
    };
  };
  const tabOf = (d) => (d && typeof d.tabId === 'number') ? d.tabId : null;
  const tab = (tabId) => (tabId === null || tabId === undefined) ? Promise.resolve(undefined) : call('tabs.get', tabId).catch(() => undefined);

  // chrome.action: what applies to every tab is Chromium's too; what applies to one of Cosmos's tabs only Cosmos knows
  // (Chromium refuses a tab id it has never heard of), so it is kept here.
  const action = chrome.action || chrome.browserAction;
  const actionClicked = own(action && action.onClicked);
  if (action) {
    const perTab = { badge: {}, badgeColor: {}, title: {}, popup: {} };
    const setter = (name, kind, value) => {
      const original = typeof action[name] === 'function' ? action[name].bind(action) : null;
      action[name] = api((d) => {
        const tabId = tabOf(d);
        report(Object.assign({ kind, tabId }, value(d)));
        if (tabId === null) return original ? original(d) : undefined;
        perTab[kind][tabId] = d;
        return undefined;
      });
    };
    setter('setBadgeText', 'badge', d => ({ text: (d && d.text) || '' }));
    setter('setBadgeBackgroundColor', 'badgeColor', d => ({ color: d && d.color }));
    setter('setTitle', 'title', d => ({ title: (d && d.title) || '' }));
    setter('setPopup', 'popup', d => ({ popup: (d && d.popup) || '' }));
    const getter = (name, kind, field) => {
      const original = typeof action[name] === 'function' ? action[name].bind(action) : null;
      action[name] = api((d) => {
        const tabId = tabOf(d);
        if (tabId !== null && perTab[kind][tabId]) return perTab[kind][tabId][field];
        return original ? original(tabId === null ? (d || {}) : {}) : undefined;
      });
    };
    getter('getBadgeText', 'badge', 'text');
    getter('getTitle', 'title', 'title');
    getter('getPopup', 'popup', 'popup');
    for (const [name, value] of [['enable', true], ['disable', false]]) {
      const original = typeof action[name] === 'function' ? action[name].bind(action) : null;
      action[name] = api((t) => {
        const tabId = typeof t === 'number' ? t : null;
        report({ kind: 'enabled', tabId, value });
        return tabId === null && original ? original() : undefined;
      });
    }
    const setIcon = typeof action.setIcon === 'function' ? action.setIcon.bind(action) : null;
    action.setIcon = api((d) => {
      if (!d) return undefined;
      const tabId = tabOf(d);
      if (d.path) {
        const path = typeof d.path === 'string' ? d.path : (d.path['32'] || d.path['38'] || d.path['48'] || d.path[Object.keys(d.path).pop()]);
        report({ kind: 'icon', tabId, path });
      } else {
        const img = d.imageData && (d.imageData.width ? d.imageData : (d.imageData['32'] || d.imageData['38'] || d.imageData[Object.keys(d.imageData).pop()]));
        if (img && typeof OffscreenCanvas !== 'undefined') {
          const canvas = new OffscreenCanvas(img.width, img.height);
          canvas.getContext('2d').putImageData(img, 0, 0);
          canvas.convertToBlob({ type: 'image/png' }).then(blob => {
            const reader = new FileReader();
            reader.onload = () => report({ kind: 'icon', tabId, dataURL: reader.result });
            reader.readAsDataURL(blob);
          });
        }
      }
      return tabId === null && setIcon ? setIcon(d) : undefined;
    });
    action.openPopup = api(() => call('action.openPopup'));
  }

  const menus = chrome.contextMenus || chrome.menus;
  const menuClicked = own(menus && menus.onClicked);
  if (menus) {
    const item = (p) => ({
      id: String(p.id), title: p.title || '', contexts: p.contexts || ['page'], parentId: p.parentId != null ? String(p.parentId) : null,
      type: p.type || 'normal', enabled: p.enabled !== false, visible: p.visible !== false
    });
    wrap(menus, 'create', p => { if (p && p.id != null) report({ kind: 'menuCreate', item: item(p) }); });
    wrap(menus, 'update', (id, p) => report({ kind: 'menuUpdate', id: String(id), changes: p || {} }));
    wrap(menus, 'remove', id => report({ kind: 'menuRemove', id: String(id) }));
    wrap(menus, 'removeAll', () => report({ kind: 'menuRemoveAll' }));
  }

  const commandFired = own(chrome.commands && chrome.commands.onCommand);

  // chrome.notifications: Chromium makes them (so getAll and the rest stay right) but shows nothing; Cosmos posts them to
  // macOS, and the user's clicks come back as their events.
  const notifications = chrome.notifications;
  const noteClicked = own(notifications && notifications.onClicked);
  const noteButton = own(notifications && notifications.onButtonClicked);
  const noteClosed = own(notifications && notifications.onClosed);
  if (notifications) {
    const shown = {};
    let generated = 1;
    for (const name of ['create', 'update']) {
      const original = notifications[name];
      if (typeof original !== 'function') continue;
      notifications[name] = function (...args) {
        // Cosmos names a notification that has no name, so Chromium and Cosmos call it the same.
        if (name === 'create' && typeof args[0] !== 'string') args.unshift('cosmos-' + generated++);
        const id = args[0], options = args[1];
        if (options && typeof options === 'object') {
          try {
            const o = shown[id] = Object.assign({}, name === 'update' ? shown[id] : {}, options);
            report({ kind: 'notification', id, title: o.title || '', message: o.message || '', iconUrl: o.iconUrl || '',
                     buttons: (o.buttons || []).map(b => (b && b.title) || '') });
          } catch (e) { /* reporting never breaks the extension */ }
        }
        return original.apply(notifications, args);
      };
    }
    wrap(notifications, 'clear', id => { delete shown[id]; report({ kind: 'notificationClosed', id: String(id) }); });
  }

  // chrome.sidePanel: Chromium keeps the options for every tab, but has no panel to show and refuses open(); Cosmos
  // keeps a tab's options and draws the panel.
  const sidePanel = chrome.sidePanel;
  if (sidePanel) {
    const setOptions = typeof sidePanel.setOptions === 'function' ? sidePanel.setOptions.bind(sidePanel) : null;
    sidePanel.setOptions = api((o) => {
      report({ kind: 'sidePanelOptions', tabId: tabOf(o), path: o && typeof o.path === 'string' ? o.path : null,
               enabled: o && typeof o.enabled === 'boolean' ? o.enabled : null });
      return tabOf(o) === null && setOptions ? setOptions(o) : undefined;
    });
    wrap(sidePanel, 'setPanelBehavior', b => report({ kind: 'sidePanelBehavior', openOnAction: !!(b && b.openPanelOnActionClick) }));
    sidePanel.open = api((options) => { report({ kind: 'sidePanelOpen', tabId: tabOf(options) }); });
  }

  // chrome.identity: a sign-in that needs the user opens a window Cosmos shows (Chromium's own would be invisible). One
  // that must not ask (interactive: false) stays with Chromium.
  const identity = chrome.identity;
  const flows = new Map();
  let nextFlow = 1;
  if (inWorker && identity && typeof identity.launchWebAuthFlow === 'function') {
    const silent = identity.launchWebAuthFlow.bind(identity);
    const launch = function (details, callback) {
      if (!details || !details.interactive) return silent(details, callback);
      const answer = new Promise((resolve, reject) => {
        const flow = nextFlow++;
        flows.set(flow, (url, error) => url ? resolve(url) : reject(new Error(error || 'The user did not approve access.')));
        report({ kind: 'authFlow', flow, url: String(details.url || ''), redirect: identity.getRedirectURL() });
      });
      if (typeof callback === 'function') { answer.then(callback, () => callback(undefined)); return undefined; }
      return answer;
    };
    identity.launchWebAuthFlow = launch;
    // Chrome signs in with the Google account the browser is signed in to, which Cosmos's Chromium has none of: the
    // token is asked for with the same web sign-in instead (it works where the extension's Google client allows it).
    if (typeof identity.getAuthToken === 'function') {
      identity.getAuthToken = function (details, callback) {
        if (typeof details === 'function') { callback = details; details = {}; }
        details = details || {};
        const answer = (async () => {
          const o = chrome.runtime.getManifest().oauth2 || {};
          if (!o.client_id) throw new Error('OAuth2 client id not found in the manifest.');
          const scopes = details.scopes || o.scopes || [];
          const url = 'https://accounts.google.com/o/oauth2/v2/auth?' + new URLSearchParams({
            client_id: o.client_id, response_type: 'token', redirect_uri: identity.getRedirectURL(), scope: scopes.join(' ') });
          const back = await launch({ url, interactive: details.interactive !== false });
          const token = new URLSearchParams(new URL(back).hash.slice(1)).get('access_token');
          if (!token) throw new Error('OAuth2 request failed: no token came back.');
          return { token, grantedScopes: scopes };
        })();
        if (typeof callback === 'function') { answer.then(r => callback(r.token, r.grantedScopes), () => callback(undefined)); return undefined; }
        return answer;
      };
      identity.removeCachedAuthToken = api(() => undefined);
    }
  }

  // chrome.tabs and chrome.windows: Cosmos's tabs and windows, by the ids Cosmos gives them.
  const tabEvents = {};
  const tabs = chrome.tabs;
  if (tabs) {
    tabs.query = api(info => call('tabs.query', info || {}));
    tabs.get = api(id => call('tabs.get', id));
    // A worker is in no tab; a page may be one.
    tabs.getCurrent = api(() => inWorker ? undefined : call('tabs.getCurrent'));
    tabs.create = api(props => call('tabs.create', props || {}));
    tabs.update = api((a, b) => typeof a === 'number' ? call('tabs.update', a, b || {}) : call('tabs.update', null, a || {}));
    tabs.remove = api(ids => call('tabs.remove', Array.isArray(ids) ? ids : [ids]));
    tabs.reload = api((a, b) => call('tabs.reload', typeof a === 'number' ? a : null, (typeof a === 'object' && a) || b || {}));
    tabs.goBack = api(id => call('tabs.goBack', typeof id === 'number' ? id : null));
    tabs.goForward = api(id => call('tabs.goForward', typeof id === 'number' ? id : null));
    tabs.duplicate = api(id => call('tabs.duplicate', id));
    tabs.discard = api(id => call('tabs.get', id));
    tabs.highlight = api(info => call('tabs.highlight', info || {}));
    tabs.move = api((ids, props) => Array.isArray(ids) ? Promise.all(ids.map(i => call('tabs.get', i))) : call('tabs.get', ids));
    tabs.captureVisibleTab = api((a, b) => call('tabs.captureVisibleTab', typeof a === 'number' ? a : null, (typeof a === 'object' && a) || b || {}));
    tabs.sendMessage = api((tabId, message, options) => call('tabs.sendMessage', tabId, message === undefined ? null : message, options || {}));
    tabs.getZoom = api(id => call('tabs.getZoom', typeof id === 'number' ? id : null));
    tabs.setZoom = api((a, b) => typeof a === 'number' && typeof b === 'number' ? call('tabs.setZoom', a, b) : call('tabs.setZoom', null, a));
    tabs.detectLanguage = api(id => call('tabs.detectLanguage', typeof id === 'number' ? id : null));
    tabs.connect = function () { throw new Error('chrome.tabs.connect is not available in Cosmos: use chrome.tabs.sendMessage.'); };
    for (const name of ['onCreated', 'onUpdated', 'onRemoved', 'onActivated', 'onHighlighted', 'onMoved', 'onReplaced', 'onAttached', 'onDetached', 'onZoomChange']) {
      tabEvents['tabs.' + name] = own(tabs[name]);
    }
  }
  const windows = chrome.windows;
  if (windows) {
    windows.getAll = api(info => call('windows.getAll', info || {}));
    windows.get = api((id, info) => call('windows.get', id, info || {}));
    windows.getCurrent = api(info => call('windows.getCurrent', info || {}));
    windows.getLastFocused = api(info => call('windows.getLastFocused', info || {}));
    windows.create = api(data => call('windows.create', data || {}));
    windows.update = api((id, info) => call('windows.update', id, info || {}));
    windows.remove = api(id => call('windows.remove', id));
    for (const name of ['onCreated', 'onRemoved', 'onFocusChanged', 'onBoundsChanged']) tabEvents['windows.' + name] = own(windows[name]);
  }

  // chrome.scripting: Cosmos runs the script in the tab's frames, where the extension may.
  const scripting = chrome.scripting;
  if (scripting) {
    scripting.executeScript = api(inj => call('scripting.executeScript', {
      target: inj.target, files: inj.files || null, world: inj.world || 'ISOLATED',
      func: typeof inj.func === 'function' ? inj.func.toString() : null, args: inj.args || []
    }));
    scripting.insertCSS = api(inj => call('scripting.insertCSS', { target: inj.target, files: inj.files || null, css: inj.css || null }));
    scripting.removeCSS = api(inj => call('scripting.removeCSS', { target: inj.target, files: inj.files || null, css: inj.css || null }));
    // Scripts registered as the manifest's are: Cosmos's content script first.
    for (const name of ['registerContentScripts', 'updateContentScripts']) {
      const original = typeof scripting[name] === 'function' ? scripting[name].bind(scripting) : null;
      if (!original) continue;
      scripting[name] = function (scripts, ...rest) {
        const withShim = (scripts || []).map(s => (s && Array.isArray(s.js) && s.js.length && s.world !== 'MAIN')
          ? Object.assign({}, s, { js: ['cosmos-extension/content.js'].concat(s.js) }) : s);
        return original(withShim, ...rest);
      };
    }
  }

  // chrome.runtime messages and ports. A content script's come wrapped with the tab it is in (Chromium does not know it),
  // and a page's or content script's call for Cosmos comes here to be passed on.
  const messageListeners = [];
  const connectListeners = [];
  const onMessage = chrome.runtime.onMessage;
  const onConnect = chrome.runtime.onConnect;
  const nativeOnMessage = onMessage.addListener.bind(onMessage);
  const nativeOnConnect = onConnect.addListener.bind(onConnect);
  for (const [target, list] of [[onMessage, messageListeners], [onConnect, connectListeners]]) {
    target.addListener = f => { if (typeof f === 'function' && !list.includes(f)) list.push(f); };
    target.removeListener = f => { const i = list.indexOf(f); if (i >= 0) list.splice(i, 1); };
    target.hasListener = f => list.includes(f);
    target.hasListeners = () => list.length > 0;
  }
  const dispatchMessage = (message, sender, sendResponse, mustAnswer) => {
    let answered = false, keep = false;
    const respond = (v) => { if (answered) return; answered = true; try { sendResponse(v); } catch (e) { /* the sender left */ } };
    for (const f of messageListeners.slice()) {
      let r;
      try { r = f(message, sender, respond); } catch (e) { console.error(e); continue; }
      if (r === true) keep = true;
      else if (r && typeof r.then === 'function') { keep = true; r.then(respond, () => respond(undefined)); }
    }
    if (mustAnswer && !keep && !answered) respond(undefined);
    return keep;
  };
  nativeOnMessage((message, sender, sendResponse) => {
    if (message && message.__cosmosCall) {
      if (!inWorker) return false;
      const c = message.__cosmosCall;
      callFrom((sender && sender.url) || null, c.api, c.args || [])
        .then(value => sendResponse({ ok: true, value }), e => sendResponse({ ok: false, error: String((e && e.message) || e) }));
      return true;
    }
    if (message && message.__cosmosReport) {
      if (inWorker) post(message.__cosmosReport);
      return false;
    }
    if (message && message.__cosmosEvent) {
      if (!inWorker) { const e = tabEvents[message.__cosmosEvent.name]; if (e) e.dispatch(...(message.__cosmosEvent.args || [])); }
      return false;
    }
    if (message && message.__cosmosMessage) {
      const env = message.__cosmosMessage;
      const s = Object.assign({}, sender);
      if (env.tab) s.tab = env.tab;
      if (typeof env.frameId === 'number') s.frameId = env.frameId;
      return dispatchMessage(env.message, s, sendResponse, false);
    }
    return dispatchMessage(message, sender, sendResponse, false);
  });
  nativeOnConnect((port) => {
    if (typeof port.name === 'string' && port.name.startsWith('__cosmos:')) {
      try {
        const env = JSON.parse(port.name.slice(9));
        Object.defineProperty(port, 'name', { value: env.name || '', configurable: true });
        if (port.sender && env.tab) port.sender.tab = env.tab;
        if (port.sender && typeof env.frameId === 'number') port.sender.frameId = env.frameId;
      } catch (e) { /* a port name that only looks like Cosmos's */ }
    }
    for (const f of connectListeners.slice()) { try { f(port); } catch (e) { console.error(e); } }
  });

  // Cosmos's tabs changed: the worker's listeners hear of it, and so do the extension's pages.
  self.__cosmosTabsEvent = (name, args) => {
    const e = tabEvents[name];
    if (e) e.dispatch(...args);
    chrome.runtime.sendMessage({ __cosmosEvent: { name, args } }).catch(() => {});
    return true;
  };

  // A worker Chromium has replaced lingers while Cosmos is attached to it, and every API call it makes fails ("No SW").
  // The fire functions say 'dead' there, so Cosmos lets it go and asks the extension's other worker; false means a live
  // worker that has nothing to do with it.
  const alive = () => chrome.runtime.getPlatformInfo().then(() => true, () => false);
  self.__cosmosFireAction = async (tabId) => {
    if (!(await alive())) return 'dead';
    actionClicked.dispatch(await tab(tabId));
    return true;
  };
  self.__cosmosFireMenu = async (info, tabId) => {
    if (!(await alive())) return 'dead';
    menuClicked.dispatch(info, await tab(tabId));
    return true;
  };
  // The sign-in window reached the extension's address (or closed): the flow's answer. False where this worker did not
  // start it, so Cosmos asks the extension's other worker.
  self.__cosmosFinishAuthFlow = async (flow, url, error) => {
    if (!(await alive())) return 'dead';
    const done = flows.get(flow);
    if (!done) return false;
    flows.delete(flow);
    done(url, error);
    return true;
  };
  self.__cosmosFireNotification = async (id, action, index) => {
    if (!(await alive())) return 'dead';
    if (action === 'clicked') noteClicked.dispatch(id);
    else if (action === 'button') noteButton.dispatch(id, index);
    else noteClosed.dispatch(id, true);
    return true;
  };
  self.__cosmosFireCommand = async (name, tabId) => {
    if (!(await alive())) return 'dead';
    commandFired.dispatch(name, await tab(tabId));
    return true;
  };
  // All of the above is there now (Cosmos can be attached before the worker has run a line).
  if (inWorker) post({ kind: 'ready' });
  }
})();
