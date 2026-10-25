# Feature catalogue

Arc's source is split into local Swift packages (**observed** from embedded source paths; see [appendix/source-tree.md](appendix/source-tree.md)):

- `Browser/` — the app target: `AppDelegate`, `MainWindowController`, `BrowserWindow`, window-content view controllers, sidebar cells, modals, AppleScript.
- `Frameworks/ARC/Sources/<Feature>` — ~77 feature modules (TCA reducers + views).
- `Frameworks/ARCClients/Sources/<Client>` — ~75 dependency clients (I/O, services, platform APIs).
- `Frameworks/ARCFoundation`, `Frameworks/ARCUI` — shared utilities and UI kit.
- `Frameworks/ADK` — the Swift wrapper over `ArcCore` (Chromium).

Below, each user-facing feature is listed with the modules that implement it and the evidence. Shortcuts come from `MainMenu.nib` ([appendix/menus-and-shortcuts.md](appendix/menus-and-shortcuts.md)).

## Core browsing model

| Feature | What it is | Modules / evidence |
|---|---|---|
| **Sidebar (vertical tabs)** | All tabs live in a left sidebar: *Favorites* at the top, *Pinned* tabs and folders, then *Today* (unpinned) tabs | `SidebarUI`, `SidebarItemUI`, `SidebarDock`, `SidebarHovering`, `SidebarPlusButton`, `SidebarDataStore`, `StorableSidebar`; `Browser/Sidebar/SidebarCells`; menu "Show/Hide Sidebar" ⌘S |
| **Favorites** | Icon grid of pinned apps above the spaces, shared across spaces | Container type `topApps` in `StorableSidebar.json`; `AppTray` |
| **Pinned / unpinned tabs** | Pinned tabs persist and can be reset to their original URL; unpinned tabs auto-archive | `newContainerIDs[].pinned / .unpinned` in the sidebar model; menu "Pin/Unpin Tab" ⌘D, "Reset Tab to Original URL", "Clear Unpinned Tabs" ⇧⌘K |
| **Folders** | Nested folders of tabs in the pinned area | Item data case `list`; "New Folder…" ⇧⌘N; "Expand/Collapse All Folders" |
| **Live Folders** | Folders that auto-fill from a source (e.g. GitHub pull requests) | `LiveFoldersFeature`, `GitHubClient` (`GitHubClient+PullRequestsParsing.swift`), `StorableLiveData.json`; flags `enable-git-hub-live-folders` |
| **Spaces** | Separate sidebars per context, each with its own theme, icon and profile; swipe between them | `SpaceCreation`, `SpaceStyleEditor`, `WindowThemeUI`, `WindowBackground`, `CustomInfoPicker`; "Next/Previous Space" ⌥⌘→/←, "Manage Spaces…", "Edit Theme…" |
| **Space themes** | Gradient themes picked on a colour wheel with noise/grain, vibrancy, light/dark/auto | `windowTheme` structure (`blendedGradient`, `baseColors`, `overlayColors`, `noiseFactor`, `wheel.analogous`, `primaryColorPalette`, `semanticColorPalette`); Metal shader `default.metallib`; Lottie `sun/moon/automatic.json` |
| **Profiles** | Chromium profiles (cookies, history, extensions) bound to spaces | `ProfilesUI`; `ArcBrowserContext`; `StorableProfiles.json`, `StorableProfileContainers.json`; "Change Profile", "New Profile" |
| **Split View** | Up to several tabs side by side in one pane, horizontal or vertical | Item data case `splitView {focusItemID, itemWidthFactors, layoutOrientation}`; "Add Split View" ⌃⇧=, "Close this Split Pane" ⌃⇧-, "Separate Page from Split View"; flag `drag-to-combine-tabs-into-split-enabled` |
| **Archive / auto-archive** | Closed and stale unpinned tabs go to a searchable archive instead of disappearing | `Archive`, `SharedArchiveFeature`, `StorableArchive`, `ArchiveDataStoreClient`; `StorableArchiveItems.json`; "Archive Tab" ⌘W, "View Archive" |
| **Little Arc** | A small floating window for links opened from other apps, promotable into a space | `LittleBrowser`; `Browser/Windows/LittleWindowViewController.swift`; "New Little Arc Window" ⌥⌘N |
| **Peek** | Links from pinned tabs open in a modal overlay instead of a new tab | `WindowContent/Modals`, `ModalContent`, `ModalItemSwitcher`; flags `modal-v2-*` |
| **Link routing** | Rules sending URLs to a chosen space/profile | `LinkRouting`; `StorableLinkRouting.json` (`rules[].urlMatch`, `destination`, `defaultDestination`) |
| **Tab switcher** | ⌃⇥ MRU switching between recent tabs | "Tab Switcher (forward/backward)"; `recentlySwitchedToTabs` in `StorableCommandBarAdditionalRanking.json`; flag `linear-tab-switcher-enabled` |

