# Extensions

Cosmos runs on regular Chromium, so extensions run in Chromium itself, with Chromium's own, complete `chrome.*` APIs:
content scripts, service workers, `declarativeNetRequest`, `webRequest`, `storage`, `scripting`, `tabs`, `windows`,
`cookies`, `alarms`, `offscreen`, messaging and the rest behave as they do in Chrome, because they are Chrome's code.
Manifest V3 extensions work; Manifest V2 ones only as far as the Chromium in use still loads them (Chrome has been
removing V2).

> **On CEF, not working yet.** Cosmos now runs Chromium through CEF, and its pages are not Chrome tabs: `chrome.tabs`
> finds none of them and the button cannot be clicked through `Extensions.triggerAction`, and Cosmos attaches to an
> extension's worker only once it has started, so the shim misses the worker's first lines. Extensions load, and their
> content scripts and `declarativeNetRequest` rules run, in the default profile only; the button, popup, menu items,
> shortcuts, notifications, side panel and sign-in described below wait for the extension step in
> [cef-engine.md](cef-engine.md). The live tests for them are switched off until then.

What Cosmos adds is the part Chrome would draw: Chromium has no toolbar or menus of its own here, so
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
| `chrome.notifications`: `create`, `update`, `clear`, buttons, icons | posted to macOS as Cosmos's own notifications; a click, a button or closing it reaches `onClicked`, `onButtonClicked` and `onClosed` |
| `chrome.sidePanel`: `side_panel` in the manifest, `setOptions` (per tab too), `setPanelBehavior({ openPanelOnActionClick })`, `open` | the panel page in a column at the right of the window, with the extension's own APIs; the action button opens and closes it when the extension asks |
| `chrome.identity.launchWebAuthFlow` (interactive) | the sign-in page opens in a window; the flow ends when the site sends it to `https://<id>.chromiumapp.org/…` |
| `chrome.identity.getAuthToken` | Google's sign-in page for the manifest's `oauth2` client, through the same window (see below) |

## Adding extensions

Open **Cosmos ▸ Extensions…** (or type "extensions" in the Command Bar).

| Way | What it does |
|---|---|
| **Find in Arc and Other Browsers** | Lists the extensions installed in Arc, Chrome, Brave, Edge, Vivaldi, Opera and Chromium on this Mac. Tick the ones you want and choose Add Selected. |
| **Chrome Web Store link or id** | Paste `https://chromewebstore.google.com/detail/…/<id>` or the 32-letter id. Cosmos downloads the package from Google's update service and unpacks it. |
| **Choose a Folder** | Any unpacked extension folder that contains `manifest.json`. Handy for extensions you are writing. |

Before anything is copied, Cosmos shows what the extension asks for in plain words ("Read and change your data on all
websites", "See your network requests", "Read files on your Mac that you open in Cosmos") and, for an extension that
signs in to Google, that its sign-in goes through a web page. Adding is a yes or no.

Cosmos copies the extension into its own folder (`Extensions/<id>/` in the data folder), so it keeps working after you
delete Arc. Reading from Arc never changes Arc's files. After an Arc import, the summary tells you how many extensions
Arc had and where to add them.

## Using them

- Every enabled extension is loaded into each profile's Chromium as the profile opens, so each profile (each space
  with its own cookies) has its own copy of the extension's storage, as separate Chrome profiles would.
- Turn an extension off (it unloads at once) or remove it (its files are deleted) in Settings ▸ Extensions.
- Extensions never load in Incognito windows.

## What does not work

- **`identity.getAuthToken` has no Google account in the browser.** Chrome signs an extension in with the Google
  account Chrome is signed in to; Chromium has none here, so Cosmos opens Google's own sign-in page for the extension's
  `oauth2` client instead, as `launchWebAuthFlow` would. Some Google services refuse a token made that way, and the
  Add prompt says so for an extension with `oauth2` in its manifest. `launchWebAuthFlow` itself works as in Chrome: an
  interactive flow opens as a window, and ends when the site sends it to the extension's `chromiumapp.org` address.
- **Chromium's own stores, not Cosmos's.** `chrome.bookmarks` sees Chromium's bookmark store, which is empty (Cosmos's
  pinned tabs and Favorites are not Chromium bookmarks); `chrome.history` sees the history Chromium keeps for the
  profile, not Cosmos's History (Clear History and deleting a page from History empty it too); `chrome.windows` sees Chromium's invisible windows, not Cosmos's.
