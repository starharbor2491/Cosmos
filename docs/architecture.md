# How Cosmos is put together

Cosmos is a Swift package of seven libraries and three executables. Each layer imports only the ones above it.

```
CosmosCore      the model, storage and search ranking. Foundation and SQLite only: no UI, no engine.
CosmosImport    reads Arc, Chromium, Firefox and Safari data; finds extensions in other browsers
CosmosBlocking  filter list parser and compiler to Chromium declarativeNetRequest rules
CosmosEngine    the protocols a web engine implements for Cosmos (BrowserEngine, EngineProfile, EnginePage, EngineExtensions)
CosmosCEF       Chromium through CEF, inside Cosmos's process (Objective-C++)
CosmosChromium  the engine Cosmos runs: Chromium's stable release, drawn in Cosmos's windows, driven over the DevTools protocol
CosmosKit       the browser: AppKit and SwiftUI, talking to the engine only through CosmosEngine
Cosmos          the app: three lines that call CosmosKit
CosmosHelper    Chromium's other processes (GPU, renderers, plug-ins), as the helper apps inside Cosmos.app
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
- **EnginePage**: a page and its `NSView`; load, reload, history, zoom, user agent, script evaluation in a named world, edit commands, snapshots, PDF, downloads, the last right click, memory and processor use. Its delegate hears about navigation, failures, agent messages, dialogs, file choosers, permission requests (and is asked for the location to give), sign-in challenges, notifications, Picture in Picture, Force Touch, close requests and crashes, and is asked before every page and frame loads whether its address is dangerous.
- **EngineExtensions**: load and unload a folder, the buttons, menu items, commands, notifications and side panels to draw, and the user's clicks back.

CosmosKit imports `CosmosEngine`, never `CosmosChromium`; only `AppDelegate` names `ChromiumEngine`, when it makes the one engine. Another engine is a new module that implements these four protocols.

## The Chromium engine (CosmosChromium)

Cosmos runs Chromium's stable release through CEF, the Chromium Embedded Framework: no fork and no patches. [cef-engine.md](cef-engine.md) records why and how.

- **One Chromium, inside Cosmos.** `ChromiumRuntime` starts CEF once, in Cosmos's own process, with an external message pump on the main run loop; the renderers, the GPU process and the rest run as the helper apps in `Cosmos.app/Contents/Frameworks`. Cosmos talks to it over the DevTools protocol on a pipe in its own process (descriptors 3 and 4, set up first thing in `main`), with NUL-terminated messages (`CDPConnection`): there is no debugging port anything else on the Mac could reach. The pipe would make `navigator.webdriver` true, which sites such as Google's sign-in refuse, so Chromium also gets `--disable-blink-features=AutomationControlled`.
- **Profiles are CEF request contexts**, each with its own folder in the data folder's `Engine Profiles/`, or nothing on disk for a private window. The first profile is CEF's global context, the only one extensions run in.
- **Pages are CEF browsers.** Each `ChromiumPage` is a CEF browser drawn in a view of Cosmos's (`ChromiumPageView`), and is a page target over the pipe: the browser asks its own DevTools channel which target it is, and Cosmos attaches to it then. A page starts empty and loads its address once the page agent and Boosts are in, so they are there for the first document. Pages a site opens are made by CEF out of sight and move into the page Cosmos makes a tab or popup of; their first document runs before Cosmos is attached ([cef-engine.md](cef-engine.md) says why).
- **Chromium draws the pages** and takes the mouse, keyboard, input methods, drags, the pointer's shape, `<select>` menus and VoiceOver itself. Cosmos's page view only hears of right clicks and Force Clicks on their way in.
- **Settings are folded in.** Cosmos's Settings are the only settings. `ChromiumPreferences` writes them into a profile's `Preferences` before it opens and the browser's `Local State` before Chromium starts, with the same keys Chromium's own Settings page writes: fonts and sizes, cookies, JavaScript, images, pop-ups, sound, site permission defaults, Do Not Track, preloading, HTTPS-first, WebRTC, languages, secure DNS, hardware acceleration. Chromium's own password and autofill prompts are off. They are in Settings ▸ Privacy (privacy and what sites may do) and Settings ▸ Advanced (fonts, languages, the graphics processor); after a change in either, Restart Engine sets them into the running Chromium and reloads open tabs (turning the graphics processor off waits for the next launch).
- **Updates** come with Cosmos: `scripts/fetch-cef.sh` pins one CEF build, and a newer Chromium is a newer Cosmos.
- **What Chrome draws in its own windows, Cosmos draws.** A CEF browser in a view of Cosmos's has no prompts, dialogs or windows of Chrome's, and turns down what would need one, so each piece goes through Cosmos:
  - *Permissions.* `page-bridge.js`, in the page's own world, wraps `getUserMedia`, geolocation, `Notification.requestPermission` and the rest, and asks Cosmos (through the agent's world) before the real call. Cosmos asks the user or answers from what they decided, sets the profile's own permission for that origin (a CEF content setting), then lets the call go on. CEF gives a page the camera or microphone only when its site has that permission. Remembered decisions are set before a page of that site loads. The location comes from macOS (`LocationSource`) through `Emulation.setGeolocationOverride`, so Chromium never asks macOS itself.
  - *HTTP sign-in.* Documents are held at the request stage (`Fetch.enable`, documents only) and go on at once; a challenge (`Fetch.authRequired`) comes to Cosmos's sheet and its answer goes back.
  - *Dangerous sites.* CEF asks before every navigation of every page and frame (`OnBeforeBrowse`), a popup's first page included; Cosmos checks the address against the malware and phishing lists (`CosmosBlocking/DangerousSites`). A listed page is stopped before it is asked for and shows Cosmos's warning, with Go Back and Visit Anyway; a listed frame is left out.
  - *Dialogs.* A page's `alert`, `confirm`, `prompt` and leave-the-page question come to Cosmos's sheet through CEF.
  - *DevTools* are Chromium's own, in a window CEF makes (it will not draw them in a view of Cosmos's).
  - *Picture in Picture* is a floating Cosmos panel showing the page's frames (`Page.startScreencast`, only while it is up) cropped to the video, which the agent keeps measuring; the page's PiP API and events behave as in Chrome.
  - *Notifications* from sites and extensions are posted to macOS as Cosmos's (`Notifier`); clicks, buttons and closing go back to the page or worker. The page's world reports a notification with a window message, which any script can post, so the agent's world passes one on only from its own frame, while the site has permission, and under that frame's own site.
  - *Frames from other sites*, which Chromium runs in processes of their own, are attached as they appear (`Target.setAutoAttach` on each page): they get the agent, Boosts, permissions and sign-in too. Chromium holds a page's workers at their start the same way, so they are attached as well, only to be let go.
  - *Downloads* go through CEF's download handler into the profile's `Cosmos Downloads` folder, and Cosmos moves each where it belongs.
  - *The context menu* is Cosmos's: CEF's is left empty.
- **Extensions** run in Chromium with its own APIs; `ChromiumExtensionHost` and the shim mirror what Chrome would draw for them. See [extensions.md](extensions.md).
- **Blocking** is an extension Cosmos writes from the compiled lists, in the default profile. See [ad-blocking.md](ad-blocking.md).

## The browser (CosmosKit)

- **BrowserStore** (`@MainActor @Observable`) owns one profile's workspace, archive, boosts, routing, settings and history, and implements `TabHost`. Everything the UI can do to the model goes through it (`BrowserStore+Tabs`, `+Navigation`, `+Adopt`, `Commands`, `ImportCoordinator`, `BoostLive`). Edits go through `edit { ws in … }`, which also schedules a debounced save. An incognito window gets its own `BrowserStore` with no directory, so nothing is written.
- **WindowState** is per window: the focused space, the selected item in each space, recent tabs, sidebar width, overlays (Command Bar, Boosts, …), which sidebar page is showing (the Library or a space) and which Library section, Peek and toasts. Windows are independent: two windows can show two spaces.
- **TabRuntime** is one live page: an `EnginePage` and Cosmos's side of it (the agent's reports, the error page, dialogs, permissions, the right-click menu). Sidebar tabs exist without a runtime until selected, which is why thousands of pinned and archived tabs cost nothing. Runtimes are keyed by `(item, profile)`; the memory saver discards idle ones and they reload on demand.
- **ProfileEnvironment** is one per profile: its `EngineProfile`, the page scripts (a small page agent in Cosmos's own script world, Boost scripts and style sheets in the page's world), and the profile's share of blocking and extensions.
- **Overlays and chrome** are SwiftUI (`BrowserRootView` in an `NSHostingView`), with page views hosted through `NSViewRepresentable`. The sidebar, Command Bar, Peek, find bar, panels and theme editor are in `UI/`. The window uses `fullSizeContentView`, so the space's gradient runs behind the traffic lights.
- **Radial menu** (`RadialSession`, `RadialMenuView`, `PageContextMenu`): the engine draws no menu of its own. The page agent reports what is under the pointer on a right click, Cosmos builds the menu from that (and adds extensions' items), then shows it as a ring over the page or as an ordinary menu at the pointer. A page that handles `contextmenu` itself keeps its own menu.
- **Menu-bar browser** (`MenuBarBrowser`, `MenuBarSession`, `MenuBarBrowserView`): an `NSStatusItem` and a non-activating `NSPanel`. The page is a `TabRuntime` made from a profile's `ProfileEnvironment`, so it uses that profile's cookie jar, blocking and Boosts; its host (`MenuBarHost`) loads new-window links in place and sends what belongs in a window there.
- **Welcome** (`Onboarding/`, with its timing and galaxy in `CosmosCore/Onboarding.swift` and `Galaxy.swift`): the first-run overlay. `OnboardingModel` owns the steps, the choices and a clock that every animation reads, so any moment can be drawn off screen; `GalaxyView` paints the galaxy in a `Canvas` with additive sprites baked once off the main thread. The Sky, Bring and last steps show the real sidebar and landing (`WindowPicture`) drawn from a copy of the window's state, and on the way in the last step's picture grows into the real window.
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
