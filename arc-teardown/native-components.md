# Native components

## Chromium helper processes

`ArcCore.framework/Versions/A/Helpers/` contains eight helper apps (**observed**; bundle IDs from their Info.plists, linkage from `otool -L` on the arm64 slices):

| Helper | Bundle ID | Links at load time |
|---|---|---|
| Browser Helper | `company.thebrowser.browser.helper` | libsandbox, libSystem |
| Browser Helper (GPU) | `company.thebrowser.browser.helper` | libsandbox, libSystem |
| Browser Helper (Renderer) | `company.thebrowser.browser.helper.renderer` | libsandbox, libSystem |
| Browser Helper (Alerts) | `company.thebrowser.browser.framework.AlertNotificationService` | libsandbox, libSystem |
| Browser Helper (Aperitif) | `company.thebrowser.browser.helper` | **libaperitif, ArcCore**, libsandbox, libSystem |
| Browser Helper (Aperitif GPU) | `company.thebrowser.browser.helper` | **libaperitif, ArcCore**, libsandbox, libSystem |
| Browser Helper (Aperitif Renderer) | `company.thebrowser.browser.helper.renderer` | **libaperitif, ArcCore**, libsandbox, libSystem |
| Browser Helper (Aperitif Alerts) | `company.thebrowser.browser.framework.AlertNotificationService` | **libaperitif, ArcCore**, libsandbox, libSystem |

### Standard helper (decompiled)

The standard helper's `entry` is Chromium's usual Mac helper `main` (`chrome_exe_main_mac.cc` pattern):

1. Read its own path with `_NSGetExecutablePath`.
2. Check whether it was launched as a seatbelt sandbox client; if so create the seatbelt server ("Failed to create seatbelt sandbox server.") and apply the sandbox ("Failed to initialize sandbox.").
3. `dlopen("<dir>/../../../../ArcCore")` and call its exported `ChromeMain`.

### "Aperitif" helpers (decompiled)

The Aperitif helper's `entry` is just `exit(ChromeMain())`: it links `ArcCore` directly instead of `dlopen`-ing it. The sandbox work moves into **`libaperitif.dylib`** (87 KB arm64, 144 functions), which is listed before `ArcCore` so it initialises first. Its strings and imports show what it does:

- Seatbelt sandbox bootstrap: `sandbox_init_with_parameters`, `sandbox_apply`, a `SandboxSerializer` that receives a compiled or source-mode policy ("could not decode compiled policy string", "SeatbeltExec: %s %s failed"), logging to `org.chromium.sandbox`.
- PartitionAlloc's malloc zone setup: `malloc_zone_register` / `malloc_zone_unregister`, "DelegatingDefaultZoneForPartitionAlloc", "The PartitionAlloc default zone has unexpectedly already been registered."
- One export, `AperitifCheckInitialized`, which `ChromeMain` can call to abort with "Aperitif has not been initialized" if the pre-main stage did not run.

**Inferred:** *Aperitif* ("before the meal") is a launch-speed experiment. Linking the 240 MB framework at load time lets dyld pre-bind it (no runtime `dlopen`), while libaperitif guarantees the sandbox and allocator are installed before any Chromium static initialiser runs. Both helper sets ship so the path can be toggled remotely (`kAperitifHelpers` in ArcCore).

## Dock tile plugin

`Contents/PlugIns/DockTilePlugIn.plugin` (Swift, decompiled with Ghidra) keeps a **custom app icon** in the Dock even while Arc is not running — macOS loads Dock tile plugins into the Dock process.

- Icons (`AppIcon` enum): `original`, `hologram`, `flutedGlass`, `schoolbook`, `colorful`, plus asset `AppIconEarlyBirds`.
- Environments (`AppIconEnvironment`): `release`, `releaseCandidate`, `development`, `canary`, `pullRequest` — each build channel has its own icon set.
- IPC: distributed notifications `company.thebrowser.arc.toDockTilePlugIn` / `…fromDockTilePlugIn` with `message`, `revision`, `appIconName` and `appIconEnvironment` keys; the plugin caches the choice (`appIconNameCached`, `appIconEnvironmentNameCached`) and calls `setDockTile:`.
- Main-app side: `AppIconClient`; flag `custom-app-icons-all-access-enabled` (suggests some icons were gated, e.g. as a member perk — **inferred**).

## App restart helper

`ARCClients_AppRestartClient.bundle/arc_restart_helper.sh` (summarised): takes a bundle ID, app path and arguments; every 0.25 s for up to 300 s it checks the user default `restartClientServiceShouldBeAllowed` is `1`, asks System Events whether the app is still running, and once it has quit reopens it with `open -a … --args …`. Logs to `/tmp/arc_restart_service/`. Used for relaunching after updates or settings that need a restart.

## AppleScript

`Arc.sdef` defines a small automation API (implemented in `Browser/AppleScript/AppDelegate+Applescript.swift`; Objective-C-visible protocols `ArcApplescriptApplication`, `ArcApplescriptWindow`, `ArcApplescriptTab`, `ArcApplescriptGenericMethods`):

| Class | Properties | Elements | Commands |
|---|---|---|---|
| application | `name`, `frontmost`, `version` | windows, tabs | `make`, `count` |
| window | `id`, `name`, `index`, `closeable`, `minimizable`, `minimized`, `resizable`, `visible`, `zoomable`, `zoomed`, `active tab`, `active space`, `incognito`, `mode` (`normal` or `incognito`, set once at creation) | tabs, spaces | `close` |
| tab | `id`, `title`, `URL` (settable), `loading`, `location` (`topApp`, `pinned` or `unpinned`) | — | `select`, `go back`, `go forward`, `reload`, `stop`, `execute` (JavaScript), `close` |
| space | `id`, `title` | tabs | `focus` |

`execute javascript` only works after the user enables **Developer ▸ Allow JavaScript from Apple Events** (`allowJavascriptFromAppleEvents:`), mirroring Chrome.

## Other bundled executables

- `app_mode_loader` and `ChromeAppModeStart_v8` / `ChromeWebAppShortcutCopierMain` exports — Chromium's PWA/app-shortcut machinery.
- `install.sh` — Chromium's stock "install from disk image" helper (copies the app to `/Applications`, optionally as root).
- `ArcCore.sig` — a 1.4 KB binary signature blob for the framework (purpose not determined).
