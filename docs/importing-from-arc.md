# Importing from Arc

Cosmos can bring your Arc sidebar with you: your spaces, Favorites, pinned tabs and folders, Today tabs, split views, the archive and your link-routing rules. The import reads Arc's own data files on your Mac. It never writes to Arc, never needs Arc to be closed, and never sends anything anywhere.

## How to import

**In the app.** Choose *Import from Arc…* from the File menu. Cosmos looks in `~/Library/Application Support/Arc`, shows what it found, and asks before replacing anything you already have. When it finishes you see a short report of what came across and what did not.

**From the terminal.**

```bash
cosmos-cli import-arc --summary            # see what would be imported; writes nothing
cosmos-cli import-arc                      # import into Cosmos's data folder
cosmos-cli import-arc --from ~/Backup/Arc  # import from a copy of Arc's folder
cosmos-cli import-arc --force              # replace an existing Cosmos workspace (the old one is backed up first)
```

| Option | Meaning |
|---|---|
| `--from DIR` | The Arc folder to read. Default: `~/Library/Application Support/Arc`. |
| `--to DATA_DIR` | The Cosmos data folder to write. Default: `$COSMOS_DATA_DIR`, else `~/Library/Application Support/Cosmos`. |
| `--summary` | Print the report and stop. |
| `--force` | Replace an existing `workspace.json`. Without it the command refuses, so a second run cannot wipe your Cosmos setup. |

The command writes `workspace.json`, `archive.json`, `boosts.json` and, if you had link-routing rules, `link-routing.json`. Its output is counts and generic messages only: it never prints a tab title or a URL, so you can paste it into a bug report.

## What comes across

| In Arc | In Cosmos |
|---|---|
| Spaces, in the order of your space bar | Spaces, same order |
| Space title and icon | Same title. Arc's built-in icons become the closest SF Symbol (planet becomes a globe, sunny a sun); emoji icons stay emoji |
| Space theme (gradient colours, intensity, grain, light or dark) | A theme named *Imported*, built from the same colours, with a medium starfield. Edit it in the space editor |
| Favorites | Favorites (tabs only) |
| Pinned tabs and folders, nested as you had them | Pinned tabs and folders. Each pinned tab remembers the address it was imported with as its home |
| Which folders were open | Open folders stay open, closed ones stay closed |
| Today tabs | Today tabs |
| Split views | Split views: up to four panes, horizontal or vertical, with their pane sizes and the focused pane |
| Tab address, title, last-used time, creation time, muted state | The same |
| Archive | The archive. Entries are marked as imported, remember their space, and can be searched and restored |
| Profiles | Profiles, with their names when Arc's profile files list them. Spaces keep their profile |
| Link-routing rules and default | Link-routing rules. Arc's *Little Arc* destination becomes *Probe* |
| The space you were last looking at | The space Cosmos opens on |

### Arc concepts and their Cosmos names

| Arc | Cosmos |
|---|---|
| Little Arc | Probe, the small floating window for links from other apps |
| Space | Space |
| Pinned / Today | Pinned / Today |
| Top Apps (the Favorites row) | Favorites |
| Boost | Boost (not imported yet, see below) |
| Easel | not available |

## What does not come across

- **Easels.** Cosmos has no Easels. Each one is counted in the report as skipped.
- **Notes** and **Captures.**
- **Arc accounts and sync.** Your Arc sign-in, sync state and recovery card are not read.
- **Passwords, cookies, history, bookmarks and extensions.** These live in Arc's Chromium profile, not in the files above. Bring history, bookmarks and passwords across with Cosmos's browser-data importer; sign in to your sites again where needed.
- **Boosts.** The importer notices a Boosts file and tells you it was left alone; reading Arc's Boost format is not done yet.
- **Custom keyboard shortcuts, Live folders, download records and the command bar's learned rankings.**

## Where Arc and Cosmos differ

The importer adapts rather than refuses. Everything it changes is counted in the report.

- **Folders only live in Pinned.** If a folder turns up in Today or Favorites, its tabs are placed where the folder was.
- **Favorites hold only tabs.** Anything else in Favorites becomes plain tabs.
- **Split views hold two to four tabs.** A split with a fifth pane keeps four, and the extra tabs sit next to it. A split with one usable pane becomes a plain tab.
- **Favorites are shared.** Arc keeps a Favorites row per profile; Cosmos has one, so rows from several profiles are merged.
- **Home addresses are approximate.** Arc does not store the address a pinned tab was pinned with, only where it last was. That last address becomes the tab's home; change it if you had navigated away.
- **Tabs that cannot be restored are skipped.** Tabs without an address are skipped, and so are archived pages that only existed inside Arc or Chromium (`arc://`, `chrome-extension://`). A sidebar tab on such a page is imported but will not open in Cosmos.
- **Damaged data is repaired, not copied.** Missing or circular references in Arc's files are dropped and the rest is imported; the report says how many.

## The report

After an import you get counts for spaces, profiles, tabs (Favorites, pinned, Today), folders, split views, archived items, link rules and Boosts; a list of items that were **skipped**, by kind; and **warnings**, one line per kind of adjustment above. It never contains titles, addresses or names, so it is safe to share.

## Running it more than once

Importing again builds the same workspace with the same ids. In the app you are asked before your current workspace is replaced; in the terminal you need `--force`, and the previous files are copied into a `Backups` folder next to them first.

## Troubleshooting

- **"No Arc profile found."** The importer looks for `StorableSidebar.json` in the Arc folder. If Arc is installed somewhere unusual, or you copied the folder, point at it with `--from`.
- **Fewer tabs than expected.** Check the report's skipped list. Tabs from spaces that no longer exist in Arc, and tabs without an address, are not imported.
- **Arc's own backups.** Arc keeps timestamped copies such as `StorableSidebar.<date>.json` beside each file. To import an older state, copy the folder, replace `StorableSidebar.json` with the backup you want, and import from the copy.
