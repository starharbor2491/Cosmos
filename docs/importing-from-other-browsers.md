# Importing from other browsers

Cosmos imports **history** and **bookmarks** from Arc, Chrome, Brave, Edge, Vivaldi, Opera, Chromium, Firefox and Safari. It never changes the other browser's data, and the other browser can stay open.

Arc is two imports. Its sidebar (spaces, pinned tabs, folders, splits) comes from Arc's own `Storable*.json` files; its history and bookmarks come from the embedded Chromium profile at `~/Library/Application Support/Arc/User Data/Default/`, exactly like Chrome's. This page covers the second kind, which works the same for every Chromium browser.

## What is imported

| Browser | Where Cosmos reads | History | Bookmarks |
|---|---|---|---|
| Arc | `~/Library/Application Support/Arc/User Data/<profile>/` | `History` (SQLite) | `Bookmarks` (JSON) |
| Google Chrome | `~/Library/Application Support/Google/Chrome/<profile>/` | `History` | `Bookmarks` |
| Brave | `~/Library/Application Support/BraveSoftware/Brave-Browser/<profile>/` | `History` | `Bookmarks` |
| Microsoft Edge | `~/Library/Application Support/Microsoft Edge/<profile>/` | `History` | `Bookmarks` |
| Vivaldi | `~/Library/Application Support/Vivaldi/<profile>/` | `History` | `Bookmarks` |
| Opera | `~/Library/Application Support/com.operasoftware.Opera/` (one profile, no subfolder) | `History` | `Bookmarks` |
| Chromium | `~/Library/Application Support/Chromium/<profile>/` | `History` | `Bookmarks` |
| Firefox | profiles listed in `~/Library/Application Support/Firefox/profiles.ini` | `places.sqlite` | `places.sqlite` (toolbar, menu, other, mobile) |
| Safari | `~/Library/Safari/` | `History.db` | `Bookmarks.plist` (Favorites, Bookmarks Menu) |

Every profile of a Chromium browser (`Default`, `Profile 1`, ...) and of Firefox is listed separately, with the name the browser gives it and an approximate count of what it holds. Safari has one profile.

### History

- Only `http` and `https` pages. `about:`, `chrome://`, `file:`, `javascript:`, extension pages and Firefox `place:` queries are dropped, as are pages the browser itself hides (embedded frames, redirect hops).
- Pages are identified without their `#fragment` and with a lower-case host, so `https://Example.com/a#top` and `https://example.com/a` are one entry: visit counts add up, the first visit is the earliest and the last visit the latest.
- You can import only history since a date, or only the most recent N pages.
- Dates are converted from each browser's epoch (Chromium 1601, Firefox 1970 in microseconds, Safari 2001). Dates in the future are clamped to now; rows with no usable date are skipped.
- It merges into Cosmos's own history: importing twice adds the counts twice, so import each browser once.

### Bookmarks

Bookmarks land in one Space (named "Imported" unless you choose another; an existing Space with that name is reused). Each source folder becomes a folder in the Space's **Pinned** section and each bookmark becomes a pinned tab, in the original order, with the bookmark's title and its URL as the tab's "home" page.

- Bookmark bars and menus are kept as top-level folders ("Bookmarks Bar", "Bookmarks Toolbar", "Favorites", "Other Bookmarks", "Mobile Bookmarks", ...). Empty ones are left out.
- Folders nested deeper than 6 levels are merged into their parent so the sidebar stays readable; nothing is dropped.
- A large folder (more than 500 bookmarks) is kept whole. At most 20,000 bookmarks are imported in one go; if there are more, the rest are left out and the summary says so.
- Importing the same bookmarks again does not duplicate them.
- Only web pages are imported: bookmarklets (`javascript:`), `chrome://` pages and Firefox smart bookmarks (`place:`) are skipped, and the summary counts them. Firefox tags and Safari's Reading List are not bookmarks and are skipped.

## Requirements

- **Safari needs Full Disk Access.** macOS protects `~/Library/Safari`. Without the permission, Cosmos shows a "permission denied" message instead of importing. To grant it: open **System Settings -> Privacy & Security -> Full Disk Access**, switch on **Cosmos** (when running from a terminal, switch on that terminal app), quit and reopen Cosmos, and import again. You can switch the permission off again afterwards.
- Nothing else is needed. No browser has to be closed. Chrome-family browsers, Arc and Firefox can keep running while you import.

