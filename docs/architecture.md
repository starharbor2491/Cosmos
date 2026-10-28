# How Cosmos is put together

Cosmos is a Swift package of six libraries and two executables. Each layer imports only the ones above it.

```
CosmosCore      the model, storage and search ranking. Foundation and SQLite only: no UI, no engine.
CosmosImport    reads Arc, Chromium, Firefox and Safari data; finds extensions in other browsers
CosmosBlocking  filter list parser and compiler to Chromium declarativeNetRequest rules
CosmosEngine    the protocols a web engine implements for Cosmos (BrowserEngine, EngineProfile, EnginePage, EngineExtensions)
CosmosChromium  the engine Cosmos runs: regular Chromium, headless, driven over the DevTools protocol
CosmosKit       the browser: AppKit and SwiftUI, talking to the engine only through CosmosEngine
Cosmos          the app: three lines that call CosmosKit
cosmos-cli      import and inspect from the terminal
```

Keeping the model free of UI is what makes most of the behaviour testable without opening a window: the whole sidebar tree, archiving, link routing, ranking and history are plain value types with tests. Keeping the browser free of the engine is what makes it testable without Chromium: `FakeEngine` in the tests records what the store asked of the engine.

## The data model (CosmosCore)

**Workspace** is one flat table of `SidebarItem`s, each with a `parentID` and ordered `childIDs`. An item is a tab, a folder or a split (a container of up to four tabs). Four kinds of root exist: Favorites (one, shared), and for each space a Pinned root and an Unpinned ("Today") root. A tab's place in the sidebar is just its parent chain, so moving, pinning, favoriting and archiving are all re-parenting, and `Workspace.problems()` can check that the table is consistent (every child has the right parent, no cycles, nothing orphaned). `repair()` fixes what a bad file or a bug left behind.

A **Space** has a title, an icon, a **SpaceTheme** (gradient colours and angle, intensity, grain, starfield, light or dark) and a profile id. A **Profile** maps to an engine profile: with Chromium, a Chromium process of its own with its own data folder (`Engine Profiles/<id>/`), which is how separate cookies per space work.

Other pieces:

- **Archive**: archived tabs with the reason (closed, auto, imported), their space and when.
- **Boost / BoostLibrary**: per-host colour filter, font, zoom, zap selectors, CSS and JS.
- **LinkRouting**: where links from other apps go (Probe, most recent space, a space), with per-site rules.
- **RadialMenu** (`RadialSettings`, `RadialAction`, `RadialLayout`, `RadialGeometry`): what the right-click ring holds for each kind of thing under the pointer, which sites keep the system menu, and where each slice is. No AppKit.
- **MenuBar** (`MenuBarSettings`, `MenuBarPlacement`, `MenuBarToggle`): the menu-bar browser's settings, where its panel goes under the icon, and the click debounce.
- **HistoryStore**: SQLite, with visit counts and a *frecency* score (recent and frequent beats old and frequent).
- **CommandRanker, CommandComposer, LearnedSelections**: how the Command Bar decides what to show: fuzzy and prefix matching on titles and hosts, de-duplication by address, frecency, a bonus for results you picked before for the same query, then the composer adds the typed address, a web search, a calculator answer and site-search hints.
- **PublicSuffixList, URLInput**: turn what you type into an address or a search, and tell `github.com` from `foo.github.io`.
- **JSONFileStore**: atomic writes and dated backups for every JSON file.

## The engine seam (CosmosEngine)

Everything the browser needs from whatever draws web pages is in `Engine.swift`:

- **BrowserEngine**: its status (downloading, starting, ready, failed), version, update checks, and `makeProfile(id:directory:)` (a nil directory keeps nothing: incognito).
- **EngineProfile**: one profile's pages, the scripts every page gets, content blocking (compiled lists plus the sites switched off), extensions, clearing site data, the engine's process ids for the Resources view, restart and close.
- **EnginePage**: a page and its `NSView`; load, reload, history, zoom, user agent, script evaluation in a named world, edit commands, snapshots, PDF, downloads, the last right click, memory and processor use. Its delegate hears about navigation, failures, agent messages, dialogs, file choosers, permission requests, Force Touch, close requests and crashes.
- **EngineExtensions**: load and unload a folder, the buttons, menu items and commands to draw, and the user's clicks back.

CosmosKit imports `CosmosEngine`, never `CosmosChromium`; only `AppDelegate` names `ChromiumEngine`, when it makes the one engine. Another engine is a new module that implements these four protocols.

## The Chromium engine (CosmosChromium)

Cosmos runs regular, unmodified Chromium: no fork, no patches, no CEF or Electron.

