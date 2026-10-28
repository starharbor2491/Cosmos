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

  const tab = async (tabId) => (tabId === null || tabId === undefined) ? undefined : chrome.tabs.get(tabId).catch(() => undefined);
  // A worker Chromium has replaced lingers while Cosmos is attached to it, and every API call it makes fails ("No SW").
  // The fire functions say false there, so Cosmos lets it go and asks the extension's other worker.
  const alive = () => chrome.runtime.getPlatformInfo().then(() => true, () => false);
  self.__cosmosFireMenu = async (info, tabId) => {
    if (!(await alive())) return false;
    const t = await tab(tabId);
    (self.__cosmosMenuListeners || []).forEach(f => { try { f(info, t); } catch (e) { console.error(e); } });
    return true;
  };
  self.__cosmosFireCommand = async (name, tabId) => {
    if (!(await alive())) return false;
    const t = await tab(tabId);
    (self.__cosmosCommandListeners || []).forEach(f => { try { f(name, t); } catch (e) { console.error(e); } });
    return true;
  };
})();