## How the other browser's files are protected

A running browser holds its databases open and locked (Arc keeps `History` open with exclusive locking). Cosmos never opens those files. It copies the database and its `-wal`/`-journal` companions to a private temporary folder (a fast copy-on-write clone on APFS), reads the copy, and deletes it afterwards, even if the import fails. If the browser was in the middle of writing, SQLite rolls the *copy* back to its last committed state. If the files change while copying, Cosmos copies again.

## What is not imported, and why

| Not imported | Why |
|---|---|
| **Passwords** | Chromium browsers (Arc, Chrome, Brave, Edge, ...) encrypt the `Login Data` database with a key kept in your macOS Keychain under that browser's own name ("Arc Safe Storage", "Chrome Safe Storage", ...). Only that browser is trusted to use the key, and macOS asks for your login password to hand it to anyone else. Firefox keeps its key in `key4.db` behind a master password option, and Safari's passwords live in iCloud Keychain. Cosmos doesn't try to extract any of them. |
| **Cookies and logged-in sessions** | Encrypted with the same per-browser Keychain key, and many sites bind a session to the browser that created it, so copies wouldn't reliably keep you signed in. You sign in once in Cosmos. |
| **Autofill (addresses, cards)** | Same encryption, and payment data is deliberately not exportable. |
| **Extensions** | Cosmos is built on WebKit, which can't run Chrome or Firefox extensions. Ad blocking and page tweaks are built in (content blockers and Boosts). |
| **Open tabs and windows** | Other browsers' session files are internal formats. For Arc, open tabs, pinned tabs and spaces come from its sidebar import instead. |
| **Settings, themes, search engines, site permissions, downloads, saved sessions** | Browser-specific and not portable. |
| **Browser-specific extras** | Edge Collections, Vivaldi Notes and Speed Dials, Opera Workspaces, Firefox containers and tags, Safari Reading List and tab groups, Safari profiles other than the main one. |

### Suggested workaround for passwords

Export your passwords to a CSV file from the old browser, import that file into the password manager you want to use (iCloud Passwords, 1Password, Bitwarden, ...), then **delete the CSV**. It is plain text.

- Arc, Chrome, Brave, Edge, Vivaldi, Opera: the browser's password manager settings (in Chrome and Arc, `chrome://password-manager/settings`) -> **Export passwords**.
- Firefox: `about:logins` -> the "..." menu -> **Export Logins**.
- Safari: Passwords app -> File -> **Export All Passwords** (older macOS: Safari Settings -> Passwords -> "..." -> Export All Passwords).

Do this while the old browser still works.

## Troubleshooting

- **A browser is missing from the list.** Cosmos only looks in the default locations above, and only lists profiles that have a `History` or `Bookmarks` file. A portable or custom-located profile isn't found.
- **"Permission denied" for a browser other than Safari.** The folder is protected by macOS, or the file's permissions were changed. Give Cosmos Full Disk Access as for Safari.
- **A profile imports history but no bookmarks (or the reverse).** The profile has none of that kind; Chromium may not create `Bookmarks` until the first bookmark exists. You'll see a warning, not an error.
- **"Couldn't read ...: file is not a database."** The browser's file is damaged. Open the browser once and let it repair itself, or skip history for that profile.

## For developers

```swift
let profiles = BrowserProfileDiscovery.discover()            // never throws; empty if nothing is installed
let data = try BrowserImporter.read(profiles[0], options: BrowserImportOptions(since: nil, limit: 5_000))
try historyStore.importEntries(data.history)
var workspace = Workspace.fresh()
BookmarkImporter.populate(&workspace, with: data.bookmarks, intoSpaceTitled: "Imported from Chrome")
```

`BrowserImporter.read` throws `BrowserImportError.permissionDenied(path:)` when macOS blocks the read; its message already tells the user how to grant Full Disk Access. `BrowserImportData.report` carries the counts for a summary screen.

To check the importers against the browsers on your own Mac (read-only; prints counts only, never titles, URLs or profile names):

```bash
COSMOS_REAL_BROWSERS=1 scripts/test.sh --filter RealBrowserSmokeTests
```
