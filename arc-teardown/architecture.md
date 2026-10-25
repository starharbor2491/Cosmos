# Architecture

## Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│ Arc.app/Contents/MacOS/Arc  (Swift, AppKit + SwiftUI, ~80 MB arm64)  │
│   NSPrincipalClass = Arc.BrowserApp, delegate = Arc.AppDelegate      │
│   ~190 Swift modules, The Composable Architecture (TCA)              │
│   Feature modules: CommandBar, Sidebar*, Boosts*, Easel*, AskArc,    │
│   LittleBrowser, PictureInPicture, AppTray, Spaces, Profiles …       │
├──────────────────────────────────────────────────────────────────────┤
│ ADK / ADKClient / ADKModels  (Swift)                                 │
│   ChromiumBrowser, WebContentChromium, BrowserContextDevToolsChromium│
│   *DelegateBridge classes adapt Objective-C delegates to Swift       │
├──────────────────────────────────────────────────────────────────────┤
│ ArcCore.framework  (Chromium 156.0.8078.48, ~240 MB arm64)           │
│   Objective-C bridge: 146 Arc* classes, 1,821 selectors              │
│   C exports: ChromeMain, ChromeAppModeStart_v8, SetLogMessageHandler │
│   Arc services: arc/services/ai, arc/services/content_conversion     │
├──────────────────────────────────────────────────────────────────────┤
│ Helpers/  Browser Helper (+GPU, Renderer, Alerts)                    │
│           Browser Helper (Aperitif …) ×4 → libaperitif.dylib         │
└──────────────────────────────────────────────────────────────────────┘
```

**Observed.** Every visible piece of Arc's UI is native. Chromium's own browser UI (tab strip, omnibox, toolbar) is not used: the Swift side creates "browsers" and "web contents" through the bridge and hosts their views inside its own windows (`ADK.TablessWebContentsUIDelegate` hints at this — a Chromium browser with no tabs, driven externally).

### The bridge (ArcCore ↔ Swift)

`ArcCore` exports almost nothing except Objective-C classes prefixed `Arc`. The main ones (full list in [appendix/arccore-objc-api.md](appendix/arccore-objc-api.md)):

| Class | Role |
|---|---|
| `ArcBrowserApplication` | The Chromium process singleton: `initialize:`, `run`, `quit`, feature flags (`setFeatureEnabled:enabled:`, `setIntFeatureValue:value:`), `createBrowser:withDelegate:forWindow:`, `createBrowserContext:isHidden:type:completion:error:`, importers, block lists, AI service creation, histograms, task manager |
| `ArcBrowserContext` + `ArcBrowserContext{Autocomplete,DevTools,Downloads,Effects,Extensions,History,PageContentExtraction,Preferences}` | A Chromium profile and its sub-services. Arc's *Profiles* map 1:1 to browser contexts |
| `ArcBrowser`, `ArcBrowserSidePanel` | A Chromium `Browser` object (needed for extensions, side panel, popups) without Chromium's UI |
| `ArcWebContents` (≈1,490 selectors) and `ArcWebContents{Configuration,NavigationController,DevTools,MediaSession,MediaSessionPiPController,PDFController,ThumbnailsGenerator,BoostIDE,AIAgent}` | One tab's page: navigation, find, zoom, audio, PiP, PDF, thumbnails, JavaScript execution, accessibility tree, page content extraction |
| `ArcAIService`, `ArcContentConversionService` | Arc's own Chromium-side services (see [ai-and-ml.md](ai-and-ml.md)) |
| `ArcSession{Window,Tab,TabGroup,Navigation}` | Chromium session restore data, used by Arc's *Restore Data* flow |
| `ArcAutocompleteMatch/Result`, `ArcHistoryItem`, `ArcMostVisitedURL`, `ArcSiteEngagementDetails` | Data feeding Arc's Command Bar |
| `ArcExtensionInfo`, `ArcExtensionToolbarAction`, `ArcExtensionCommand` | Chrome extension support |
| `ArcLoginCredentials*`, `ArcCreditCardInfoSaveRequest`, `ArcAddressEntrySaveRequest` | Autofill / password-save prompts surfaced to native UI |
| `ArcSpake2Context` | SPAKE2 key exchange (used for device pairing / QR sign-in style flows; **inferred**) |

On the Swift side, the `ADK` module wraps these: `ADK.ChromiumBrowser`, `ADK.WebContentChromium`, `ADK.ChromiumDownload`, `ADK.TracingControllerChromium`, and a family of `…DelegateBridge` classes (`BrowserContextDelegateBridge`, `BrowserContextHistoryDelegateBridge`, `HistogramSamplesDelegateBridge`, `PerformanceObserverBridge`, `CrashKeysObserverBridge` …). Swift protocols such as `ADK.Browser`, `ADK.BrowserContext`, `ADK.WebContent`, `ADK.Navigation` and `ADK.JavaScriptExecuting` let the rest of the app run against stubs (`ADK.StubWebContent`) in tests and previews.

## Swift application

**Observed** from Swift runtime names (`_TtC…`, mangled protocol references) in the main executable:

- **UI**: AppKit for windows, sidebar collection views and the command bar text field; SwiftUI for most panels (`SwiftUIIntrospect` bridges the two). Animation via `Lottie` and Arc's own `Motion` module; Metal shaders for window gradients (`WindowThemeUI` ships a `default.metallib` with `gradientFragment`, `GradientLayer`, `OverlayRenderConfiguration`).
- **Architecture**: Point-Free's **The Composable Architecture** (`ComposableArchitecture`, `Dependencies`, `CasePaths`, `CustomDump`, `IdentifiedCollections`, `XCTestDynamicOverlay`), with features split into small modules named `…Feature`, `…Client`, `…UI`.
- **Clients**: dependency-injected service modules — `FeatureFlagsClient`, `AnalyticsClient`, `TelemetryClient`, `BoostsClient`, `EaselClient`, `KeyBindings`, `LiveSlackClient`, `RemoteConfigClient`, `WorkspaceClient`, `TopBarColorClient`, `SoftwareUpdaterClient`, `AppRestartClient`, `BlockListClient`, `FontsManager`, `SearchClientManager`, `FirebaseSidebarSyncClient`, `HistogramTrackingClient` …
- **Persistence**: Arc's own `Storable` / `StorableSidebar` modules writing JSON (see [data-and-sync.md](data-and-sync.md)); `ARCFoundationBase.PersistentCache`, `FileCacheStorage`, `LayeredCacheCoder`.

### Third-party libraries (observed)

| Area | Libraries |
|---|---|
| App architecture | ComposableArchitecture, swift-dependencies, CasePaths, CustomDump, IdentifiedCollections, swift-collections, swift-async-algorithms, CombineExt, swift-atomics, swift-numerics (`RealModule`), swift-system, NonEmpty, swift-parsing, Perception/SwiftNavigation |
| Sync & backend | Firebase (Auth, Core, Firestore, Functions, Storage), gRPC/BoringSSL (`openssl_grpc`), abseil, leveldb, nanopb, GTMSessionFetcher, Promises (FBLPromises), GoogleUtilities |
| Feature flags & analytics | LaunchDarkly (+ LDSwiftEventSource), Segment (+ Sovran), Datadog (Core, Logs, Trace, RUM internals), OpenTelemetry API, Sentry |
| Web/content | SwiftSoup and Fuzi (HTML/XML parsing), Mustache (templates), DomainParser (Public Suffix List), SDWebImage (+SwiftUI), YouTubePlayerKit |
| Crypto & files | libsodium (`Sodium`), swift-crypto, ZIPFoundation |
| Updates | Sparkle 2 (EdDSA-signed appcast) |

## Bundle layout

| Path | Contents |
|---|---|
| `Contents/MacOS/Arc` | Universal Swift executable (158 MB; arm64 slice 80 MB) |
| `Contents/Frameworks/ArcCore.framework` | Chromium + bridge (591 MB on disk incl. resources) |
| `ArcCore…/Helpers/` | `Browser Helper`, `(GPU)`, `(Renderer)`, `(Alerts)`, and `(Aperitif)`, `(Aperitif GPU)`, `(Aperitif Renderer)`, `(Aperitif Alerts)`; `app_mode_loader` (Chromium "app mode" shortcut loader) |
| `ArcCore…/Libraries/` | `libaperitif.dylib`, SwiftShader (`libvk_swiftshader.dylib`, `libvulkan.dylib`) for software GPU fallback, `MEIPreload`, `PrivacySandboxAttestationsPreloaded`, `IwaKeyDistribution` (stock Chromium component data) |
| `ArcCore…/Resources/` | `resources.pak` (5,414 resources), `chrome_100/200_percent.pak`, `icudtl.dat`, V8 snapshots, `DevTools/protocol.json`, 55 locales × gendered variants, `arc/services/*/public/mojom/*.h` (C API headers for Arc's services) |
| `Contents/Frameworks/` | Sparkle, Lottie, Sentry, FirebaseFirestoreInternal, grpc, grpcpp, absl, openssl_grpc, libswiftCompatibilitySpan |
| `Contents/PlugIns/DockTilePlugIn.plugin` | Shows the custom app icon in the Dock while Arc is not running |
| `Contents/Resources/*.bundle` | 83 Swift Package resource bundles; 48 are `ARC_*` feature modules |
| `Contents/Resources/Arc.sdef` | AppleScript dictionary |
| `Contents/Resources/Base.lproj/MainMenu.nib` | Main menu (decoded in [appendix/menus-and-shortcuts.md](appendix/menus-and-shortcuts.md)) |

## Platform integration (observed in Info.plist and entitlements)

- **Signing**: Developer ID Application: The Browser Company of New York Inc. (team `S6N382Y83G`), hardened runtime, notarised Developer ID chain.
- **Minimum OS**: macOS 13.0. `LSEnvironment` sets `MallocNanoZone=0` (required by Chromium's PartitionAlloc).
- **URL schemes**: `http`, `https`, `mailto`, and the private `arcBrowser` scheme. Document types: PDF, HTML, XHTML. Handoff via `NSUserActivityTypeBrowsingWeb`.
- **Entitlements**: CloudKit container `iCloud.net.arc.sidebar`; push notifications (`aps-environment` production); associated domain `webcredentials:arc.net`; `com.apple.developer.web-browser.public-key-credential` (lets Arc act as a browser for passkeys); keychain groups `…browser.webauthn` and `…browser.auth`; camera, microphone and location device entitlements.
- **App Transport Security**: `NSAllowsArbitraryLoads = true` (the web engine needs arbitrary HTTP).
- **Updates**: Sparkle, feed `https://releases.arc.net/updates.xml`, automatic checks every 8 hours (`SUScheduledCheckInterval` 28800), automatic install on.
- **Scripting**: `NSAppleScriptEnabled`, dictionary `Arc.sdef` (see [native-components.md](native-components.md)).
