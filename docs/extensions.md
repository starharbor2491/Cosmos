# Extensions

Cosmos runs on Chromium (through CEF), so extensions run in Chromium itself, with Chromium's own `chrome.*` APIs:
content scripts, service workers, `declarativeNetRequest`, `webRequest`, `storage`, `cookies`, `alarms`, `offscreen`,
`runtime` messaging and the rest behave as they do in Chrome, because they are Chrome's code. Manifest V3 extensions
work; Chromium 156 no longer loads Manifest V2 ones.

**Tabs are Cosmos's.** CEF draws Cosmos's pages without Chrome's windows around them, so Chromium knows of no tabs.
Cosmos loads each extension from a copy (in `Cosmos Extensions/` of the default profile's folder) with a script of its
own ahead of the extension's: in its service worker, before each of its content scripts and at the top of each of its
pages. Through it, Cosmos answers `chrome.tabs`, `chrome.windows` and `chrome.scripting` with its own tabs, by tab ids
of its own:

- `tabs.query` (by Cosmos's tabs: the tab a window shows is `active`, Favorites and pinned tabs are `pinned`; the
  `audible`, `muted`, `discarded` and `groupId` filters match as for a tab that is none of those), `get`, `getCurrent`, `create`, `update`, `remove`, `reload`, `goBack`, `goForward`, `duplicate`,
  `highlight`, `captureVisibleTab`, `sendMessage` (to the tab's content scripts, every frame or one), `getZoom`,
  `setZoom`, `detectLanguage`; the events `onCreated`, `onUpdated`, `onRemoved` and `onActivated`, to the worker and
  the extension's pages.
- `windows.getAll`, `get`, `getCurrent`, `getLastFocused`, `create` (a popup is a small window, anything else a tab),
  `update`.
- `scripting.executeScript` (a function with arguments, or files; the extension's world or the page's), `insertCSS`,
  `removeCSS`, and content scripts registered at run time. Each extension's world in a page is its own, even for two
  extensions of the same name. `insertCSS` adds a `<style>` element from the extension's world, so a page can see it,
  and a strict `style-src` policy of the page can refuse it, where Chrome's would apply.
- A content script's messages and ports say which tab and frame they came from (`sender.tab`, `sender.frameId`), as
  Chrome's do.
- The permissions are Chrome's: a tab's address and title only with `tabs`, a host permission for its site, or
  `activeTab`, which a click on the extension's button, menu item or shortcut gives for that tab until it goes to
  another site; scripts only with `scripting` and where a host permission or `activeTab` reaches; `captureVisibleTab`
  only with `<all_urls>` or `activeTab`. As in Chrome, the sites of an extension's content scripts are not host
  permissions. A frame with no address of its own (`about:blank`, `srcdoc`) counts as its origin. An extension opens
  only websites, `about:blank` and its own pages.
- An API that needs a permission (`contextMenus`, `notifications`, `sidePanel`, `identity`, `scripting`) does nothing
  without it, also when an extension's script posts to Cosmos directly instead of through the `chrome.*` call.
  Cosmos takes a script to run only as a function's source and its arguments, or files of the extension, but it cannot
  tell a function written in the extension from one it fetched: Manifest V3's rule against code from elsewhere holds
  for `executeScript` only as far as the extension's own content security policy holds it.
- An extension whose folder has a link in it (to a file anywhere else), or whose service worker is outside its
  folder, is not loaded: Cosmos writes to its copy, and would write through the link. Nor is one that copies the `key`
  of Cosmos's own bridge extension (and so has its id).
- Not there: `tabs.connect` (`tabs.sendMessage` works), tab groups, and muting; `windows.remove` does nothing.
- Extensions load into the default profile only (the first profile's spaces); Chromium's DevTools protocol loads them
  nowhere else.

What Cosmos adds is the part Chrome would draw: Chromium has no toolbar or menus of its own here, so
Cosmos draws the extension's button, badge and popup, its right-click menu items and its keyboard shortcuts, and sends
your clicks and key presses back to the extension. That mirror is the "equivalent API" for the parts of `chrome.*`
that end in browser UI:

| Extension API | In Cosmos |
|---|---|
| `chrome.action` / `chrome.browserAction`: title, icon, badge text and colour, enable / disable, per-tab values | the button in a row under the address pill, with its badge |
| the action's popup (`default_popup`, `setPopup`) | the popup page in a panel under the button (from a shortcut, in the tab's top-right corner), grown to what the page lays out (within Chrome's limits); it closes when the keyboard goes elsewhere, as a click outside it does. Dragged by the bar along its top, it leaves the button and stays where it is put, over Cosmos's windows, until its close button, ⌘W or turning its extension off (a drag keeps the bar below the menu bar and on the screen). (Not a popover: macOS shows none of Chromium's drawing in one, only a white box.) |
| `action.onClicked` (no popup) | clicking the button; Cosmos starts the extension's worker if it is not running, and the listeners get the tab |
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
| **Add to Chrome, on the Chrome Web Store** | Browse the Web Store in Cosmos and choose Add to Chrome: Cosmos asks, over the tab, what Settings would ask, then adds it the way a pasted link does. (Chromium has the store's install API on the store's pages but would ask with a window of Chrome's own, which it has no place for here; Cosmos's page script hands the request to Cosmos instead, and only the store's own top-level page can make it, right after a click, as in Chrome. Clicking again while Cosmos still asks adds nothing more.) The store's "Switch to Chrome?" note can be dismissed. |
| **Chrome Web Store link or id** | Paste `https://chromewebstore.google.com/detail/…/<id>` or the 32-letter id. Cosmos downloads the package from Google's update service (asking as the Chromium it runs, so it gets the version made for it), checks that its developer signed it for that id, and unpacks it. |
| **Choose a Folder** | Any unpacked extension folder that contains `manifest.json`. Handy for extensions you are writing. |

Before anything is copied, Cosmos shows what the extension asks for in plain words ("Read and change your data on all
websites", "See your network requests", "Read files on your Mac that you open in Cosmos") and, for an extension that
signs in to Google, that its sign-in goes through a web page. Adding is a yes or no.

Cosmos copies the extension into its own folder (`Extensions/<id>/` in the data folder), so it keeps working after you
delete Arc. Reading from Arc never changes Arc's files. After an Arc import, the summary tells you how many extensions
Arc had and where to add them.

An extension from the Web Store keeps the Web Store's id: Cosmos writes its developer's key into the manifest of its
copy (`key`), as Chrome does when it installs one, and Chromium makes the id from that key. Sites, sign-in pages
(`https://<id>.chromiumapp.org`) and companion apps that know the extension by its id still do, and its data stays
with it across updates. Extensions from Arc and other Chromium browsers already have the key in their manifests.

## Updates

Once a day (and a few minutes after Cosmos starts), Cosmos asks Google's update service about every extension that came
from the Web Store, or from another browser with a Web Store id, in one request, as Chrome does. For each newer version:

- its package must be signed by the extension's own developer, for that id, and match the SHA-256 the service gave;
  one that isn't is not installed, and Settings ▸ Extensions says so under the extension;
- its manifest must be the version the service announced (an older package, however well signed, is no update);
- if it asks for nothing more than the version you have (no new permission, no new site), it replaces that version
  by itself, in the same place in Chromium, with its data;
- if it asks for more, it waits: Settings ▸ Extensions shows that the new version is ready, and **Update…** shows what
  it asks for, as adding one does. Until then the version you have keeps running.

A disabled extension is updated too and stays off. **Check Now** in Settings ▸ Extensions asks at once. One exception
to "with its data": an extension added from the Web Store by a Cosmos from before this check has no `key` in its copy,
so Chromium knows it by an id made from its folder; its first update brings the key and the Web Store's id, and what
it had stored under the old id is left behind.

## Using them

- Every enabled extension is loaded into the default profile (the first one) as it opens. Spaces with a profile of
  their own have no extensions: Chromium's DevTools protocol loads them into the default profile only.
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
- Packages from the Web Store are checked against their developer's signature (the Web Store's own countersignature
  is not checked: the developer's is what ties the files to the id). Extensions from Arc or other browsers are copied
  as they are on disk, unchecked, until their first update from the Web Store; and an unpacked folder you choose is
  never checked. Only add extensions you trust.

## How it was checked

The live tests run on CEF, in the test process. Besides the ones below, `PageAgentTests` checks what an extension sees
of Cosmos's tabs and what its permissions hide, opening tabs and running scripts only where it may, a popup that asks
for its tab, and the `chrome.tabs` events. The tests below were first written for headless Chromium and pass on CEF.

- **Live** (`PageAgentTests.anExtensionRunsAndItsButtonMenuAndShortcutWork`): a Manifest V3 extension with a content
  script, a service worker, a button, a menu item and a shortcut is loaded into a real profile. The content script
  runs on a page; the badge the worker sets reaches Cosmos's button; clicking the button, the menu item and the
  shortcut each reach the worker, which messages the right tab. An extension can have a second, dead worker that
  Chromium has replaced: Cosmos delivers to the worker that can still reach the extension's APIs and lets go of the
  other. On CEF these tests found that an extension loaded before Chromium was running was loaded twice (starting
  Chromium loads every extension), and the second load replaced the worker mid-sign-in; and that a click right after
  loading came before the worker had run its first line.
- **Live, too:** an extension's notification is posted and its click and button reach the extension
  (`anExtensionsNotificationIsPostedAndItsClickReachesTheExtension`); its side panel opens as a page with the
  extension's APIs (`anExtensionsSidePanelOpensAsAPageCosmosShows`); an interactive `launchWebAuthFlow` opens a window
  and resolves with the address the site sent it to (`anExtensionsSignInOpensAWindowAndEndsWhereTheSiteSendsBack`).
  `getAuthToken` against Google itself was not tried. A popup shows what its page draws, under its button or with none in
  the tab's top-right corner, at the page's size, and closes when its window loses the keyboard
  (`anExtensionsPopupShowsWhatItsPageDraws`, from the window server's picture of the popup's window, kept off screen);
  in a popover it was white. Dragged by its bar, a popup follows the pointer (not for a click's wobble), keeps the bar on
  the screen, leaves its button's window, stays open when the keyboard goes elsewhere or another popup opens, and
  closes from its close button, ⌘W or its extension being turned off (`ExtensionTests.aPopupDraggedByItsBarStaysOpenWhereItIsPut`,
  which moves the bar's grab point itself rather than the mouse; `PopupPlacementTests`).
- `ChromiumExtensionHostTests`: the mirror of buttons, badges, icons, popups and menus from what the shim reports, and
  that icons are only read from inside the extension's own folder.
- `ExtensionTests`, `ExtensionShortcutTests` (on the fake engine): adding, the permission summary, enabling, removing,
  shortcut parsing and matching, which tab a menu item or shortcut is run over.
- `ChromiumExtensionTests` (CosmosImport): finding extensions in a profile (versions, localized names, themes and apps
  skipped), and Web Store link and id parsing.
- `WebStoreTests`, on packages made in the test as the Web Store makes them (CRX3, signed with a key of the test's):
  a package signed for its id is taken; a changed one, one for another id, one whose signature covers other files, one
  that claims an id its key does not make, a CRX2 and a bare zip are refused. The update service's address (the running
  Chromium's version, CRX3, every extension at once) and its answer (Google's `gupdate` form, taken from a real answer);
  an extension installed from the Web Store gets its key and the Web Store's id; an update that asks for nothing more
  comes in by itself under the same id (the engine never lets go of it), one that asks for more waits and shows what
  it asks for, and one with the wrong SHA-256 or another developer's signature stays out; a disabled one stays off.
  `aNewerCopyOfAnExtensionKeepsItsIDAndItsData` (live Chromium): a second copy with the same key, in another folder,
  takes the first one's place under the same id and reads what it stored. `onlyTheWebStoresOwnPageCanAskToAddAnExtension`
  (live Chromium): Add to Chrome reaches Cosmos from a click on the store's top-level page only, not without a click,
  from another site or from a frame. `aSecondAddToChromeWhileTheFirstIsAskedAddsNothing`: one question, one copy.
  Checked once by hand (2026-10-30), not in the tests: a real Web Store package (uBlock Origin Lite) passes the signature
  check and installs, and on the real store page Add to Chrome reaches Cosmos with its id.
- Not checked: real extensions from the Web Store one by one; side panels and notifications on screen; popups on a
  real screen in the app (a click elsewhere closing one, typing into one, a drag with the mouse, the bar, corners and
  shadow); and anything that
  needs a person at the keyboard.

## For developers

| File | Role |
|---|---|
| `CosmosImport/Browsers/ChromiumExtensions.swift` | finds extensions in Chromium-family profiles |
| `CosmosImport/Browsers/ChromeWebStore.swift` | id and link parsing, download address, `.crx` unwrapping |
| `CosmosKit/Extensions/ExtensionCenter.swift` | the list of installed extensions, install and remove, permission summary, shortcuts, the popup's panel |
| `CosmosKit/UI/ExtensionButtons.swift` | the button row |
| `CosmosEngine/Engine.swift` (`EngineExtensions`) | what the browser asks of an engine's extensions: load, unload, buttons, menu items, commands |
| `CosmosChromium/ChromiumExtensionHost.swift` | loads extensions over the pipe (`Extensions.loadUnpacked`), attaches to their service workers, mirrors their UI, answers `chrome.tabs`, `chrome.windows` and `chrome.scripting` by Cosmos's tabs and the extension's permissions, delivers clicks |
| `CosmosChromium/ExtensionStage.swift` | the copy of an extension Chromium loads, with Cosmos's scripts ahead of the extension's own |
| `CosmosChromium/Resources/extension-shim.js` | runs in each extension's worker and pages before its own code: Cosmos's `chrome.tabs`, `chrome.windows` and `chrome.scripting`, reports badge, icon, popup, menu, notification, side panel and sign-in calls to Cosmos, and fires the button, `contextMenus.onClicked`, `commands.onCommand`, the notification events, the tab events and the end of a sign-in flow when Cosmos says so |
| `CosmosChromium/Resources/extension-content.js` | runs before each extension's content scripts: which tab they are in, for their messages and ports, and `tabs.sendMessage` coming in |
| `CosmosKit/Extensions/ExtensionTabs.swift` | Cosmos's tabs and windows as extensions see them |
| `CosmosChromium/Resources/Bridge/` | Cosmos's own small extension in the default profile: clearing site data and Chromium's own history |
