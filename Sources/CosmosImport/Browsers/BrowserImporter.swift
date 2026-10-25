import Foundation
import CosmosCore

/// Reads history and bookmarks from any discovered browser profile. Blocking: call it off the main thread.
public enum BrowserImporter {
    /// `read(_:options:)` with the four options spelled as a tuple.
    public static func read(_ profile: BrowserProfile, options: (history: Bool, bookmarks: Bool, since: Date?, limit: Int?)) throws -> BrowserImportData {
        try read(profile, options: BrowserImportOptions(history: options.history, bookmarks: options.bookmarks, since: options.since, limit: options.limit))
    }

    /// Throws `BrowserImportError.permissionDenied` when macOS blocks the read (Safari without Full Disk Access).
    /// Other failures of one kind of data (a missing or corrupt file) become warnings in the report as long as the other
    /// kind could be read; if nothing could be read at all, the first error is thrown.
    public static func read(_ profile: BrowserProfile, options: BrowserImportOptions = BrowserImportOptions()) throws -> BrowserImportData {
        var report = BrowserImportReport(browser: profile.browser, profileName: profile.name)
        var history: BrowserHistoryRead?
        var bookmarks: BrowserBookmarksRead?
        var failures: [(kind: BrowserDataKind, error: BrowserImportError)] = []

        func attempt<T>(_ kind: BrowserDataKind, _ body: () throws -> T) throws -> T? {
            do { return try body() }
            catch {
                let mapped = BrowserFileAccess.map(error, path: profile.directory.path)
                if case .permissionDenied = mapped { throw mapped }
                failures.append((kind, mapped))
                return nil
            }
        }

        let dir = profile.directory
        switch profile.browser.family {
        case .chromium:
            if options.history { history = try attempt(.history) { try ChromiumImporter.readHistory(profileDirectory: dir, options: options) } }
            if options.bookmarks { bookmarks = try attempt(.bookmarks) { try ChromiumImporter.readBookmarks(profileDirectory: dir, now: options.now) } }
        case .firefox:
            if options.history || options.bookmarks {
                if let both = try attempt(options.history ? .history : .bookmarks, { try FirefoxImporter.read(profileDirectory: dir, options: options) }) {
                    history = both.history
                    bookmarks = both.bookmarks
                }
            }
        case .safari:
            if options.history { history = try attempt(.history) { try SafariImporter.readHistory(directory: dir, options: options) } }
            if options.bookmarks { bookmarks = try attempt(.bookmarks) { try SafariImporter.readBookmarks(directory: dir) } }
        }

        if history == nil && bookmarks == nil, let first = failures.first { throw first.error }
        for f in failures { report.warnings.append("Skipped \(f.kind.rawValue): \(f.error.errorDescription ?? "unreadable")") }

        if let history {
            report.historyRowsRead = history.rowsRead
            report.historyRowsSkipped = history.rowsSkipped
            report.historyRowsMerged = history.rowsMerged
            report.historyImported = history.entries.count
        }
        if let bookmarks {
            report.bookmarksImported = bookmarks.nodes.bookmarkCount
            report.bookmarkFoldersImported = bookmarks.nodes.folderCount
            report.bookmarksSkipped = bookmarks.skipped
        }
        return BrowserImportData(history: history?.entries ?? [], bookmarks: bookmarks?.nodes ?? [], report: report)
    }
}
