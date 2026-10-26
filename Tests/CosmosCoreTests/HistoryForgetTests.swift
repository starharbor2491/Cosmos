import Foundation
import Testing
@testable import CosmosCore

/// "Clear" has to leave nothing readable behind: not in what the Command Bar learned from what was typed, and not in the
/// database's own log file.
@Suite struct HistoryForgetTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-history-\(UUID().uuidString)/history.sqlite").path
    }

    private func bytes(of path: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }

    // MARK: What the Command Bar learned

    @Test func forgettingSinceADateDropsThePicksMadeAfterItAndKeepsTheOlderOnes() {
        let now = Date()
        var learned = LearnedSelections()
        learned.record(query: "old search", candidateID: "hist:https://example.com/old", at: now.addingTimeInterval(-86400))
        learned.record(query: "recent search", candidateID: "hist:https://example.com/recent", at: now.addingTimeInterval(-60))
        learned.record(query: "mixed", candidateID: "hist:https://example.com/mixed", at: now.addingTimeInterval(-86400))
        learned.record(query: "mixed", candidateID: "hist:https://example.com/secret", at: now.addingTimeInterval(-60))
        learned.forget(since: now.addingTimeInterval(-3600))
        #expect(learned.picks["old search"] != nil)
        #expect(learned.picks["recent search"] == nil, "a query with nothing left goes entirely")
        #expect(learned.picks["mixed"]?.keys.sorted() == ["hist:https://example.com/mixed"])
        #expect(!String(decoding: (try? JSONEncoder().encode(learned)) ?? Data(), as: UTF8.self).contains("secret"))
    }

    @Test func forgettingACandidateDropsItEverywhere() {
        var learned = LearnedSelections()
        learned.record(query: "ex", candidateID: "hist:https://example.com/a")
        learned.record(query: "exa", candidateID: "hist:https://example.com/a")
        learned.record(query: "exa", candidateID: "hist:https://example.com/b")
        learned.forget(candidateIDs: ["hist:https://example.com/a"])
        #expect(learned.picks["ex"] == nil)
        #expect(learned.picks["exa"]?.keys.sorted() == ["hist:https://example.com/b"])
    }

    /// The Command Bar makes what was typed (an address, a search, a suggestion, a sum) fresh every time, so a pick of one
    /// can never help the ranking; remembering it would only keep the text.
    @Test(arguments: ["url:https://example.com/secret", "web:my private search", "sug:my private suggestion", "site:wiki:my private search", "calc"])
    func whatWasTypedIsNotRemembered(candidateID: String) {
        var learned = LearnedSelections()
        learned.record(query: "my private search", candidateID: candidateID)
        #expect(learned.picks.isEmpty)
    }

    @Test(arguments: ["tab:1", "arch:2", "hist:https://example.com/", "top:example.com", "space:3", "cmd:newSpace"])
    func whatTheCommandBarOffersAgainIsRemembered(candidateID: String) {
        var learned = LearnedSelections()
        learned.record(query: "ex", candidateID: candidateID)
        #expect(learned.picks["ex"]?.keys.sorted() == [candidateID])
    }

    /// A file written by an earlier version holds the typed things; they go when it is loaded.
    @Test func picksOfTypedThingsInAnOldFileAreDropped() throws {
        let old = """
        {"maxQueries":600,"picks":{"private search":{"web:private search":{"count":2,"lastAt":"2026-10-20T10:00:00Z"},
        "hist:https://example.com/":{"count":1,"lastAt":"2026-10-20T10:00:00Z"}},"only typed":{"url:https://x.com":{"count":1,"lastAt":"2026-10-20T10:00:00Z"}}}}
        """
        var learned = try JSONDecoder.cosmos.decode(LearnedSelections.self, from: Data(old.utf8))
        let changed = learned.dropUnlearnable()
        #expect(changed)
        #expect(learned.picks["private search"]?.keys.sorted() == ["hist:https://example.com/"])
        #expect(learned.picks["only typed"] == nil)
        let again = learned.dropUnlearnable()
        #expect(!again)
    }

    // MARK: The database's log file

    @Test func clearingLeavesNoAddressInTheLogFile() throws {
        let path = temporaryPath()
        let history = try HistoryStore(path: path)
        for index in 0..<6 { history.record(url: URL(string: "https://clearme\(index).example/private-page")!, title: "Private \(index)") }
        history.clear()
        for file in [path, path + "-wal"] {
            #expect(!bytes(of: file).contains(Data("clearme".utf8)), "\(file) still holds a cleared address")
        }
    }

    @Test func clearingARangeLeavesNoAddressInTheLogFileEither() throws {
        let path = temporaryPath()
        let history = try HistoryStore(path: path)
        history.record(url: URL(string: "https://keepme.example/")!, title: "Keep", at: Date().addingTimeInterval(-86400 * 3))
        history.record(url: URL(string: "https://clearme.example/private-page")!, title: "Private")
        history.clear(since: Date().addingTimeInterval(-3600))
        #expect(history.count() == 1)
        for file in [path, path + "-wal"] {
            #expect(!bytes(of: file).contains(Data("clearme".utf8)), "\(file) still holds a cleared address")
        }
    }

    @Test func deletingOneAddressLeavesItNowhere() throws {
        let path = temporaryPath()
        let history = try HistoryStore(path: path)
        let url = URL(string: "https://deleteme.example/private-page")!
        history.record(url: url, title: "Private")
        history.record(url: URL(string: "https://keepme.example/")!, title: "Keep")
        history.delete(url: url)
        #expect(history.count() == 1)
        for file in [path, path + "-wal"] {
            #expect(!bytes(of: file).contains(Data("deleteme".utf8)), "\(file) still holds a deleted address")
        }
    }

    /// A page's address is the same page with or without a fragment, and the history keeps it without.
    @Test func anAddressIsTheSamePageWithOrWithoutAFragment() {
        let plain = HistoryStore.address(for: URL(string: "https://example.com/a")!)
        #expect(plain != nil)
        #expect(HistoryStore.address(for: URL(string: "https://example.com/a#section")!) == plain)
        #expect(HistoryStore.address(for: URL(string: "file:///tmp/a")!) == nil)
    }

    @Test func theHostsKeptAreThoseOfWhatIsLeft() throws {
        let history = try HistoryStore(path: nil)
        history.record(url: URL(string: "https://www.One.example/a")!, title: "")
        history.record(url: URL(string: "https://two.example/b")!, title: "")
        history.delete(url: URL(string: "https://two.example/b")!)
        #expect(history.hosts() == ["www.one.example"])
    }

    // MARK: The dated copies of the files

    private struct Note: Codable, Equatable { var text: String }

    @Test func rewritingWithoutBackupsLeavesNoCopyOfTheOldValue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-json-\(UUID().uuidString)", isDirectory: true)
        let store = JSONFileStore<Note>(url: dir.appendingPathComponent("note.json"), backupInterval: 0)
        try store.save(Note(text: "secret"), now: Date().addingTimeInterval(-100))
        try store.save(Note(text: "secret again"), now: Date().addingTimeInterval(-50))
        #expect(!store.backups().isEmpty, "the setup should have made a copy")

        try store.rewriteDiscardingBackups(Note(text: "nothing"))

        #expect(store.backups().isEmpty)
        #expect(try store.load() == Note(text: "nothing"))
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for file in files where !file.hasDirectoryPath {
            #expect(!((try? Data(contentsOf: file)) ?? Data()).contains(Data("secret".utf8)), "\(file.lastPathComponent) still holds it")
        }
    }

    @Test func aStoreThatKeepsNoBackupsMakesNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-json-\(UUID().uuidString)", isDirectory: true)
        let store = JSONFileStore<Note>(url: dir.appendingPathComponent("note.json"), backupInterval: 0, keepBackups: 0)
        try store.save(Note(text: "one"))
        try store.save(Note(text: "two"))
        try store.save(Note(text: "three"))
        #expect(store.backups().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.backupDirectory.path))
    }
}
