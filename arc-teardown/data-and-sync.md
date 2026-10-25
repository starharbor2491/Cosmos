# Data, file formats and sync

Arc keeps nearly all app state as JSON in **`~/Library/Application Support/Arc/`**. Chromium's own profile data (history, cookies, passwords, extensions) lives separately, in Chromium's usual `User Data` layout. The structures below were confirmed against a real profile, keeping only field names and types; the full value-free schema is in [appendix/storable-schema.md](appendix/storable-schema.md).

## Files

**Observed.** The executable references these 29 files (by name):

| File | Holds |
|---|---|
| `StorableSidebar.json` | **The sidebar**: spaces, favorites, pinned/unpinned tabs, folders, splits, plus both sync states (≈ the whole Arc model) |
| `StorableWindows.json` | Open windows, their focused space and sidebar width/mode |
| `StorableProfiles.json`, `StorableProfileContainers.json` | Profiles and their mapping to Chromium browser contexts |
| `StorableArchive.json`, `StorableArchiveItems.json` | Archive settings and archived tabs |
| `StorableBoostsData.json` | Boosts |
| `StorableLiveData.json` | Live Folder data per profile |
| `StorableLinkRouting.json` | Link-routing rules (`rules[].urlMatch`, `destination`, `defaultDestination`) |
| `StorableKeyBindings.json` | Custom keyboard shortcuts |
| `StorableCommandBarAdditionalRanking.json` | Learned command-bar choices and tab-switch history per profile |
| `StorableHome.json` | Arc Home / start page state |
| `StorableCaptures.json`, `StorableDownloadMetadata.json`, `StorablePasteboardHistory.json` | Captures, download bookkeeping, clipboard history |
| `StorableMembershipCard.json`, `StorableAuthState.json` | Member card, sign-in state |
| `StorableFirebaseEncryptionKey.json`, `StorableFirebaseLastSeenSchemaVersion.json`, `StorableFirebaseSyncDebugState.json` | Firebase sync key material and bookkeeping |
| `StorableFeatureFlags.json`, `StorableDynamicLogLevels.json`, `StorableDeveloperModeState.json`, `StorableDefaultBrowserPrompts.json`, `StorableASEConfiguration.json`, `StorablePreviewsDataClient.json`, `StorableSessionRestorationData.json`, `StorableTodosData.json` | Settings and smaller feature state |

Alongside them are image caches (`SidebarItemsFaviconCache/`, `ArchiveItemsFaviconCache/`, `BoostsImageCache/`), `Captures/`, `StorableARCDocuments/` (notes), `RemoteAssetDirectory/` and `IgnoredPaths.json`.

**Backups (observed):** before rewriting, Arc keeps timestamped copies named `Storable<Name>.<yyyy-MM-dd-HH-mm-ss-SSS>.json`, e.g. `StorableArchive.2026-10-21-15-43-22-611.json`. The *Restore Data* menu item restores from these.

## Encoding conventions

These are Swift `Codable` defaults, which matters for anyone writing an importer (**observed**):

