# Extensions

Cosmos runs on regular Chromium, so extensions run in Chromium itself, with Chromium's own, complete `chrome.*` APIs:
content scripts, service workers, `declarativeNetRequest`, `webRequest`, `storage`, `scripting`, `tabs`, `windows`,
`cookies`, `alarms`, `offscreen`, messaging and the rest behave as they do in Chrome, because they are Chrome's code.
Manifest V3 extensions work; Manifest V2 ones only as far as the Chromium in use still loads them (Chrome has been
removing V2).

What Cosmos adds is the part Chrome would draw: Chromium runs headless here and has no toolbar or menus of its own, so
Cosmos draws the extension's button, badge and popup, its right-click menu items and its keyboard shortcuts, and sends
your clicks and key presses back to the extension. That mirror is the "equivalent API" for the parts of `chrome.*`
that end in browser UI:

| Extension API | In Cosmos |
|---|---|
| `chrome.action` / `chrome.browserAction`: title, icon, badge text and colour, enable / disable, per-tab values | the button in a row under the address pill, with its badge |
| the action's popup (`default_popup`, `setPopup`) | the popup page in a popover under the button, sized to what the page lays out (within Chrome's limits) |
| `action.onClicked` (no popup) | clicking the button; Chromium delivers the event itself |
| `chrome.contextMenus` / `chrome.menus`: items, children, `update`, `remove`, contexts `page` `link` `image` `selection` `editable` `video` `audio` `all`, `%s` in titles | the items appear in the page's right-click menu (in the radial menu under More); a click reaches `onClicked` with the click's `info` and the tab |
| `chrome.commands` (`commands` in the manifest, `_execute_action`) | the shortcut works in Cosmos windows; `onCommand` gets the command and the tab |
| `chrome.tabs.create`, an options page | the page opens as a Cosmos tab (a script-sized popup window opens as a popup) |

## Adding extensions

Open **Cosmos ▸ Extensions…** (or type "extensions" in the Command Bar).

| Way | What it does |
|---|---|
| **Find in Arc and Other Browsers** | Lists the extensions installed in Arc, Chrome, Brave, Edge, Vivaldi, Opera and Chromium on this Mac. Tick the ones you want and choose Add Selected. |
| **Chrome Web Store link or id** | Paste `https://chromewebstore.google.com/detail/…/<id>` or the 32-letter id. Cosmos downloads the package from Google's update service and unpacks it. |
| **Choose a Folder** | Any unpacked extension folder that contains `manifest.json`. Handy for extensions you are writing. |

Before anything is copied, Cosmos shows what the extension asks for in plain words ("Read and change your data on all
websites", "See your network requests", "Read files on your Mac that you open in Cosmos") and any parts that will not
show. Adding is a yes or no.

Cosmos copies the extension into its own folder (`Extensions/<id>/` in the data folder), so it keeps working after you
delete Arc. Reading from Arc never changes Arc's files. After an Arc import, the summary tells you how many extensions
Arc had and where to add them.

## Using them

- Every enabled extension is loaded into each profile's Chromium as the profile opens, so each profile (each space
  with its own cookies) has its own copy of the extension's storage, as separate Chrome profiles would.
- Turn an extension off (it unloads at once) or remove it (its files are deleted) in Settings ▸ Extensions.
- Extensions never load in Incognito windows.

## What does not work

- **APIs whose result Chrome shows in its own interface and Cosmos does not draw yet:** `sidePanel`, `notifications`
  and `identity` (Google sign-in). The Add prompt names them when an extension asks for them; the extension still
  loads, and the parts that use those APIs do nothing visible.
- **Chromium's own stores, not Cosmos's.** `chrome.bookmarks` sees Chromium's bookmark store, which is empty (Cosmos's
  pinned tabs and Favorites are not Chromium bookmarks); `chrome.history` sees the history Chromium keeps for the
  profile, not Cosmos's History; `chrome.windows` sees Chromium's invisible windows, not Cosmos's.
- The `frame` context for menu items is not offered (Cosmos does not report which frame a right click was in).
- Extensions that need a companion app (native messaging) were not tested; companion apps register in Chrome's own
  folders, which Cosmos's Chromium does not read, so they will most likely not find it.
- Cosmos does not check an extension's signature. Packages from the Web Store come over HTTPS from Google; extensions
  from Arc or other browsers are copied as they are. Only add extensions you trust.

## How it was checked

- **Live, in headless Chromium** (`PageAgentTests.anExtensionRunsAndItsButtonMenuAndShortcutWork`): a Manifest V3
  extension with a content script, a service worker, a button, a menu item and a shortcut is loaded into a real
  profile. The content script runs on a page; the badge the worker sets reaches Cosmos's button; clicking the button,
  the menu item and the shortcut each reach the worker, which messages the right tab. This test found that an
  extension can have a second, dead worker that Chromium has replaced: Cosmos now delivers to the worker that can
  still reach the extension's APIs and lets go of the other.
- `ChromiumExtensionHostTests`: the mirror of buttons, badges, icons, popups and menus from what the shim reports, and
  that icons are only read from inside the extension's own folder.
- `ExtensionTests`, `ExtensionShortcutTests` (on the fake engine): adding, the permission summary, enabling, removing,
  shortcut parsing and matching, which tab a menu item or shortcut is run over.
- `ChromiumExtensionTests` (CosmosImport): finding extensions in a profile (versions, localized names, themes and apps
  skipped), Web Store link and id parsing, and unwrapping `.crx` packages (CRX2 and CRX3).
- Not checked: real extensions from the Web Store one by one, popups on screen, and anything that needs a person at
  the keyboard.

## For developers

| File | Role |
|---|---|
| `CosmosImport/Browsers/ChromiumExtensions.swift` | finds extensions in Chromium-family profiles |
| `CosmosImport/Browsers/ChromeWebStore.swift` | id and link parsing, download address, `.crx` unwrapping |
| `CosmosKit/Extensions/ExtensionCenter.swift` | the list of installed extensions, install and remove, permission summary, shortcuts, the popup popover |
| `CosmosKit/UI/ExtensionButtons.swift` | the button row |
| `CosmosEngine/Engine.swift` (`EngineExtensions`) | what the browser asks of an engine's extensions: load, unload, buttons, menu items, commands |
| `CosmosChromium/ChromiumExtensionHost.swift` | loads extensions over the pipe (`Extensions.loadUnpacked`), attaches to their service workers, mirrors their UI, delivers clicks (`Extensions.triggerAction` for buttons) |
| `CosmosChromium/Resources/extension-shim.js` | runs in each extension worker before its own code: reports badge, icon, popup and menu calls to Cosmos, and fires `contextMenus.onClicked` and `commands.onCommand` when Cosmos says so |
| `CosmosChromium/Resources/Bridge/` | Cosmos's own small extension in every profile: tab ids for extension events, page zoom, clearing site data |
