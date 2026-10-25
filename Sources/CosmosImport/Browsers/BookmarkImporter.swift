import Foundation
import CosmosCore

/// Turns imported bookmarks into sidebar items: folders become folders and bookmarks become pinned tabs, all in
/// the Pinned section of one space.
public enum BookmarkImporter {
    /// Folders nested deeper than this are folded into their parent.
    public static let maxFolderDepth = 6
    /// No more than this many tabs are created in one import.
    public static let maxTabs = 20_000

    public struct Summary: Equatable, Sendable {
        public var spaceID: UUID
        public var createdSpace = false
        public var tabsAdded = 0
        public var foldersAdded = 0
        /// Bookmarks already present at the same place from an earlier import (or repeated in the source).
        public var duplicatesSkipped = 0
        /// Bookmarks left out because the total cap was reached.
        public var tabsDropped = 0
        public var warnings: [String] = []
    }

    /// Imports `bookmarks` into the space titled `title` (matched ignoring case; created when missing) and returns its id.
    /// Source order is kept, and importing the same bookmarks again adds nothing new. The workspace stays healthy
    /// (`problems()` is empty). See `populateWithSummary` for the counts and warnings.
    @discardableResult
    public static func populate(_ workspace: inout Workspace, with bookmarks: [BookmarkNode], intoSpaceTitled title: String = "Imported") -> UUID {
        populateWithSummary(&workspace, with: bookmarks, intoSpaceTitled: title).spaceID
    }

    public static func populateWithSummary(_ workspace: inout Workspace, with bookmarks: [BookmarkNode], intoSpaceTitled title: String = "Imported",
                                           maxTabs: Int = BookmarkImporter.maxTabs, maxFolderDepth: Int = BookmarkImporter.maxFolderDepth) -> Summary {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported" : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var createdSpace = false
        var spaceID = workspace.spaces.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }?.id
        if spaceID == nil {
            if workspace.profiles.isEmpty { workspace.profiles = [Profile(name: "Personal", isDefault: true)] }
            spaceID = workspace.addSpace(title: name, icon: .symbol("tray.and.arrow.down.fill"))
            createdSpace = true
        }
        let id = spaceID!
        var summary = Summary(spaceID: id)
        summary.createdSpace = createdSpace

        var run = Run(maxTabs: maxTabs, maxFolderDepth: maxFolderDepth, preexisting: Set(workspace.items.keys), summary: summary)
        if let pinnedRoot = workspace.space(id)?.pinnedRootID { run.add(bookmarks, under: pinnedRoot, depth: 0, in: &workspace) }
        summary = run.summary

        let total = bookmarks.bookmarkCount
        summary.tabsDropped = max(0, total - summary.tabsAdded - summary.duplicatesSkipped)
        if summary.tabsDropped > 0 {
            summary.warnings.append("Only the first \(maxTabs) of \(total) bookmarks were imported; \(summary.tabsDropped) were left out.")
        }
        if run.foldedFolders > 0 {
            summary.warnings.append("\(run.foldedFolders) folders nested deeper than \(maxFolderDepth) levels were merged into their parent folders.")
        }
        return summary
    }

    private struct Run {
        let maxTabs: Int
        let maxFolderDepth: Int
        /// Items that existed before this import: only these are reused, one incoming folder per existing folder of the
        /// same name, so re-importing is idempotent without merging same-named siblings of the source.
        let preexisting: Set<UUID>
        var summary: Summary
        var foldedFolders = 0

        var isFull: Bool { summary.tabsAdded >= maxTabs }

        /// Appends `nodes` at the end of `parent`. `depth` is the folder depth of `parent` (0 for the Pinned root).
        mutating func add(_ nodes: [BookmarkNode], under parent: UUID, depth: Int, in ws: inout Workspace) {
            let current = ws.children(of: parent)
            var folders: [String: [UUID]] = [:]
            var urls: Set<String> = []
            for c in current {
                if c.isFolder, preexisting.contains(c.id), let t = c.title { folders[t, default: []].append(c.id) }
                if let u = c.tab?.url { urls.insert(u.absoluteString) }
            }
            for node in nodes {
                if isFull { return }
                switch node.kind {
                case .url:
                    guard let url = node.url else { continue }
                    if !urls.insert(url.absoluteString).inserted { summary.duplicatesSkipped += 1; continue }
                    if addTab(node, url: url, under: parent, in: &ws) { summary.tabsAdded += 1 }
                case .folder:
                    if depth + 1 > maxFolderDepth {
                        foldedFolders += 1
                        add(node.children, under: parent, depth: depth, in: &ws)
                        urls = Set(ws.children(of: parent).compactMap { $0.tab?.url?.absoluteString })
                        continue
                    }
                    let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = title.isEmpty ? "Untitled Folder" : title
                    let id: UUID
                    if let reused = folders[name]?.first {
                        folders[name]?.removeFirst()
                        id = reused
                    } else if let created = ws.addFolder(title: name, under: parent, now: node.dateAdded ?? Date()) {
                        ws.setFolderExpanded(created, false)
                        summary.foldersAdded += 1
                        id = created
                    } else {
                        continue
                    }
                    add(node.children, under: id, depth: depth + 1, in: &ws)
                }
            }
        }

        private func addTab(_ node: BookmarkNode, url: URL, under parent: UUID, in ws: inout Workspace) -> Bool {
            let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = ws.addTab(url: url, title: title.isEmpty ? nil : title, under: parent, now: node.dateAdded ?? Date()) else { return false }
            ws.updateTab(id) { $0.homeURL = url; $0.lastActiveAt = nil }
            if !title.isEmpty { ws.rename(id, to: title) }
            return true
        }
    }
}
