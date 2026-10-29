// Cosmos draws Chromium's pages itself. This worker does the few things only an extension can: set a tab's zoom (Chromium
// sends frames at the size of the page's viewport in device-independent pixels, so Cosmos zooms the page by the screen's
// scale to get sharp frames), clear site data and forget what Chromium's own history holds.

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

// Chromium keeps a history of its own, which Cosmos does not show; Cosmos's History forgetting a page forgets it here too.
self.cosmosClearHistory = async (since) => {
  await chrome.browsingData.remove({ since }, { history: true });
  return true;
};

// Every address of the page, with or without a fragment (Cosmos's History keeps one row for them all).
self.cosmosDeleteHistory = async (url) => {
  const page = url.split('#')[0];
  const all = await chrome.history.search({ text: '', startTime: 0, maxResults: 0 });
  for (const item of all) if (item.url.split('#')[0] === page) await chrome.history.deleteUrl({ url: item.url });
  return true;
};

// The chrome.tabs id of a page target, for extension events that name a tab.
self.cosmosTabID = async (targetId) => tabFor(targetId);
