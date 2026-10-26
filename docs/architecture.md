# How Cosmos is put together

Cosmos is a Swift package of five libraries and two executables. Each layer imports only the ones above it.

```
CosmosCore      the model, storage and search ranking. Foundation and SQLite only: no UI, no WebKit.
CosmosImport    reads Arc, Chromium, Firefox and Safari data; finds extensions in other browsers
CosmosBlocking  filter list parser and compiler to WebKit content rules
CosmosKit       the browser: AppKit, SwiftUI, WKWebView
Cosmos          the app: three lines that call CosmosKit
cosmos-cli      import and inspect from the terminal
```

Keeping the model free of UI is what makes most of the behaviour testable without opening a window: the whole sidebar tree, archiving, link routing, ranking and history are plain value types with tests.

## The data model (CosmosCore)

**Workspace** is one flat table of `SidebarItem`s, each with a `parentID` and ordered `childIDs`. An item is a tab, a folder or a split (a container of up to four tabs). Four kinds of root exist: Favorites (one, shared), and for each space a Pinned root and an Unpinned ("Today") root. A tab's place in the sidebar is just its parent chain, so moving, pinning, favoriting and archiving are all re-parenting, and `Workspace.problems()` can check that the table is consistent (every child has the right parent, no cycles, nothing orphaned). `repair()` fixes what a bad file or a bug left behind.

A **Space** has a title, an icon, a **SpaceTheme** (gradient colours and angle, intensity, grain, starfield, light or dark) and a profile id. A **Profile** maps to a `WKWebsiteDataStore(forIdentifier:)`, which is how separate cookies per space work.

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

## The browser (CosmosKit)

- **BrowserStore** (`@MainActor @Observable`) owns one profile's workspace, archive, boosts, routing, settings and history, and implements `TabHost`. Everything the UI can do to the model goes through it (`BrowserStore+Tabs`, `+Navigation`, `+Adopt`, `Commands`, `ImportCoordinator`, `BoostLive`). Edits go through `edit { ws in … }`, which also schedules a debounced save. An incognito window gets its own `BrowserStore` with no directory, so nothing is written.
- **WindowState** is per window: the focused space, the selected item in each space, recent tabs, sidebar width, overlays (Command Bar, Archive, Boosts, …), Peek and toasts. Windows are independent: two windows can show two spaces.
- **TabRuntime** is one live page (`WKWebView` plus its delegates for navigation, UI, downloads and permissions). Sidebar tabs exist without a runtime until selected, which is why thousands of pinned and archived tabs cost nothing. Runtimes are keyed by `(item, profile)`; the memory saver discards idle ones and they reload on demand.
- **ProfileEnvironment** is one per profile: its data store, one `WKUserContentController` (a small page agent in WebKit's client world, Boost scripts and style sheets in the page world, content rule lists, and the extension controller) and the configuration every tab of that profile is created with.
- **Overlays and chrome** are SwiftUI (`BrowserRootView` in an `NSHostingView`), with web views hosted through `NSViewRepresentable`. The sidebar, Command Bar, Peek, find bar, panels and theme editor are in `UI/`. The window uses `fullSizeContentView`, so the space's gradient runs behind the traffic lights.
- **Radial menu** (`RadialSession`, `RadialMenuView`, `TabRuntime.presentRadialMenu`): the page agent reports what is under the pointer just before WebKit asks for its context menu; `CosmosWebView.willOpenMenu` hands that menu to the store, which puts a ring over the page and cancels the system menu (its items are kept alive and run when a slice is chosen). A page that handles `contextmenu` itself never asks WebKit for a menu, so it never gets a ring.
- **Menu-bar browser** (`MenuBarBrowser`, `MenuBarSession`, `MenuBarBrowserView`): an `NSStatusItem` and a non-activating `NSPanel`. The page is a `TabRuntime` made from a profile's `ProfileEnvironment`, so it uses that profile's cookie jar, blocking rules and Boosts; its host (`MenuBarHost`) loads new-window links in place and sends what belongs in a window there.
- **Settings** (`Settings/`): every control is drawn here (see `SettingsControls.swift`). Open dropdown lists are drawn by the window itself (`DropdownHost`), not inline.
- **App shell** (`App/`): the app delegate (windows, link routing, key handling), the main menu (every item carries a `MenuAction`), Probe windows, Settings, the demo seed and the automation harness.

### Decisions worth knowing

- **Web pages never see Cosmos.** The page agent runs in the client content world and talks to the app through a message handler; Boosts run in the page world only because they have to.
- **Shortcuts beat pages.** A local key monitor handles chords that menu key equivalents can't express reliably (⌃⇧=, ⌃Tab, ⌥⌘ arrows) before any responder sees them, as Arc does.
- **One blocker, many profiles.** `ContentBlockerController` compiles the lists once and attaches the same rule lists to every profile's controller. A per-site switch can't remove lists from a shared controller, so it turns blocking off per navigation through WebKit's private `_setContentBlockersEnabled:` preference (guarded with `responds(to:)`, and covered by a test).
- **Extensions are optional machinery.** `ExtensionCenter` works on any macOS; `ExtensionEngine` is `@available(macOS 15.4, *)` and held as `AnyObject`, so the app still runs on macOS 14.
- **Honest import reports.** Every importer returns counts and generic notes, never titles or addresses, so a report can be pasted into a bug report.

## Files on disk

See the table in the [README](../README.md#where-your-data-lives).

## Traps in this toolchain

These cost time once; they are written down so they cost it only once.

- Building with only the Command Line Tools means the SwiftUI macro plugin is missing: `@State` does not compile. The repo has `@Local` (`UI/Local.swift`), a thin wrapper over `State`. Avoid `@Entry` and `@Previewable` for the same reason.
- Swift Testing's `#expect` can't call mutating methods; do the mutation first.
- `swift test` sometimes fails with "plugin for module 'TestingMacros' not found". It is a toolchain flake. Use `scripts/test.sh`, which retries (and clears `.build` on the third try).
- WebKit can't be initialised off the main thread, so tests that touch it are `@MainActor`.
