# Building and testing Cosmos

You need macOS 14+ and the Swift command line tools. Full Xcode is not required and nothing is installed globally.

## Build

```bash
scripts/build-app.sh               # release build -> build/Cosmos.app
scripts/build-app.sh --debug       # faster to produce
scripts/build-app.sh --install     # also copy to ~/Applications
swift build                        # just compile (debug); run with .build/debug/Cosmos
```

The script runs `swift build`, then assembles the bundle by hand: it copies the executables and SwiftPM's resource bundles into `Contents/Resources`, makes the icon from `cosmos icon/cosmos-galaxy-icon.png` (`sips` and `iconutil`; the in-app copy is `Sources/CosmosKit/Resources/AppIcon.png`, made with `sips -z 512 512 "cosmos icon/cosmos-galaxy-icon.png" --out Sources/CosmosKit/Resources/AppIcon.png`), writes `Info.plist` (http and https URL types, usage strings) from `VERSION`, and signs ad hoc. There is no Xcode project.

## Test

```bash
scripts/test.sh                              # everything, over 550 tests
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

## Crash testing

Beyond the unit tests, seeded random testing hammers everything that reads outside input. Each case prints its seed, so a failure reproduces exactly; to look harder, raise the `Array(1...N)` of a suite's `arguments`.

| Suite | What it throws at the code |
|---|---|
| `WorkspaceFuzzTests` | 400 random structural operations per seed (add, move, pin, favorite, split, restore, remove spaces…): the tree stays healthy, an operation that says no changes nothing, split weights and focus agree with the panes, a saved copy reloads. Also random damage to a saved workspace, which `repair()` must always turn into something the app can open |
| `CorruptDataTests` | every file in the data folder (workspace, archive, boosts, settings, session, history…) empty, garbage, truncated, 8 MB, nested 200 000 deep, or decodable but impossible (no spaces, no profiles, cycles); the store must still open and be usable |
| `StoreFuzzTests` | 250 random store operations across two windows (open, close, reopen, pin, drag, split, switch and delete spaces, Peek…): the tree stays healthy and no window selects a tab or space that is gone. It yields to the run loop now and then; without that, web views pile up faster than WebKit can release them |
| `InputFuzzTests`, `FaviconTests` | random text through URL input, calculator, title tidying, ranking, link rules; deeply nested arithmetic; page titles and pages built to make a regex backtrack; a PNG that is a few hundred KB and a gigapixel when decoded |
| `ImporterFuzzTests`, `BrowserImporterFuzzTests` | the Arc profile with random JSON edits and random byte damage; Chromium, Firefox and Safari history and bookmarks, and extension manifests, damaged the same way: an error or a healthy result, never a crash |

Every bug these found has its own named test next to the code it concerns.

Two more ways to look for crashes:

```bash
scripts/stress.sh 7 400                      # the whole app, a throwaway demo profile, 400 random steps
swift test --sanitize=address --scratch-path /tmp/cosmos-asan   # all tests under AddressSanitizer, in their own build folder
```

`scripts/stress.sh` drives the real app through the automation harness (key presses, page loads including hostile ones, overlays, window sizes, Settings tabs, new and closed windows with `STRESS_WINDOWS=1`; the network is off unless you set `STRESS_ONLINE=1`) and reports an exit code, the last step it ran and the exception if it died. The sanitizer build is slow the first time; it finds memory errors, not logic ones, and its larger stack frames also make deep recursion fail sooner (the Arc importer's folder depth cap is set with that in mind).

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
| `settings` `closeSettings` `allowlist` | show Settings on a tab (`blocking`, `extensions`, `radialMenu`, …); turn blocking off for a host |
| `dropdown` `scrollSettings` | open the nth dropdown in Settings (`index`, top to bottom; -1 closes it); scroll the Settings pane `y` points, so a snapshot can show the part below the fold |
| `setTheme` | give the current space one of the preset themes by name, to check a screen on light and dark skies |
| `menuBar` | drive the menu-bar browser: `action` is `enable`, `disable`, `configure` (`home`, `layout`, `remember`), `open`, `close`, `pin`, `go` (`text`) or `state`; snapshot it with `"window": "menubar"` |
| `rightClick` `radial` | right-click the page at `x`,`y` as a real person would (with `flags`, `hold`); then `dump`, `hover`, `choose` or `back` on the radial menu that opened |
| `extensions` `extensionAction` | add every extension found on this Mac, or click the nth extension button |
| `eval` | run JavaScript in the current page and log the result |
| `state` | log the space, overlay, tab, window and blocker state |
| `spatial` | measure the sidebar and check its alignment rules (icons, titles, edges, gaps share columns); see below |
| `snapshot` | write a PNG (`"window": "settings"`, `"probe"` or `"menubar"` for those windows) |
| `quit` | quit |

The verbs are in `Sources/CosmosKit/App/Automation.swift`. The automation script that checked ad blocking end to end, for example, loads a page on one site and has it load a Google ad script, an analytics script and a jQuery script from third parties: with blocking on the first two fail and the third loads; with the site allowlisted all three load.

## Spacing and alignment

Every measurement in the interface is meant to come from `Sources/CosmosKit/UI/Metrics.swift`: a 4 pt spacing scale, five corner radii that nest concentrically, row and field heights, the Settings controls' one height, and one column system for the sidebar (gutter, inset, icon, gap, indent). Use a token instead of a local number. What is checked is the sidebar (below) and, for Settings, the controls' heights and insets by reading; other panels still have a few local numbers (the Boosts editor, the theme editor and the Command Bar's rows), which is where to look if something sits 2 pt off.

The `spatial` automation step checks that the sidebar actually follows them. Views tagged `.spatial("name")` report their frames while an automation run is recording, and `SpatialProbe.check` applies the rules (all icons share a column, a folder's children sit under its icon, titles sit one gap after their icon, rows share edges and height, the address pill and Favorites span the rows' width, section rules reach the edge, folder chevrons sit in their depth's column, split panes keep the icon column, the footer's first glyph is centred on it, toolbar buttons are one square size; the last four only when they are on screen). A rule is one line in `SpatialProbe.swift`, with a test in `SpatialProbeTests` that feeds it a deliberately misaligned layout.

## Settings controls

Settings (`Sources/CosmosKit/Settings/`) draws its controls itself: switches, check boxes, segmented choices, dropdowns that open in place (arrow keys, Return, Esc and a click elsewhere all work), buttons, confirmation dialogs, even the focus ring (shown only while the keyboard is what you are using). They are in `SettingsControls.swift`, built from shapes and text on top of one `TapTarget` (hover, press, Return/Space, a 28 pt hit area, accessibility traits, a tick under the finger). A control with no label of its own is named after the row it sits in, so what VoiceOver says is what the row says. `NoSystemControlsInSettingsTests` scans the folder and fails on any system `Toggle`, `Picker`, `Button`, `Form`, `TabView`, `List`, `TextField`, `Menu`, `ProgressView`, `ColorPicker`, tooltip (`.help`), `NSAlert` or similar, so a new setting can't quietly bring one back. Two system pieces are left, each allowed in exactly one file: the text-editing engine inside a text field (an `NSTextField` with no border or background, because typing, selection and input methods are not worth rebuilding) and the file chooser for "Choose a Folder…". Scrolling is SwiftUI's `ScrollView` with its indicators hidden and the pane's edges fading where more content lies past them. Not verified without a screen: VoiceOver reading order and the feel of the dropdown keys.

## Legibility

A space's theme can be as bright as its author likes; what the window paints is adjusted so text reads on it. `Legibility` (CosmosCore) pulls each gradient stop toward black under light text, or toward white under dark text, by the least amount at which every role of text on every surface the sidebar draws (plain, hovered, pressed, selected) reaches its contrast: titles and addresses 4.5:1, hints, placeholders and timestamps 3:1, strokes and glyphs 3:1. Themes that already read are left alone; Aurora, Supernova and Pulsar, whose bright ends cannot carry white text, become deeper versions of themselves. Buttons take white or dark text by whichever reads, darkening the fill slightly rather than switching when that is all it takes. `LegibilityTests` checks every preset, and the numbers were measured on rendered screenshots of all eight presets (sidebar text 4.3:1 or more, titles 5.7:1 or more). The 3:1 for hints is below WCAG's 4.5:1 for small text; it is a choice, not an oversight.

## Layout of the package

`Package.swift` lists the targets. Swift 5 language mode is used so that the UI code stays simple under strict concurrency. Resource files (`public_suffix_rules.txt`, `search-engines.json`, `top-domains.txt`, `agent.js`, the fallback filter rules) are SwiftPM resources, found through `Bundle.module`; the build script copies the resulting bundles into the app.
