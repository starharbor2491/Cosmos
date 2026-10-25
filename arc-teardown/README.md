# Arc browser teardown

A static reverse-engineering study of **Arc for macOS 1.170.0** (build 89123), made to preserve how Arc works before it is discontinued on 22 December 2026, and to guide Cosmos as a successor.

Everything here was derived from the shipped app bundle on disk (and, for file formats only, the *structure* of one real Arc profile). Nothing was executed, patched, or sent anywhere.

## What's in here

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | How the app is put together: Swift/AppKit shell, the `ADK` layer, `ArcCore` (Chromium 156), helper processes, bundles, tech stack |
| [features.md](features.md) | Catalogue of every feature module and what it does |
| [data-and-sync.md](data-and-sync.md) | On-disk `Storable*.json` formats, the sidebar/space/tab model, CloudKit and Firebase sync, encryption |
| [web-behaviors-and-boosts.md](web-behaviors-and-boosts.md) | How Boosts, tidy titles, Picture-in-Picture rules, tab suspension, ad blocking and the internal extension work |
| [ai-and-ml.md](ai-and-ml.md) | Arc Max / Ask Arc, the on-device AI service (embeddings, local LLMs, command-bar ranking with on-device training), HTML→Markdown |
| [network-and-services.md](network-and-services.md) | Every first-party host, the Firestore collections, updates, analytics and telemetry |
| [native-components.md](native-components.md) | Helper processes and the "Aperitif" sandbox bootstrap, the Dock tile plugin, AppleScript API, restart helper |
| [cosmos-rebuild-guide.md](cosmos-rebuild-guide.md) | What Cosmos needs to build to replace Arc, in priority order, with an Arc data importer plan |
| [appendix/](appendix/) | Raw reference tables: menus & shortcuts, ArcCore bridge API (146 classes / 1,821 selectors), Swift classes by module, partial source tree, value-free data schemas, feature flags |
| [tools/arc_export.py](tools/arc_export.py) | Exports your Arc sidebar (favorites, spaces, pinned/unpinned tabs, folders, splits) to neutral JSON before Arc goes away |

## Headline findings

1. **Arc is a Swift/AppKit app that embeds Chromium as a framework.** `ArcCore.framework` is Chromium 156.0.8078.48 compiled with an Objective-C bridge of 146 `Arc*` classes (`ArcBrowserApplication`, `ArcBrowserContext`, `ArcWebContents`, …). Swift wraps that bridge in a module called `ADK`. There is no Chromium UI at all; every tab strip, sidebar, menu and dialog is native Swift.
2. **The UI is built with The Composable Architecture** (`ComposableArchitecture`, `Dependencies`, `CasePaths`) across ~190 Swift modules, shipped as 83 Swift Package resource bundles (48 of them Arc feature modules).
3. **State lives in plain JSON.** About 29 `Storable*.json` files in `~/Library/Application Support/Arc/` hold the sidebar, spaces, profiles, archive, Boosts, key bindings and more, with rotating timestamped backups. `StorableSidebar.json` is the heart of Arc and is fully importable (see [data-and-sync.md](data-and-sync.md)).
4. **Boosts are implemented in Chromium as per-host "effects"**: `ArcBrowserContextEffects` registers CSS, scripts, colour filters, colour schemes and zoom factors against host patterns.
5. **Arc runs real ML on device**: embedding models (GTE, Nomic), small local LLMs (Phi-3.5, Llama 3.2, Gemma 2B, Qwen2 0.5B, OpenELM 270M) via ONNX Runtime / Core ML / MLX, and a command-bar ranking model that is *trained on device with MLX* and reports weight deltas — a federated-learning design.
6. **Arc and Dia share infrastructure.** AI proxies, block lists, web search and help live on `*.diabrowser.engineering` / `*.diabrowser.com`, and Arc 1.170 has a *Send to Dia* menu command.
7. **"Aperitif" is a faster helper-launch path**: four extra Chromium helpers link `ArcCore` directly and run the seatbelt sandbox + PartitionAlloc setup from a tiny `libaperitif.dylib` before Chromium starts, instead of `dlopen`-ing the framework at runtime.

## Scope and what was deliberately left out

This repository documents *how Arc works*; it does not redistribute Arc. Specifically, it contains **no** Arc binaries, frameworks, images, icons, fonts, sounds, videos or animations; no verbatim copies of Arc's JavaScript, CSS or JSON configuration (they are described and summarised instead); no bulk decompiled code; no API keys, client tokens or the Firebase config; and no user data from the profile that was examined — only field names and JSON types.

Facts are labelled by how they were established:

- **Observed** — read directly from a file, header, plist, symbol or string.
- **Decompiled** — from Ghidra pseudocode of a specific function.
- **Inferred** — a conclusion drawn from several observations; treat as a strong hypothesis.

## Method and tools

- **Target**: `Arc.app` 1.170.0, `CFBundleVersion` 89123, commit `Release-89123-9f5625b3740d579b8dfd1e30e19a452433ae5c8c`, built 21 Oct 2026 with Xcode 26.4 (17E202) against the macOS 26.4 SDK; universal x86_64 + arm64; analysis used the arm64 slices. Main executable SHA-256 `25af5f4eaaae5aca25021f2737e90cc4d41fdf195c4a5c4012ea31a1bba4b86a`.
- **REA 6.8.0** (`rea-agents`) for bundle inventory, Mach-O/signature inspection, dylib resolution, Interface Builder decoding and Ghidra-backed decompilation.
- **Ghidra 12.1.4** (headless, via REA) for the helpers, `libaperitif.dylib` and the Dock tile plugin. The 80 MB main executable is stripped, so it was analysed through Swift/Objective-C runtime metadata and strings rather than whole-program decompilation; `ArcCore` (240 MB of Chromium) was analysed through its exported bridge API.
- Apple tools: `codesign`, `otool`, `nm`, `dyld_info -objc`, `lipo`, `plutil`, `swift-demangle`; plus small Python scripts for the `.pak` resources and for value-free JSON schema extraction.
- Analysis date: 25 October 2026.
