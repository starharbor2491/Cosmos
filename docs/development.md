# Building and testing Cosmos

You need macOS 14+ and the Swift command line tools. Full Xcode is not required and nothing is installed globally.

## Build

```bash
scripts/build-app.sh               # release build -> build/Cosmos.app
scripts/build-app.sh --debug       # faster to produce
scripts/build-app.sh --install     # also copy to ~/Applications
swift build                        # just compile (debug); run with .build/debug/Cosmos
```

The script runs `swift build`, then assembles the bundle by hand: it copies the executables and SwiftPM's resource bundles into `Contents/Resources`, draws the icon (`Cosmos --render-icon`, then `sips` and `iconutil`), writes `Info.plist` (http and https URL types, usage strings) from `VERSION`, and signs ad hoc. There is no Xcode project.

## Test

```bash
scripts/test.sh                              # everything, about 260 tests
scripts/test.sh --filter ContentBlockerTests # a suite
```

Use the script rather than `swift test`: with only the command line tools, `swift test` sometimes reports "plugin for module 'TestingMacros' not found". The script retries and clears `.build` when that happens.

| Target | What it covers |
|---|---|
| CosmosCoreTests | workspace tree and merge, archive, ranking and the Command Bar composer, history and frecency, calculator, URL input, public suffixes, JSON store |
| CosmosImportTests | the Arc importer on a generated fixture, Chromium, Firefox and Safari importers, bookmark import, extension discovery, `.crx` unwrapping, Boost note |
| CosmosBlockingTests | filter parser, rule compiler, validator, list manager (no network), fuzzing, and a corpus test that downloads the real EasyList and EasyPrivacy (skipped when offline). Set `COSMOS_VERIFY_WEBKIT=1` to also compile and run rules in real web views |
| CosmosKitTests | the store (tabs, archive, spaces, persistence, incognito, permissions), the Command Bar model, Boost injection, content blocking against real pages, extensions against real pages. Tests that load pages serve them from a throwaway server on 127.0.0.1 |

Tests that touch WebKit are `@MainActor`; WebKit cannot be set up on a background thread.

## Run with a throwaway profile

```bash
.build/debug/Cosmos --demo                    # three themed spaces with sample tabs, in a temporary folder
.build/debug/Cosmos --data-dir /tmp/cosmos    # use a separate data folder
.build/debug/Cosmos --offline                 # never download filter lists
```

`COSMOS_DATA_DIR`, `COSMOS_DEMO=1` and `COSMOS_OFFLINE=1` do the same through the environment. `--demo` implies no downloads and a temporary folder.

## The terminal tool

```bash
cosmos-cli import-arc --summary      # what would come across; writes nothing, prints counts only
cosmos-cli import-arc --force        # replace the Cosmos workspace (the old one is backed up)
```

See [importing-from-arc.md](importing-from-arc.md).

## Looking at the UI without screen recording

Granting a tool permission to record the screen is a lot to ask for a build script, so the app can photograph itself. Run it with a script:

```bash
.build/debug/Cosmos --demo --automation script.json
```

The script is a JSON array of steps; the log goes to `script.json.log`. A snapshot swaps each web view for an image of itself, then renders the window's own views to a PNG. That makes overlays and the sidebar visible exactly as drawn. (It does not show the window frame or the traffic lights.)

```json
[
  {"do": "wait", "seconds": 2},
  {"do": "open", "url": "https://example.com"},
  {"do": "waitLoaded"},
  {"do": "overlay", "name": "siteControls"},
  {"do": "snapshot", "path": "/tmp/site.png"},
  {"do": "quit"}
]
```

| Step | Does |
|---|---|
| `wait` `waitLoaded` | pause; wait for the current page |
| `open` `navigate` `reload` `select` | new tab, same tab, reload, select the nth tab |
| `overlay` `closeOverlay` `type` `key` `chord` | open a panel (`commandBar`, `archive`, `history`, `downloads`, `boosts`, `welcome`, `shortcuts`, `siteControls`, `find`, `theme`), type into the focused field, press keys |
| `space` `sidebar` `split` `peek` `closePeek` `menu` `resize` | switch space, toggle sidebar, add a split, open Peek, run a menu item, set window size |
| `external` | open a link as if from another app (exercises link routing) |
| `boost` `downloadsDir` | create a Boost; choose where downloads go |
| `settings` `closeSettings` `allowlist` | show Settings on a tab (`blocking`, `extensions`, …); turn blocking off for a host |
| `extensions` `extensionAction` | add every extension found on this Mac, or click the nth extension button |
| `eval` | run JavaScript in the current page and log the result |
| `state` | log the space, overlay, tab, window and blocker state |
| `snapshot` | write a PNG (`"window": "settings"` or `"probe"` for those windows) |
| `quit` | quit |

The verbs are in `Sources/CosmosKit/App/Automation.swift`. The automation script that checked ad blocking end to end, for example, loads a page on one site and has it load a Google ad script, an analytics script and a jQuery script from third parties: with blocking on the first two fail and the third loads; with the site allowlisted all three load.

## Layout of the package

`Package.swift` lists the targets. Swift 5 language mode is used so that the UI code stays simple under strict concurrency. Resource files (`public_suffix_rules.txt`, `search-engines.json`, `top-domains.txt`, `agent.js`, the fallback filter rules) are SwiftPM resources, found through `Bundle.module`; the build script copies the resulting bundles into the app.