- **One process per profile.** `ChromiumProfile` starts Chromium with `--headless --remote-debugging-pipe --user-data-dir=<the profile's folder>`: no window, no Dock icon, and no debugging port that anything else on the Mac could reach. Cosmos talks to it over two pipes (descriptors 3 and 4) with NUL-terminated DevTools protocol messages (`CDPConnection`). Chromium's crash folder is moved into the profile too (`BREAKPAD_DUMP_LOCATION`), so nothing is written to `~/Library/Application Support/Chromium`.
- **Pages are tabs.** Each `ChromiumPage` is a page target. Cosmos attaches to every target before it runs (Chromium waits for it), so the page agent and Boosts are in place for the first document. Pages a site or an extension opens arrive the same way and become Cosmos tabs or popups.
- **Cosmos draws the pages.** Chromium renders offscreen and streams frames (`Page.startScreencast`); `ChromiumPageView` puts the newest on its layer and turns AppKit mouse, scroll and key events into `Input.dispatch*` events (`KeyMapping`). Frames come at device-independent size, so the bridge extension zooms each page by the screen's scale to keep text sharp.
- **Settings are folded in.** Cosmos's Settings are the only settings. Before Chromium starts, `ChromiumPreferences` writes them into `Default/Preferences` and `Local State`, with the same keys Chromium's own Settings page writes: fonts and sizes, default zoom, cookies, JavaScript, images, pop-ups, sound, site permission defaults, Do Not Track, preloading, HTTPS-first, WebRTC, languages, secure DNS, hardware acceleration. Chromium's password and autofill prompts are off (they have nowhere to show). They are in Settings ▸ Engine; after a change there, Restart Engine starts every profile's Chromium again with the new settings, and open tabs reload.
- **Updates.** `ChromiumInstall` downloads Chromium from Google's public `chromium-browser-snapshots` bucket (`Mac_Arm` or `Mac`), checks its MD5 against the bucket's record, unpacks it under `~/Library/Application Support/Cosmos/Chromium/` and starts it headless once to make sure it runs. It looks for a newer snapshot once a day; a new one is used from the next launch, the one before is kept, and a snapshot that will not start is marked bad and never tried again while the previous one comes back. Settings ▸ Engine shows the version and has Check Now.
- **Extensions** run in Chromium with its own APIs; `ChromiumExtensionHost` and the shim mirror what Chrome would draw for them. See [extensions.md](extensions.md).
- **Blocking** is an extension Cosmos writes into each profile from the compiled lists. See [ad-blocking.md](ad-blocking.md).

## The browser (CosmosKit)

- **BrowserStore** (`@MainActor @Observable`) owns one profile's workspace, archive, boosts, routing, settings and history, and implements `TabHost`. Everything the UI can do to the model goes through it (`BrowserStore+Tabs`, `+Navigation`, `+Adopt`, `Commands`, `ImportCoordinator`, `BoostLive`). Edits go through `edit { ws in … }`, which also schedules a debounced save. An incognito window gets its own `BrowserStore` with no directory, so nothing is written.
- **WindowState** is per window: the focused space, the selected item in each space, recent tabs, sidebar width, overlays (Command Bar, Boosts, …), which sidebar page is showing (the Library or a space) and which Library section, Peek and toasts. Windows are independent: two windows can show two spaces.
- **TabRuntime** is one live page: an `EnginePage` and Cosmos's side of it (the agent's reports, the error page, dialogs, permissions, the right-click menu). Sidebar tabs exist without a runtime until selected, which is why thousands of pinned and archived tabs cost nothing. Runtimes are keyed by `(item, profile)`; the memory saver discards idle ones and they reload on demand.
- **ProfileEnvironment** is one per profile: its `EngineProfile`, the page scripts (a small page agent in Cosmos's own script world, Boost scripts and style sheets in the page's world), and the profile's share of blocking and extensions.
- **Overlays and chrome** are SwiftUI (`BrowserRootView` in an `NSHostingView`), with page views hosted through `NSViewRepresentable`. The sidebar, Command Bar, Peek, find bar, panels and theme editor are in `UI/`. The window uses `fullSizeContentView`, so the space's gradient runs behind the traffic lights.
- **Radial menu** (`RadialSession`, `RadialMenuView`, `PageContextMenu`): the engine draws no menu of its own. The page agent reports what is under the pointer on a right click, Cosmos builds the menu from that (and adds extensions' items), then shows it as a ring over the page or as an ordinary menu at the pointer. A page that handles `contextmenu` itself keeps its own menu.
- **Menu-bar browser** (`MenuBarBrowser`, `MenuBarSession`, `MenuBarBrowserView`): an `NSStatusItem` and a non-activating `NSPanel`. The page is a `TabRuntime` made from a profile's `ProfileEnvironment`, so it uses that profile's cookie jar, blocking and Boosts; its host (`MenuBarHost`) loads new-window links in place and sends what belongs in a window there.
- **Settings** (`Settings/`): every control is drawn here (see `SettingsControls.swift`). Open dropdown lists are drawn by the window itself (`DropdownHost`), not inline.
- **App shell** (`App/`): the app delegate (the engine, windows, link routing, key handling), the main menu (every item carries a `MenuAction`), Probe windows, Settings, the demo seed and the automation harness.

### Decisions worth knowing

- **Web pages never see Cosmos.** The page agent runs in an isolated script world named `cosmos`, the only world that can call `__cosmosPost` (a DevTools binding) to talk to the app; Boosts run in the page's world only because they have to.
- **Shortcuts beat pages.** A local key monitor handles chords that menu key equivalents can't express reliably (⌃⇧=, ⌃Tab, ⌥⌘ arrows) before any responder sees them, as Arc does.
- **One blocker, many profiles.** `ContentBlockerController` compiles the lists once and hands the same rulesets to every profile. The per-site switch is an `allowAllRequests` rule in the same extension, so switching a site off rewrites one small file and compiles nothing.
- **Honest import reports.** Every importer returns counts and generic notes, never titles or addresses, so a report can be pasted into a bug report.

## Files on disk

See the table in the [README](../README.md#where-your-data-lives).

## Traps in this toolchain

These cost time once; they are written down so they cost it only once.

- Building with only the Command Line Tools means the SwiftUI macro plugin is missing: `@State` does not compile. The repo has `@Local` (`UI/Local.swift`), a thin wrapper over `State`. Avoid `@Entry` and `@Previewable` for the same reason.
- Swift Testing's `#expect` can't call mutating methods; do the mutation first.
- `swift test` sometimes fails with "plugin for module 'TestingMacros' not found". It is a toolchain flake. Use `scripts/test.sh`, which hands the compiler the testing macros itself and retries if it still happens.
- A test that starts Chromium must stop it (`engine.shutdown()`, done in `defer`), or the Chromium processes outlive the test run.