- **Dates** are `Double` seconds since **1 January 2001** (Apple's reference date), not Unix time. To convert: `unix = value + 978307200`.
- **Dictionaries keyed by IDs are flat arrays** that alternate key, value, key, value: `["<uuid>", {…, "id": "<uuid>"}, "<uuid>", {…}]`. (Swift encodes `Dictionary` with non-`String` keys this way.) The key always equals the value's `id`.
- **Enums with associated values** are objects with one key, the case name; unlabeled payloads are `_0`, `_1`: e.g. `{"spaceItems": {"_0": "<spaceID>"}}`, `{"default": true}`.
- `StorableCommandBarAdditionalRanking.json` uses a different, explicit enum style: `{"type": "<case>", "associatedValues": {...}}`.

## The sidebar model

`StorableSidebar.json` top level:

```
{
  "sidebar":            { "containers": [ {"global": {}}, { "spaces": [...], "items": [...], "topAppsContainerIDs": [...] } ] },
  "sidebarSyncState":   { ... CloudKit sync mirror ... },
  "firebaseSyncState":  { ... Firebase sync mirror ... }
}
```

**Items** (`containers[1].items`, alternating ID/object). Every node in the sidebar tree is an item:

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `parentID` | UUID / null | Tree parent |
| `childrenIds` | [UUID] | Ordered children |
| `title` | string / null | User-set title (folders, renamed tabs) |
| `createdAt` | 2001-epoch seconds | |
| `isUnread` | bool | |
| `originatingDevice` | UUID | For sync |
| `data` | enum | One of the cases below |

`data` cases:

- `tab` — `savedURL`, `savedTitle`, `savedMuteStatus`, `timeLastActiveAt`, `referrerID`, `activeTabBeforeCreationID`
- `list` — a folder (children via `childrenIds`)
- `itemContainer` — a root: `containerType` is `spaceItems(_0: spaceID)` (a space's pinned or unpinned root) or `topApps(_0: {default: true})` (Favorites)
- `splitView` — `focusItemID`, `itemWidthFactors` (alternating item ID / width), `layoutOrientation`, `timeLastActiveAt`
- `easel` — `easelID` (seen in archived items; other feature-specific cases may exist)

**Spaces** (`containers[1].spaces`, alternating ID/object):

| Field | Notes |
|---|---|
| `id`, `title` | |
| `containerIDs` | `["pinned", <rootID>, "unpinned", <rootID>]` — the two item-container roots of this space |
| `newContainerIDs` | Same, newer enum form: `[{"pinned": {}}, <id>, {"unpinned": {"_0": {"shared": {}}}}, <id>]` |
| `profile` | `{"default": true}` or a custom profile reference |
| `customInfo.iconType.icon` | Emoji or SF Symbol name (`SFSymbolEmojiLookupTable.json` maps between them) |
| `customInfo.windowTheme` | Theme: `background.single._0.style.color._0.blendedGradient._0` with `baseColors[]`, `overlayColors[]` (RGBA + `colorSpace`), `modifiers {intensityFactor, noiseFactor, overlay}`, `translucencyStyle`, `wheel.analogous`; plus `isVibrant`, `contentOverBackgroundAppearance`, `primaryColorPalette {midTone, shaded, shadedDark, tintedLight}`, `semanticColorPalette.appearanceBased.{light,dark}` with `background`, `foregroundPrimary/Secondary/Tertiary`, `cutoutColor`, `maxContrastColor`, `minContrastColor`, `hover`, `focus` |

**To rebuild a space's sidebar:** look up its pinned and unpinned root IDs from `containerIDs`, then walk `childrenIds` recursively through `items`. Favorites are the children of the item whose `containerType` is `topApps`.

`StorableWindows.json` holds `windows[]` (each with `focusedSpaceID`, `style.standard.sidebarContext`, and `contents.windowContents` / `contents.splitViewState.windowContentIDs`) and global `sidebarViewPreferences {sidebarWidth, sidebarMode}`. `StorableArchiveItems.json` stores archived tabs as `items[]` with `archivedAt`, `reason`, `source` (e.g. `littleArc`) and the original `sidebarItem` (same item shape as above, including the `easel {easelID}` case).

## Sync

Arc has two sync systems, both mirrored inside `StorableSidebar.json`:

1. **CloudKit (original).** `sidebarSyncState` holds `container` and `items`, each a `value` plus `encodedCKRecordFields` (serialised `CKRecord` system fields), and `serverChangeToken`, `hasCreatedCustomZone`, `hasCreatedPrivateSubscription`. Container `iCloud.net.arc.sidebar` (entitlement) via `SidebarSyncCloudKit` / `CloudKitContainerClient`. **Observed.**
2. **Firebase / Firestore (newer).** `firebaseSyncState` holds `syncData {items[], spaceModels[], orderedSpaceIDs, dataEra}`, where every record is wrapped as `{value, lastChangeDate, lastChangedDevice}` — a per-record last-writer-wins scheme — plus `lastSyncedTimestamp`, `publishInProgress` and `currentPublishTransactionRetryCount`. Modules `FirebaseSidebarSyncClient`, `FirebaseSidebarSyncCommon`, `FirebaseSidebarSyncSchemaClient`, `FirebaseSyncDebugClient`. Firestore collections seen in the binary: `sidebar`, `spaces`, `profiles`, `boosts`, `easels`, `objects`, `presence`, `documents`. **Observed.**

**End-to-end encryption (inferred from several observations):** Firebase sync data is encrypted on the client. Evidence: `FirebaseSyncRemoteEncryptionClient`, `EncryptionClient`, `EncryptionRecoveryClient`, a local `StorableFirebaseEncryptionKey.json`, libsodium (`Sodium`) linked in, and flags `recovery-mnemonic-after-sign-in-enabled` / `lost-recovery-card-flow-enabled` (help article "Arc Sync … recovery cards"). The user's recovery card or mnemonic restores the key on a new device.

Flags such as `i-cloud-sync-deprecation-ui-enabled` and `new-user-cloud-kit-sync-enrollment-disabled` show the move from CloudKit to Firebase.

## What an importer needs

For Cosmos, a faithful Arc import needs only `StorableSidebar.json` (structure), `StorableWindows.json` (which space was open) and, optionally, `StorableArchiveItems.json`, `StorableBoostsData.json` and `StorableLinkRouting.json`. History, bookmarks, passwords and cookies come from the Chromium profile using any standard Chromium importer. See [cosmos-rebuild-guide.md](cosmos-rebuild-guide.md).
