// Runs in an extension's service worker before the extension's own code. Chromium keeps doing everything the chrome.* APIs
// do; this only tells Cosmos about the parts Chromium would show in its own toolbar and menus, which do not exist here,
// and lets Cosmos deliver clicks on the menu items and shortcuts it draws instead.
(function () {
  'use strict';
  if (self.__cosmosShim) return;
  self.__cosmosShim = true;
  const report = (m) => { try { __cosmosExt(JSON.stringify(m)); } catch (e) { /* Cosmos is not listening */ } };
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

  const action = chrome.action || chrome.browserAction;
  if (action) {
    wrap(action, 'setBadgeText', d => report({ kind: 'badge', tabId: tabOf(d), text: (d && d.text) || '' }));
    wrap(action, 'setBadgeBackgroundColor', d => report({ kind: 'badgeColor', tabId: tabOf(d), color: d && d.color }));
    wrap(action, 'setTitle', d => report({ kind: 'title', tabId: tabOf(d), title: (d && d.title) || '' }));
    wrap(action, 'setPopup', d => report({ kind: 'popup', tabId: tabOf(d), popup: (d && d.popup) || '' }));
    wrap(action, 'enable', t => report({ kind: 'enabled', tabId: typeof t === 'number' ? t : null, value: true }));
    wrap(action, 'disable', t => report({ kind: 'enabled', tabId: typeof t === 'number' ? t : null, value: false }));
    wrap(action, 'setIcon', d => {
      if (!d) return;
      const tabId = tabOf(d);
      if (d.path) {
        const path = typeof d.path === 'string' ? d.path : (d.path['32'] || d.path['38'] || d.path['48'] || d.path[Object.keys(d.path).pop()]);
        report({ kind: 'icon', tabId, path });
        return;
      }
      const img = d.imageData && (d.imageData.width ? d.imageData : (d.imageData['32'] || d.imageData['38'] || d.imageData[Object.keys(d.imageData).pop()]));
      if (!img || typeof OffscreenCanvas === 'undefined') return;
      const canvas = new OffscreenCanvas(img.width, img.height);
      canvas.getContext('2d').putImageData(img, 0, 0);
      canvas.convertToBlob({ type: 'image/png' }).then(blob => {
        const reader = new FileReader();
        reader.onload = () => report({ kind: 'icon', tabId, dataURL: reader.result });
        reader.readAsDataURL(blob);
      });
    });
  }

  const menus = chrome.contextMenus || chrome.menus;
  if (menus) {
    const listeners = [];
    self.__cosmosMenuListeners = listeners;
    const item = (p) => ({
      id: String(p.id), title: p.title || '', contexts: p.contexts || ['page'], parentId: p.parentId != null ? String(p.parentId) : null,
      type: p.type || 'normal', enabled: p.enabled !== false, visible: p.visible !== false
    });
    wrap(menus, 'create', p => { if (p && p.id != null) report({ kind: 'menuCreate', item: item(p) }); });
    wrap(menus, 'update', (id, p) => report({ kind: 'menuUpdate', id: String(id), changes: p || {} }));
    wrap(menus, 'remove', id => report({ kind: 'menuRemove', id: String(id) }));
    wrap(menus, 'removeAll', () => report({ kind: 'menuRemoveAll' }));
    if (menus.onClicked) wrap(menus.onClicked, 'addListener', f => listeners.push(f));
  }

  const commandListeners = [];
  self.__cosmosCommandListeners = commandListeners;
  if (chrome.commands && chrome.commands.onCommand) wrap(chrome.commands.onCommand, 'addListener', f => commandListeners.push(f));

  // chrome.notifications: Chromium makes them (so getAll and the rest stay right) but shows nothing; Cosmos posts them to
  // macOS, and the user's clicks come back as their events.
  const notifications = chrome.notifications;
  const noteListeners = { clicked: [], button: [], closed: [] };
  self.__cosmosNotificationListeners = noteListeners;
  if (notifications) {
    if (notifications.onClicked) wrap(notifications.onClicked, 'addListener', f => noteListeners.clicked.push(f));
    if (notifications.onButtonClicked) wrap(notifications.onButtonClicked, 'addListener', f => noteListeners.button.push(f));
    if (notifications.onClosed) wrap(notifications.onClosed, 'addListener', f => noteListeners.closed.push(f));
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

  // chrome.sidePanel: Chromium keeps the options, but has no panel to show and refuses open(); Cosmos draws the panel.
  const sidePanel = chrome.sidePanel;
  if (sidePanel) {
    wrap(sidePanel, 'setOptions', o => report({ kind: 'sidePanelOptions', tabId: tabOf(o), path: o && typeof o.path === 'string' ? o.path : null,
                                                 enabled: o && typeof o.enabled === 'boolean' ? o.enabled : null }));
    wrap(sidePanel, 'setPanelBehavior', b => report({ kind: 'sidePanelBehavior', openOnAction: !!(b && b.openPanelOnActionClick) }));
    sidePanel.open = function (options, callback) {
      report({ kind: 'sidePanelOpen', tabId: tabOf(options) });
      const done = Promise.resolve();
      if (typeof callback === 'function') { done.then(() => callback()); return undefined; }
      return done;
    };
  }

  // chrome.identity: a sign-in that needs the user opens a window Cosmos shows (Chromium's own would be invisible). One
  // that must not ask (interactive: false) stays with Chromium.
  const identity = chrome.identity;
  const flows = new Map();
  let nextFlow = 1;
  if (identity && typeof identity.launchWebAuthFlow === 'function') {
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
      identity.removeCachedAuthToken = function (details, callback) {
        const done = Promise.resolve();
        if (typeof callback === 'function') { done.then(() => callback()); return undefined; }
        return done;
      };
    }
  }

  const tab = async (tabId) => (tabId === null || tabId === undefined) ? undefined : chrome.tabs.get(tabId).catch(() => undefined);
  // A worker Chromium has replaced lingers while Cosmos is attached to it, and every API call it makes fails ("No SW").
  // The fire functions say 'dead' there, so Cosmos lets it go and asks the extension's other worker; false means a live
  // worker that has nothing to do with it.
  const alive = () => chrome.runtime.getPlatformInfo().then(() => true, () => false);
  self.__cosmosFireMenu = async (info, tabId) => {
    if (!(await alive())) return 'dead';
    const t = await tab(tabId);
    (self.__cosmosMenuListeners || []).forEach(f => { try { f(info, t); } catch (e) { console.error(e); } });
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
    const l = self.__cosmosNotificationListeners;
    const run = (fs, ...a) => fs.forEach(f => { try { f(...a); } catch (e) { console.error(e); } });
    if (action === 'clicked') run(l.clicked, id);
    else if (action === 'button') run(l.button, id, index);
    else run(l.closed, id, true);
    return true;
  };
  self.__cosmosFireCommand = async (name, tabId) => {
    if (!(await alive())) return 'dead';
    const t = await tab(tabId);
    (self.__cosmosCommandListeners || []).forEach(f => { try { f(name, t); } catch (e) { console.error(e); } });
    return true;
  };
})();
