# Extensions

Cosmos runs browser extensions with WebKit's own extension engine, the one Safari uses (`WKWebExtensionController`). It reads the Chrome extension format (Manifest V2 and V3), so most extensions written for Chrome or Arc run unchanged. This needs **macOS 15.4 or later**; on older systems the Extensions tab says so and nothing else changes.

## Adding extensions

Open **Cosmos ▸ Extensions…** (or type "extensions" in the Command Bar).

| Way | What it does |
|---|---|
| **Find in Arc and Other Browsers** | Lists the extensions installed in Arc, Chrome, Brave, Edge, Vivaldi, Opera and Chromium on this Mac. Tick the ones you want and choose Add Selected. |
| **Chrome Web Store link or id** | Paste `https://chromewebstore.google.com/detail/…/<id>` or the 32-letter id. Cosmos downloads the package from Google's update service and unpacks it. |
| **Choose a Folder** | Any unpacked extension folder that contains `manifest.json`. Handy for extensions you are writing. |

Before anything is copied, Cosmos shows what the extension asks for in plain words ("Read and change your data on all websites", "See your network requests") and any parts that will not work. Adding is a yes or no. What you agree to is saved, and the extension gets exactly that.

Cosmos copies the extension into its own folder (`Extensions/<id>/` in the data folder), so it keeps working after you delete Arc. Reading from Arc never changes Arc's files.

After an Arc import, the summary tells you how many extensions Arc had and where to add them.

## Using them

- Extensions with a toolbar button show it in a row under the address pill. Click to open the popup. A badge (a count on an ad blocker, for example) is drawn on the button.
- Content scripts, background workers, `declarativeNetRequest` rules, storage, messaging between parts of an extension, `chrome.tabs` and `chrome.windows` are provided by WebKit. Cosmos tells WebKit about its windows and tabs (including split panes and pinned tabs) so these see the real browser.
- An extension's options page opens in a tab.
- Turn an extension off (it unloads at once) or remove it (its files and stored data are deleted) in Settings ▸ Extensions.
- Extensions never load in Incognito windows.

## What does not work

WebKit implements a large part of the Chrome extension API, not all of it. The Add prompt names the permissions an extension declares that WebKit does not provide: `history`, `bookmarks`, `downloads`, `identity`, `notifications`, `sidePanel`, `topSites`, `tabGroups`, `proxy`, `privacy`, `browsingData`, `sessions`, `offscreen`, `management` and the capture APIs. The extension still loads; the parts that use those APIs will not work.

Other limits:

- Keyboard shortcuts defined by extensions (`commands`) and extension items in right-click menus are not wired up yet.
- One set of extensions serves every profile: an extension's own storage is shared across spaces that use different profiles.
- Extensions that need a companion app (native messaging) will not find it.
- Cosmos does not check an extension's signature. Packages from the Web Store come over HTTPS from Google; extensions from Arc or other browsers are copied as they are. Only add extensions you trust.

## How it was checked

- `ExtensionTests` builds a small Manifest V3 extension (a content script and a service worker), adds it through the same code the Settings screen uses, loads a page from a local server in a real tab, and checks that the content script ran and that the background worker answered a message with the sender's tab address.
- All eleven extensions in the author's real Arc profile were added in one run; all loaded without errors, their buttons appeared, one injected its own page overlay into example.com, and clicking their buttons did not crash. Behaviour inside each extension's popup and options page was not examined one by one.
- `ChromiumExtensionTests` covers finding extensions in a profile (versions, localized names, themes and apps skipped), Web Store link and id parsing, and unwrapping `.crx` packages (CRX2 and CRX3).

## For developers

| File | Role |
|---|---|
| `CosmosImport/Browsers/ChromiumExtensions.swift` | finds extensions in Chromium-family profiles |
| `CosmosImport/Browsers/ChromeWebStore.swift` | id and link parsing, download address, `.crx` unwrapping |
| `CosmosKit/Extensions/ExtensionCenter.swift` | the list of installed extensions, install and remove, permission summary (works on any macOS) |
| `CosmosKit/Extensions/ExtensionEngine.swift` | `WKWebExtensionController`, loading, permissions prompts, popups (macOS 15.4+) |
| `CosmosKit/Extensions/ExtensionAdapters.swift` | `ExtensionTab` and `ExtensionWindow`, which present Cosmos's tabs and windows to WebKit |
| `CosmosKit/UI/ExtensionButtons.swift`, `App/ExtensionsSettings.swift` | the toolbar row and the settings tab |

`BrowserStore` calls `extensionCenter?.tabOpened/tabClosed/tabActivated/tabChanged/windowOpened/…` at the points where tabs and windows change. `ProfileEnvironment.makeConfiguration()` attaches the controller to every non-incognito web view.