## Command Bar and search

| Feature | What it is | Modules / evidence |
|---|---|---|
| **Command Bar** | ⌘T (new tab) / ⌘L (current tab) palette for URLs, search, open tabs, history, commands | `CommandBar`, `SearchClientManager` with candidate providers `SidebarCandidatesProvider`, `TopDomainsCandidatesProvider`, `TypeTravelCandidatesProvider`, `DocumentsCandidateProvider`, `EaselCandidatesProvider`; Chromium autocomplete via `ArcBrowserContextAutocomplete` |
| **Type Travel** | Command-bar actions and menu commands reachable by typing | `TypeTravel` (`CandidateFetcher.swift`, `MainMenuClient.swift`); usage counts in `typeTravelUsage` |
| **Learned ranking** | Remembers which result you pick per query and re-ranks; on-device ML ranking model | `CommandBarAdditionalRankingDataStoreClient`, `StorableCommandBarAdditionalRanking.json` (`queriesToSelectedArchetype`); `AIService_RankCommandBar` (see [ai-and-ml.md](ai-and-ml.md)) |
| **Site search** | Type a site's name then Tab to search inside it | Help article "Site Search"; `ArcSearchEngine` |
| **Instant links / calculator** | Answers and direct links inside the bar | flags `instant-links-v2-enabled`, `instant-links-suggestion-enabled`, `command-bar-calculator-enabled` |
| **Top domains** | Built-in suggestions for popular sites | `TopDomains` bundle (`TopDomains.json`, `TLD-short-list.json`), `popularDomains.json`, `DomainParser` (Public Suffix List) |
| **Dedupe rules** | Treat tabs on some hosts as duplicates by title+host | `command_bar_behavior.json` → `dedupByTitleAndHostList` (Figma, Google Maps, Notion, Zoom, GitHub …) |

## Creation tools

| Feature | What it is | Modules / evidence |
|---|---|---|
| **Easels** | Freeform canvas mixing live web captures, images, text and drawings; shareable and collaborative | `Easel`, `EaselUI` (canvas, snap guides, annotations), `EaselClient` (`EaselFirebaseDataProvider`, `EaselFirebasePresencePinger`), `EaselLibraryClient`; Firestore `easels`, `objects`, `presence`; "New Easel" ⌃⇧E |
| **Notes** | Rich-text notes in the sidebar, exportable | `DocumentsFeature` (`ArcDocumentEditorViewController`), `ArcRichTextEditor`, `TextEditor`, `DocumentsClient`, `DocumentsLibraryClient`; "New Note" ⌃⇧N; "Export Arc Notes" |
| **Capture** | Screenshot an area, full page or "portrait mode" | `Capture`, `CaptureClient`; `StorableCaptures.json`; "Capture…" ⇧⌘2, "Capture Full Page" |
| **Library / Media** | Browse downloads, captures, easels, notes, boosts | `LibraryData`, `SharedDownloadsFeature`; "View Library" ⇧⌘L, "View Media", "View Downloads" ⇧⌘J |
| **Boosts** | Per-site custom CSS/JS, colour tweaks, font swaps, "Zap" to hide elements; shareable; gallery | `BoostsClient`, `BoostsEditor` (`SelectorPicker.js` element picker), `BoostsDialog`; Chromium `ArcBrowserContextEffects`, `ArcWebContentsBoostIDE`; `StorableBoostsData.json`; flags `boosts-v2-enabled`, `boosts-v2-monaco-enabled`, `boost-sharing-enabled`. Detail in [web-behaviors-and-boosts.md](web-behaviors-and-boosts.md) |
| **Share** | Share tabs, folders, spaces, easels with links | `ShareMenu`, `SharableObjectsFeature`, `SharableArcObjectsClient`; Firestore `objects` |

## Web page helpers