- The `frame` context for menu items is not offered (Cosmos does not report which frame a right click was in).
- Extensions that need a companion app (native messaging) were not tested; companion apps register in Chrome's own
  folders, which Cosmos's Chromium does not read, so they will most likely not find it.
- Cosmos does not check an extension's signature. Packages from the Web Store come over HTTPS from Google; extensions
  from Arc or other browsers are copied as they are. Only add extensions you trust.

## How it was checked

What follows was checked on headless Chromium, before CEF; on CEF these tests are switched off until Cosmos answers
`chrome.tabs` and the button itself.

- **Live, in headless Chromium** (`PageAgentTests.anExtensionRunsAndItsButtonMenuAndShortcutWork`): a Manifest V3
  extension with a content script, a service worker, a button, a menu item and a shortcut is loaded into a real
  profile. The content script runs on a page; the badge the worker sets reaches Cosmos's button; clicking the button,
  the menu item and the shortcut each reach the worker, which messages the right tab. This test found that an
  extension can have a second, dead worker that Chromium has replaced: Cosmos now delivers to the worker that can
  still reach the extension's APIs and lets go of the other. A later one found that the first click in a tab opened a
  stray page a second later: to find the tab target `Extensions.triggerAction` wants, Cosmos looks into Chromium's
  tabs, and the profile took each tab for a new page. Tabs are now left alone, and the lookup ends on Chromium's
  answer rather than a timer, so a slow Chromium (paused for two seconds in
  `anExtensionsButtonStillWorksWhenChromiumIsSlowToSayWhichTabThePageIsIn`) no longer loses the click.
- **Live, too:** an extension's notification is posted and its click and button reach the extension
  (`anExtensionsNotificationIsPostedAndItsClickReachesTheExtension`); its side panel opens as a page with the
  extension's APIs (`anExtensionsSidePanelOpensAsAPageCosmosShows`); an interactive `launchWebAuthFlow` opens a window
  and resolves with the address the site sent it to (`anExtensionsSignInOpensAWindowAndEndsWhereTheSiteSendsBack`).
  `getAuthToken` against Google itself was not tried.
- `ChromiumExtensionHostTests`: the mirror of buttons, badges, icons, popups and menus from what the shim reports, and
  that icons are only read from inside the extension's own folder.
- `ExtensionTests`, `ExtensionShortcutTests` (on the fake engine): adding, the permission summary, enabling, removing,
  shortcut parsing and matching, which tab a menu item or shortcut is run over.
- `ChromiumExtensionTests` (CosmosImport): finding extensions in a profile (versions, localized names, themes and apps
  skipped), Web Store link and id parsing, and unwrapping `.crx` packages (CRX2 and CRX3).
- Not checked: real extensions from the Web Store one by one, popups, side panels and notifications on screen, and
  anything that needs a person at the keyboard.

## For developers

| File | Role |
|---|---|
| `CosmosImport/Browsers/ChromiumExtensions.swift` | finds extensions in Chromium-family profiles |
| `CosmosImport/Browsers/ChromeWebStore.swift` | id and link parsing, download address, `.crx` unwrapping |
| `CosmosKit/Extensions/ExtensionCenter.swift` | the list of installed extensions, install and remove, permission summary, shortcuts, the popup popover |
| `CosmosKit/UI/ExtensionButtons.swift` | the button row |
| `CosmosEngine/Engine.swift` (`EngineExtensions`) | what the browser asks of an engine's extensions: load, unload, buttons, menu items, commands |
| `CosmosChromium/ChromiumExtensionHost.swift` | loads extensions over the pipe (`Extensions.loadUnpacked`), attaches to their service workers, mirrors their UI, delivers clicks (`Extensions.triggerAction` for buttons) |
| `CosmosChromium/Resources/extension-shim.js` | runs in each extension worker before its own code: reports badge, icon, popup, menu, notification, side panel and sign-in calls to Cosmos, and fires `contextMenus.onClicked`, `commands.onCommand`, the notification events and the end of a sign-in flow when Cosmos says so |
| `CosmosChromium/Resources/Bridge/` | Cosmos's own small extension in the default profile: tab ids for extension events, clearing site data and Chromium's own history |
