// Cosmos draws Chromium's pages itself. This worker does the few things only an extension can: set a tab's zoom (Chromium
// sends frames at the size of the page's viewport in device-independent pixels, so Cosmos zooms the page by the screen's
// scale to get sharp frames) and clear site data.

const tabFor = async (targetId) => {
  const target = (await chrome.debugger.getTargets()).find(t => t.id === targetId);
  return target && target.tabId !== undefined ? target.tabId : null;
};

self.cosmosZoom = async (targetId, factor) => {
  const tab = await tabFor(targetId);
  if (tab === null) return false;
  await chrome.tabs.setZoomSettings(tab, { mode: 'automatic', scope: 'per-tab' });
  await chrome.tabs.setZoom(tab, factor);
  return true;
};

self.cosmosClearData = async () => {
  await chrome.browsingData.remove({}, {
    appcache: true, cache: true, cacheStorage: true, cookies: true, fileSystems: true, indexedDB: true,
    localStorage: true, serviceWorkers: true, webSQL: true
  });
  return true;
};

// The chrome.tabs id of a page target, for extension events that name a tab.
self.cosmosTabID = async (targetId) => tabFor(targetId);
