# Cosmos

A space-themed web browser for macOS, made for people leaving Arc. It keeps the parts of Arc that were hard to give up (a vertical sidebar of **spaces**, Favorites, pinned tabs and a Today list that tidies itself, the **Command Bar**, **Peek**, split view, **Boosts**) and gives each space its own gradient sky. It runs on WebKit, so it is small and light on battery. It imports your Arc sidebar, history, bookmarks and extensions.

Arc stops working on 22 December 2026. [`arc-teardown/`](arc-teardown/) is the study of how Arc works that Cosmos was built from.

> **Status.** Cosmos 1.0 is a complete, working browser that has been built and checked end to end on one Mac (macOS 27). It is not notarized, has had no users but its author, and has gaps listed under [What is not here](#what-is-not-here). Read that before you trust it with your only browser.

## What you get

- **Spaces with themes.** Each space has a name, icon and its own gradient, grain and optional starfield, and can use its own profile (separate cookies and logins). Switch with ⌃1–9 or ⌥⌘←/→.
- **Favorites, Pinned and Today.** Favorites sit at the top of every space. Pinned tabs and folders stay put; Today tabs are archived after a while (you choose how long) and are searchable in the Archive.
- **Command Bar** (⌘T, ⌘L). One box for open tabs, archived tabs, history, top sites, commands, spaces and web search. Type a site name and press Tab to search inside that site. It does arithmetic. It learns which result you pick for a query.
- **Peek** (⇧-click a link) and **Probe** (⌥⌘N, Arc's Little Arc): a quick look at a page without opening a tab, in a floating window that can become a tab.
- **Split view** (⌃⇧=): up to four pages side by side.
- **Boosts.** Per-site colour filters, fonts, zoom, hidden elements (click to zap), your own CSS and JavaScript.
- **Ad, tracker and cookie-banner blocking** with EasyList, EasyPrivacy and the Fanboy cookie list (downloaded, not bundled), compiled to WebKit content rules. One switch per site in Site Controls.
- **Extensions** from Arc, Chrome, Brave, Edge and others, or by Chrome Web Store link, run with WebKit's extension engine (macOS 15.4+). See [docs/extensions.md](docs/extensions.md).
- **Radial menu.** Right-click a link, an image, some text or a text field and a ring of that thing's actions opens around the pointer: flick toward a slice, or click one. It is built from the same actions WebKit's own right-click menu has, so nothing is lost (the rest wait under More). Choose what is on each ring and the order in Settings, switch it off for sites where you want the system menu (also from Site Controls), and hold ⌥ for the system menu at any time. A page that draws its own right-click menu keeps it.
- **Menu-bar browser.** Turn it on in Settings ▸ Menu Bar and a Cosmos icon appears in the menu bar. Click it for a small browser under the icon, phone-sized or desktop-sized, for a quick look at something without finding a window. It uses the same cookies and logins as the profile you pick (so you are signed in wherever the browser is), the same blocking and Boosts, and its pages go into your history. Click away to put it down, or pin it to keep it over other windows. It opens on the page you left, or on a start page you choose.
- **Link routing.** Links from other apps open in a Probe window, your current space, or a space chosen by site.
- **Everything else you expect.** Downloads, history, find in page, Picture in Picture (also automatic when you leave a playing video), page zoom, incognito windows, a "Set as default browser" button, site permissions for camera and microphone that are remembered per site, and a memory saver that puts idle tabs to sleep.

## Install

Cosmos needs macOS 14 or later (extensions need 15.4) and the Swift command line tools (`xcode-select --install`). Full Xcode is not needed.

```bash
git clone <this repository> && cd Cosmos
scripts/build-app.sh --install     # builds a release app and copies it to ~/Applications
```

`scripts/build-app.sh` alone leaves `build/Cosmos.app` in the repository. The app is signed ad hoc and is not notarized, so the first time you open it, **right-click it and choose Open**, then confirm.

On first launch Cosmos asks whether to import from Arc. You can also do it later from **Cosmos ▸ Import from Arc or Another Browser…**. Arc can stay open; Cosmos only reads its files. See [docs/importing-from-arc.md](docs/importing-from-arc.md) and [docs/importing-from-other-browsers.md](docs/importing-from-other-browsers.md).

## Arc to Cosmos in one minute

| In Arc | In Cosmos | Keys |
|---|---|---|
| Command Bar | Command Bar | ⌘T new tab, ⌘L current tab |
| Little Arc | Probe | ⌥⌘N |
| Peek | Peek | ⇧-click a link |
| Spaces | Spaces | ⌃1–9, ⌥⌘←/→ |
| Pin a tab | Pin | ⌘D |
| Favorite a tab | Favorite | ⌥⌘D |
| Archive tabs | Archive All Today Tabs | ⇧⌘K |
| Split view | Split view | ⌃⇧= add, ⌃⇧- close pane |
| Boosts | Boosts | ⌥⌘B |
| Site Control Center | Site Controls | click the lock in the address pill |
| Easels, Notes, Live Folders, Arc Max AI, Sync | not in Cosmos | |

The longer list, with every shortcut, is in [docs/arc-to-cosmos.md](docs/arc-to-cosmos.md). **⌘/** shows the shortcuts inside the app.

## What is not here

Cosmos is a browser, not a clone of everything Arc shipped.

- **No sync between devices and no account.** Your tabs and settings are a few files on your Mac (listed below); the cookies and site data that WebKit keeps for each profile are in WebKit's own folders.
- **None of Arc's AI features** (Ask on page, summaries, Tidy Tabs by AI, AI renaming), and no Easels, Notes, Live Folders or calendar and mail previews.
- **Arc's Boosts cannot be imported.** In the Arc profile used to build this, Boost definitions are not stored on disk (only an image cache), so Cosmos cannot read them. Recreate a Boost in about a minute from Site Controls.
- **WebKit, not Chromium.** Sites behave as in Safari. Chromium-only web features are missing. Extensions that rely on Chrome-only APIs (history, bookmarks, downloads, notifications, sign-in through Chrome) will load but those parts will not work. The Add prompt warns when it sees this.
- **Ad blocking is Safari-style.** WebKit content rules cannot do everything uBlock Origin does (no scriptlets, no `:has-text`, regex filters with alternation, and so on). About 99.9% of EasyList's network filters compile. [docs/ad-blocking.md](docs/ad-blocking.md) has the numbers and the gaps. For more, add uBlock Origin Lite as an extension.
- **Not verified:** anything that needs a person at the trackpad. The sidebar drag gesture, the haptic taps, the two-finger space swipe, Force Touch Peek and how the animations feel are built and unit tested (state machines, payloads, the model operations) but were never exercised on screen, because nothing here records the screen. Also not checked by eye: the exact alignment of the window buttons, JavaScript dialogs, OAuth sign-in popups, and anything on macOS 14 or 15 (all testing was on macOS 27).
- **Not notarized**, so macOS asks you to confirm the first launch. Updates are manual: pull and run the build script again.

## Where your data lives

`~/Library/Application Support/Cosmos/` (override with `--data-dir` or `COSMOS_DATA_DIR`):

| File or folder | What it holds |
|---|---|
| `workspace.json` | spaces, themes, Favorites, pinned and Today tabs, folders, split views, profiles |
| `archive.json` | archived tabs |
| `boosts.json`, `link-routing.json`, `settings.json` | Boosts, link routing rules, settings |
| `history.sqlite` | history with visit counts (used for frecency in the Command Bar) |
| `command-bar-learning.json` | which result you picked for which query |
| `session.json` | windows to reopen |
| `extensions.json`, `Extensions/` | the extensions you added and their files |
| `FilterLists/`, `blocking.json` | downloaded filter lists and their compiled form |
| `Favicons/` | the logos of sites in your sidebar; ones not renewed for 90 days are deleted |
| `Backups/` | dated copies of the JSON files, kept automatically |

That folder holds Cosmos's own files. Cookies, local storage and the page cache are kept by WebKit, one store per profile, under `~/Library/WebKit/` and `~/Library/Caches/` (in a folder named after the app's bundle id), and downloads go to `~/Downloads`. Incognito windows keep their cookies and site data in memory only.

Nothing leaves your Mac except what you browse, the filter lists Cosmos downloads, the logos of sites that have a tab in your sidebar (fetched from the site itself, asking only for its home page and icon, never the page you were on), search suggestions (switch off in Settings) and Chrome Web Store downloads you ask for. There is no telemetry.

## For developers

[docs/architecture.md](docs/architecture.md) explains the modules and how a tab, a space and a window fit together. [docs/development.md](docs/development.md) covers building, the tests (`scripts/test.sh`), the self-snapshot automation harness (how the UI was checked without screen recording) and the quirks of building with only the Command Line Tools.

```
Sources/CosmosCore       model, storage, search ranking (no UI, no WebKit)
Sources/CosmosImport     Arc, Chromium, Firefox and Safari importers; extension discovery
Sources/CosmosBlocking   filter list parser and WebKit rule compiler
Sources/CosmosKit        the browser: AppKit, SwiftUI, WKWebView
Sources/Cosmos           the app (a few lines)
Sources/CosmosCLI        cosmos-cli: import and inspect from the terminal
```

## Credits and licenses

Cosmos is MIT licensed ([LICENSE](LICENSE)). It uses only Apple frameworks; there are no third-party code dependencies.

- The registrable-domain logic uses the **Public Suffix List** (<https://publicsuffix.org>, MPL 2.0), bundled with its comments removed in `Sources/CosmosCore/Resources/public_suffix_rules.txt`.
- **Filter lists are not included.** Cosmos downloads EasyList and EasyPrivacy (GPLv3+ / CC BY-SA 3.0, easylist.to), the Fanboy cookie list (CC BY 3.0) and, if you turn them on, uBlock Origin's lists (GPLv3) from their publishers. Settings ▸ Blocking shows each list's license.
- Icons are Apple's SF Symbols. The app icon is drawn in code.
- Arc is a product of The Browser Company. Cosmos contains no Arc code, binaries, assets or strings; [arc-teardown/](arc-teardown/) describes Arc's behaviour from the outside.
