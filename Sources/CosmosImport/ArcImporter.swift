import Foundation
import CosmosCore

/// Everything an Arc profile maps to in Cosmos.
public struct ArcImportResult: Equatable, Sendable {
    public var workspace: Workspace
    /// Arc's archive, newest first, as `.imported` entries.
    public var archive: [ArchivedItem]
    /// `nil` when the profile has no `StorableLinkRouting.json`.
    public var linkRouting: LinkRouting?
    public var boosts: [Boost]
    /// The space that was showing in Arc's last window, if it could be identified.
    public var focusedSpaceID: UUID?
    public var report: ImportReport

    public init(workspace: Workspace, archive: [ArchivedItem] = [], linkRouting: LinkRouting? = nil, boosts: [Boost] = [],
                focusedSpaceID: UUID? = nil, report: ImportReport = ImportReport()) {
        self.workspace = workspace
        self.archive = archive
        self.linkRouting = linkRouting
        self.boosts = boosts
        self.focusedSpaceID = focusedSpaceID
        self.report = report
    }
}

public enum ArcImportError: Error, Equatable, LocalizedError {
    /// The directory has no `StorableSidebar.json`.
    case profileNotFound
    case unreadable(file: String, reason: String)
    case malformed(file: String, reason: String)
    /// The sidebar file is valid but defines no spaces, so there is nothing to build a workspace from.
    case noSpaces
    /// The imported tree still violated `Workspace.problems()` after `repair()`. This is a bug in the importer.
    case inconsistent(problems: [String])
    /// `write(to:force:)` found a workspace file and was not allowed to replace it.
    case workspaceExists

    public var errorDescription: String? {
        switch self {
        case .profileNotFound: return "No Arc profile was found (StorableSidebar.json is missing)."
        case .unreadable(let file, let reason): return "\(file) could not be read: \(reason)"
        case .malformed(let file, let reason): return "\(file) is not in the expected format: \(reason)"
        case .noSpaces: return "The Arc profile has no spaces to import."
        case .inconsistent(let problems):
            return "The imported workspace failed its consistency check (\(problems.count) problems, first: \(problems.prefix(3).joined(separator: "; ")))."
        case .workspaceExists: return "A Cosmos workspace already exists there. Importing would replace it; pass force to replace it (the old file is backed up)."
        }
    }
}

