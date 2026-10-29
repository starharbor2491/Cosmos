// The few things only an extension can do for Cosmos, in the default profile: clear site data and forget what Chromium's
// own history holds.

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