| Feature | What it is | Modules / evidence |
|---|---|---|
| **Picture-in-Picture** | Auto PiP for video when you leave a tab; Document PiP; meeting PiP with mic/camera controls | `PictureInPicture` (`PIPWindowController`, `DocumentPiPWindowController`, `MeetingControls.ViewModel`); `ArcWebContentsMediaSessionPiPController`; per-site rules in `web_content_behavior.json`; flag `google-meet-auto-picture-in-picture-enabled` |
| **Media controls** | Now-playing controls in the sidebar | `MediaControlsFeature`, `MediaControlsDataStore` |
| **Hover previews** | Hover a pinned tab to preview it; Gmail/Calendar previews | `HoverCards`, `Previews` (`CalendarEventData`, `RecentEmail`), `LiveCalendars`, `LiveCalendarClient`; "Peek Email…" ⇧⌘E; "Join Meeting" ⌃⌘J |
| **Live Slack / Notion** | Unread/activity info for Slack and Notion tabs | `LiveSlackClient` (`SlackLocalConfigClient.swift`, activity-feed payloads), `LiveNotionClient` |
| **Tidy titles** | Cleaner tab titles for 52 sites (e.g. Gmail folder names) | `web_content_behavior.json` → `tidyTitles` |
| **Tab suspension / memory** | Freeze background tabs except an allow-list | `web_content_behavior.json` → `keepaliveAllowList`, `tabSuspensionBlocklist`; `WebContentLifecycleOptimization`; `memory_behavior.json` (remote) |
| **Ad & tracker blocking** | Built-in content blocker with EasyList, AdGuard, uBlock, cookie lists and regional lists | `AdBlocking`, `BlockListClient`; `ADK_ADK.bundle/selectors.css` cosmetic filters; `ArcBrowserApplication setBlockLists:` |
| **Site Control Center** | Per-site permissions, cookies, settings popover | `SiteControlCenter`; `ArcSiteSettingInfo`, `ArcPermissionRequest` |
| **Translation** | Page translation | `Translation`; Chromium translate |
| **Find** | Find in page with find & replace | "Find…" ⌘F, `arc_performFindPanelAction:`; `ArcFindResult` |
| **Copy URL helpers** | Copy URL, as Markdown, as quote | "Copy URL" ⇧⌘C, "Copy URL as Markdown" ⌥⇧⌘C, "Copy URL as Quote" ⌃⇧⌘C |
| **Developer mode** | Dev toolbar, DevTools, network inspector, JS console | "Toggle Developer Mode" ⌃D; `StorableDeveloperModeState.json`; `ArcWebContentsDevTools` |
| **Extensions** | Chrome Web Store extensions, pinned extension actions | `ArcBrowserContextExtensions`, `ArcExtensionToolbarAction`; `AppTray.PinnedExtensionCollectionViewItem`; "Add Extension…" |

## AI (Arc Max)

Ask Arc, Ask-in-page, Browse for Me, ChatGPT-in-command-bar, tidy tab titles/downloads, 5-second previews and others — see [ai-and-ml.md](ai-and-ml.md). Modules: `AskArc`, `AskArcComparisonTool`, `AskInPage`, `LLM`, `WebSearch`, `PromptGeneration`, `Scraping`.

## Account, onboarding, settings

| Feature | Modules / evidence |
|---|---|
| Sign-in / account | `AuthFeature` (Firebase Auth incl. MFA endpoints), `DeleteAccountFeature`, `KeychainClient`, `StorableAuthState.json` |
| Member card & referrals | `MembershipCard`, `ReferralCodeFeature`, `ReferralCodeClient`; `arc.net/gift/` |
| Import from other browsers | `ImportFeature`, `ImportMenuFeature`; `ArcImportSource`, `ArcBookmarkImportTargets` |
| Onboarding | `WelcomeToArcFeature` (videos for pinning, new tab, space swiping, split view), `KeyboardShortcutsEducationFeature` |
| Preferences | `PreferencesFeature`, `SyncedPreferencesClient`, `UserDefaultsClient` |
| Default browser prompts | `DefaultBrowserPrompts`, `DefaultBrowserClient`, `StorableDefaultBrowserPrompts.json` |
| Custom app icons | `AppIconClient` + Dock tile plugin (see [native-components.md](native-components.md)) |
| Updates | `SoftwareUpdaterClient` (Sparkle), `SidebarBanner` (update banners, `update-heart-animation.json`) |
| Restore data | "Restore Data" flow (`Browser/DataStore/RestoreSidebarDataFlow.swift`), timestamped `Storable*.json` backups |
| Send to Dia | "Send to Dia" (`sendCurrentTabToDia:`) — hands the current tab to The Browser Company's newer browser |

## Diagnostics and internal tools

`ActionInspectorDashboard`, `TabCloseDebugger`, `TracingFeature` ("Record Trace"), `DynamicLogLevels`, `MeterMetrics`/`MeterClient`, `ProcessMemoryUsage`, `TabSwitchingPerfTracker`, `NewWindowPerfClient`, `WebpageLoadingPerfClient`, `BugReporterClient`, `MainThreadChecker`, "Copy Arc Info", "Reveal Arc Data", "Open Task Manager".

## Feature flags

139 flag keys ending in `-enabled`/`-disabled` are listed in [appendix/feature-flags.txt](appendix/feature-flags.txt) (LaunchDarkly; local overrides in `StorableFeatureFlags.json`). They show the shared codebase with Arc for Windows (`win-*`) and Arc Search for iOS (`mobile-*`), and late-life work such as `i-cloud-sync-deprecation-ui-enabled`, `mac-os12-deprecation-ui-enabled`, `arc-signups-disabled` and `arc-force-sign-out-enabled`.