/// Reads an Arc profile (`~/Library/Application Support/Arc`) into Cosmos types. Read-only: Arc may be running and
/// nothing in the profile directory is ever written.
public enum ArcImporter {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arc", isDirectory: true)
    }

    /// True when `directory` looks like an Arc profile: it holds `StorableSidebar.json`.
    public static func hasProfile(at directory: URL = defaultDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("StorableSidebar.json").path)
    }

    /// Imports the profile in `directory`.
    ///
    /// Only `StorableSidebar.json` is required; `StorableWindows.json`, `StorableArchiveItems.json`,
    /// `StorableLinkRouting.json`, the profile files and the Boosts file are used when present and skipped (with a
    /// warning if they cannot be read) when not. The result always passes `Workspace.problems()`.
    /// - Parameter now: stamped on items Arc gave no date and on the root containers; injectable for tests.
    public static func importProfile(at directory: URL = defaultDirectory, now: Date = Date()) throws -> ArcImportResult {
        let notes = ImportNotes()
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))

        let sidebarFile = directory.appendingPathComponent("StorableSidebar.json")
        guard FileManager.default.fileExists(atPath: sidebarFile.path) else { throw ArcImportError.profileNotFound }
        guard let root = try ArcJSON.load(sidebarFile) as? [String: Any] else {
            throw ArcImportError.malformed(file: sidebarFile.lastPathComponent, reason: "the top level is not an object")
        }

        let sidebar = ArcSidebar.parse(root, notes: notes)
        guard !sidebar.spaces.isEmpty else { throw ArcImportError.noSpaces }

        let windows = ArcWindows(optionalJSON("StorableWindows.json", in: directory, notes: notes))
        let profileFiles = ["StorableProfiles.json", "StorableProfileContainers.json"].compactMap { optionalJSON($0, in: directory, notes: notes) }
        let built = ArcWorkspaceBuilder(sidebar: sidebar, windows: windows, profiles: ArcProfileTable(files: profileFiles), notes: notes, now: stamp).build()
        var workspace = built.workspace
        workspace.repair()
        let problems = workspace.problems()
        guard problems.isEmpty else { throw ArcImportError.inconsistent(problems: problems) }

        let spaceIDs = Set(workspace.spaces.map(\.id))
        var firstSpaceByProfile: [ArcProfileKey: UUID] = [:]
        for space in workspace.spaces { if let key = built.profileKeys[space.id], firstSpaceByProfile[key] == nil { firstSpaceByProfile[key] = space.id } }

        let archive = ArcArchive.parse(optionalJSON("StorableArchiveItems.json", in: directory, notes: notes), spaceIDs: spaceIDs, now: stamp, notes: notes)
        let linkRouting = ArcLinkRouting.parse(optionalJSON("StorableLinkRouting.json", in: directory, notes: notes),
                                               spaceIDs: spaceIDs, firstSpaceByProfile: firstSpaceByProfile, notes: notes)
        let boosts = ArcBoosts.load(directory: directory, notes: notes)
        let focused = windows.focusedSpace.flatMap { spaceIDs.contains($0) ? $0 : nil }

        return ArcImportResult(workspace: workspace, archive: archive, linkRouting: linkRouting, boosts: boosts, focusedSpaceID: focused,
                               report: report(for: workspace, archive: archive, linkRouting: linkRouting, boosts: boosts, notes: notes))
    }

    // MARK: Helpers

    /// A decoded optional file: `nil` when it does not exist, and also (with a warning) when it cannot be parsed, so a
    /// damaged side file never blocks the import.
    private static func optionalJSON(_ name: String, in directory: URL, notes: ImportNotes) -> Any? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try ArcJSON.load(url) } catch {
            notes.warn("\(name) could not be read and was skipped")
            return nil
        }
    }

    private static func report(for workspace: Workspace, archive: [ArchivedItem], linkRouting: LinkRouting?, boosts: [Boost], notes: ImportNotes) -> ImportReport {
        var report = ImportReport()
        report.spaces = workspace.spaces.count
        report.profiles = workspace.profiles.count
        report.favorites = workspace.favorites.filter(\.isTab).count
        for space in workspace.spaces {
            report.pinnedTabs += workspace.tabs(under: space.pinnedRootID).count
            report.unpinnedTabs += workspace.tabs(under: space.unpinnedRootID).count
        }
        report.folders = workspace.items.values.filter(\.isFolder).count
        report.splitViews = workspace.items.values.filter(\.isSplit).count
        report.archivedItems = archive.count
        report.linkRules = linkRouting?.rules.count ?? 0
        report.boosts = boosts.count
        report.warnings = notes.warnings
        report.skipped = notes.skipped
        return report
    }
}

// MARK: - Saving

public extension ArcImportResult {
    /// The files `write(to:force:)` creates, relative to the data directory.
    static let fileNames = ["workspace.json", "archive.json", "boosts.json", "link-routing.json"]

    /// Writes the import to a Cosmos data directory (see `CosmosPaths`) as `workspace.json`, `archive.json`
    /// (`ArchiveData`), `boosts.json` (`BoostLibrary`) and, when the profile had link routing, `link-routing.json`.
    ///
    /// Refuses to replace an existing workspace unless `force` is set; a forced replacement first backs the old files up
    /// into the usual `Backups/` folder. Returns the names of the files written.
    @discardableResult
    func write(to directory: URL, force: Bool = false) throws -> [String] {
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: workspaceURL.path), !force { throw ArcImportError.workspaceExists }

        func store<T: Codable>(_ name: String, _ type: T.Type) -> JSONFileStore<T> {
            let s = JSONFileStore<T>(url: directory.appendingPathComponent(name))
            s.backupInterval = 0
            return s
        }
        var written: [String] = []
        try store("workspace.json", Workspace.self).save(workspace); written.append("workspace.json")
        try store("archive.json", ArchiveData.self).save(ArchiveData(entries: archive, limit: max(5000, archive.count))); written.append("archive.json")
        try store("boosts.json", BoostLibrary.self).save(BoostLibrary(boosts: boosts)); written.append("boosts.json")
        if let linkRouting {
            try store("link-routing.json", LinkRouting.self).save(linkRouting); written.append("link-routing.json")
        }
        return written
    }
}
