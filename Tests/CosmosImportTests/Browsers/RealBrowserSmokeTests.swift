import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

/// Opt-in: `COSMOS_REAL_BROWSERS=1 scripts/test.sh --filter RealBrowserSmokeTests`.
///
/// Reads the browsers installed on this Mac, read-only, through the same snapshot code path as a real import, and
/// asserts structure only. It prints counts and nothing else: never titles, URLs, profile names or emails.
@Suite(.serialized) struct RealBrowserSmokeTests {
    static let enabled = ProcessInfo.processInfo.environment["COSMOS_REAL_BROWSERS"] == "1"

    @Test(.enabled(if: RealBrowserSmokeTests.enabled, "set COSMOS_REAL_BROWSERS=1 to read this Mac's browsers"))
    func discoversAndReadsInstalledBrowsersReadOnly() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let profiles = BrowserProfileDiscovery.discover(workDirectory: work)
        print("[real-browsers] discovered \(profiles.count) profile(s): "
              + BrowserKind.allCases.map { k in "\(k.displayName)=\(profiles.filter { $0.browser == k }.count)" }.joined(separator: ", "))

        var arcChecked = false
        for (n, profile) in profiles.enumerated() {
            let label = "\(profile.browser.displayName) #\(n + 1)"
            let siblingsBefore = Self.historySiblings(profile)
            print("[real-browsers] \(label): kinds=\(profile.dataKinds.map(\.rawValue).sorted()) counts=\(profile.approximateCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted()) accessDenied=\(profile.accessDenied) default=\(profile.isDefault)")
            do {
                let data = try BrowserImporter.read(profile, options: BrowserImportOptions(workDirectory: work))
                try Self.checkStructure(data)
                let r = data.report
                print("[real-browsers] \(label): history imported=\(r.historyImported) (rows read=\(r.historyRowsRead), skipped=\(r.historyRowsSkipped), merged=\(r.historyRowsMerged)); "
                      + "bookmarks=\(r.bookmarksImported) in \(r.bookmarkFoldersImported) folder(s), non-web skipped=\(r.bookmarksSkipped); warnings=\(r.warnings.count)")
                var ws = Workspace.fresh()
                let summary = BookmarkImporter.populateWithSummary(&ws, with: data.bookmarks)
                #expect(ws.problems().isEmpty)
                #expect(summary.tabsAdded + summary.duplicatesSkipped + summary.tabsDropped == data.bookmarks.bookmarkCount)
                print("[real-browsers] \(label): workspace tabs=\(summary.tabsAdded) folders=\(summary.foldersAdded) duplicates=\(summary.duplicatesSkipped)")
                if profile.browser == .arc { arcChecked = true }
            } catch let error as BrowserImportError {
                guard case .permissionDenied = error else {
                    Issue.record("\(label): unexpected import error (\(error))")
                    continue
                }
                print("[real-browsers] \(label): permission denied (expected for Safari without Full Disk Access)")
                #expect(profile.browser == .safari || profile.accessDenied)
            }
            let siblingsAfter = Self.historySiblings(profile)
            #expect(siblingsAfter.filter { !$0.hasSuffix("-journal") } == siblingsBefore.filter { !$0.hasSuffix("-journal") },
                    "the importer must not create -wal/-shm files next to the original")
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: work.path)).isEmpty, "temporary copies must be deleted")

        if profiles.contains(where: { $0.browser == .arc }) {
            #expect(arcChecked, "Arc is installed here, so its profile should have been readable")
        } else {
            print("[real-browsers] Arc is not installed on this Mac")
        }
    }

    /// File names next to the history database other than the journal (which a running browser creates and deletes itself).
    static func historySiblings(_ profile: BrowserProfile) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profile.directory.path)) ?? []
        return names.filter { ($0.hasPrefix("History") || $0.hasPrefix("places.sqlite")) }.sorted()
    }

    static func checkStructure(_ data: BrowserImportData) throws {
        var seen = Set<String>()
        for e in data.history {
            #expect(["http", "https"].contains(e.url.scheme))
            #expect(e.url.host?.isEmpty == false)
            #expect(e.firstVisit <= e.lastVisit)
            #expect(e.lastVisit >= BrowserTimestamp.earliestPlausible)
            #expect(e.visitCount >= 1)
            #expect(seen.insert(e.url.absoluteString).inserted, "history must be de-duplicated")
        }
        #expect(data.history.map(\.lastVisit) == data.history.map(\.lastVisit).sorted(by: >))
        func check(_ node: BookmarkNode) {
            switch node.kind {
            case .url:
                #expect(["http", "https"].contains(node.url?.scheme))
                #expect(node.children.isEmpty)
            case .folder:
                #expect(node.url == nil)
                node.children.forEach(check)
            }
        }
        data.bookmarks.forEach(check)
        #expect(data.report.historyImported == data.history.count)
        #expect(data.report.bookmarksImported == data.bookmarks.bookmarkCount)
    }
}
