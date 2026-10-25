# Rebuilding Arc as Cosmos

What the teardown implies for building a successor, in priority order. Recommendations are ours, not Arc's.

## 0. Save your Arc data first

Before Arc stops working, export the sidebar with the included script (no Arc code involved; it reads `StorableSidebar.json` read-only):

```bash
python3 tools/arc_export.py -o ~/Desktop/arc-export.json
```

It writes favorites and every space's pinned/unpinned tree (tabs, folders, splits) with titles, URLs and dates as plain JSON. Also keep a copy of `~/Library/Application Support/Arc/` (the `Storable*.json` files) and Arc's Chromium profile, which holds history, passwords and cookies.

## 1. Pick the engine

Arc's core design is "native shell + headless Chromium". The options:

| Option | Fit | Cost |
|---|---|---|
| **WKWebView (WebKit)** | Native, small, battery-friendly; `WKUserScript` and `WKContentRuleList` cover Boosts and ad blocking; built-in Safari-style passkeys | No Chrome extensions; some sites prefer Chromium |
| **CEF (Chromium Embedded Framework)** | Closest to Arc: Chromium rendering with your own UI; Chrome extensions partially supported | Large binary, complex build, slower to update |
| **Fork Chromium like Arc did** | Full control (Arc's `ArcCore` is this, plus a 146-class Objective-C bridge) | A dedicated team; Arc rebased onto Chromium continuously |

**Recommendation:** start on **WKWebView** behind a small `WebEngine` protocol modelled on Arc's `ADK` (`Browser`, `BrowserContext`, `WebContent`, `Navigation`, `JavaScriptExecuting`). That keeps the option of a CEF back end later, exactly the seam Arc drew.

## 2. Data model (copy Arc's, it's good)

Model the sidebar as Arc does (see [data-and-sync.md](data-and-sync.md)):

- One flat table of **items** `{id, parentID, childrenIds, title, createdAt, data}` with `data` a tagged union: `tab {url, title, lastActiveAt}`, `folder`, `split {focusID, widths, orientation}`, `container(spaceID | favorites)`.
- **Spaces** `{id, title, icon, theme, profileID, pinnedRootID, unpinnedRootID}`.
- **Favorites** are the children of one global container.
- Store as JSON with rotating timestamped backups — simple, diffable, and it made Arc's *Restore Data* possible.

The exporter's output maps straight onto this model, so an *Import from Arc* feature is just a reader for `arc-export.json`.

## 3. MVP features (what made Arc "Arc")

In order of how much users miss them:

1. **Vertical sidebar** with Favorites, Pinned and Today sections; drag to reorder, nest into folders.
2. **Spaces** with per-space theme and icon, and swiping between them (⌥⌘←/→).
3. **Command Bar** (⌘T new tab, ⌘L current tab) searching open tabs, sidebar items, history and top domains. Start with frecency (`lastNavSeconds`, `typedCount`, visit count, exact/base-domain/title-prefix matches — the same features Arc's ranker uses); add learned re-ranking later.
4. **Auto-archive** of unpinned tabs after a configurable idle time, with a searchable archive.
5. **Split View** (⌃⇧=), up to 4 panes, horizontal or vertical.
6. **Little Arc** — links from other apps open in a small window that can be promoted into a space.
7. **Peek** — links from pinned tabs open in an overlay.
8. **Profiles per space.**
9. **Keyboard shortcuts** matching Arc's ([appendix/menus-and-shortcuts.md](appendix/menus-and-shortcuts.md)) so muscle memory carries over.

## 4. Second wave

- **Boosts**: per-host CSS/JS/colour/zoom, applied through `WKUserScript` / `WKUserStyleSheet`-style injection keyed by host pattern — the same shape as Arc's `registerStylesheet:withIdentifier:forHostPattern:`. Add an element "zap" picker that builds a selector from tag, id, classes and `:nth-child`.
- **Ad blocking**: compile EasyList/EasyPrivacy/AdGuard into `WKContentRuleList`s, or use `adblock-rust`.
- **Tidy titles and keep-alive rules**: a remotely updatable JSON like Arc's `web_content_behavior.json` (host → title rules, never-suspend list, PiP tweaks).
- **Auto Picture-in-Picture** when leaving a tab with playing video.
- **Hover previews** of pinned tabs; mail/calendar peeks.
- **Notes and Easels**, if you want the creative side.

## 5. AI (optional)

Arc's design is a good template: an on-device service for embeddings and small models (MLX or Core ML on Apple silicon), page-to-Markdown conversion before anything is sent to an LLM, and a proxy you control for cloud models. Arc's ranking-model design — train locally on which result the user picked and only share weight deltas — is a privacy-friendly way to improve the Command Bar.

## 6. Sync

Arc moved from CloudKit to Firebase with client-side encryption and recovery cards. For a single-developer project, **CloudKit with end-to-end-encrypted fields** (or just iCloud Drive JSON) is far less work and costs nothing to run.

## 7. Platform plumbing

- Register as a browser: `CFBundleURLTypes` for `http`/`https`, document types for HTML/PDF, `NSUserActivityTypeBrowsingWeb`, and the `com.apple.developer.web-browser.public-key-credential` entitlement for passkeys.
- Sparkle 2 with an EdDSA-signed appcast for updates.
- An AppleScript dictionary like Arc's (window/tab/space, `execute javascript` behind an opt-in) keeps users' Raycast/Alfred scripts working.
