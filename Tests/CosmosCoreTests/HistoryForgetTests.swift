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
        learned.record(query: "old search", candidateID: "web:old search", at: now.addingTimeInterval(-86400))
        learned.record(query: "recent search", candidateID: "web:recent search", at: now.addingTimeInterval(-60))
        learned.record(query: "mixed", candidateID: "web:mixed", at: now.addingTimeInterval(-86400))
        learned.record(query: "mixed", candidateID: "url:https://example.com/secret", at: now.addingTimeInterval(-60))
        learned.forget(since: now.addingTimeInterval(-3600))
        #expect(learned.picks["old search"] != nil)
        #expect(learned.picks["recent search"] == nil, "a query with nothing left goes entirely")
        #expect(learned.picks["mixed"]?.keys.sorted() == ["web:mixed"])
        #expect(!String(decoding: (try? JSONEncoder().encode(learned)) ?? Data(), as: UTF8.self).contains("secret"))
    }

    @Test func forgettingACandidateDropsItEverywhere() {
        var learned = LearnedSelections()
        learned.record(query: "ex", candidateID: "hist:https://example.com/a")
        learned.record(query: "exa", candidateID: "hist:https://example.com/a")
        learned.record(query: "exa", candidateID: "hist:https://example.com/b")
        learned.forget(candidateIDs: ["hist:https://example.com/a", "url:https://example.com/a"])
        #expect(learned.picks["ex"] == nil)
        #expect(learned.picks["exa"]?.keys.sorted() == ["hist:https://example.com/b"])
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

    @Test func theHostsKeptAreThoseOfWhatIsLeft() throws {
        let history = try HistoryStore(path: nil)
        history.record(url: URL(string: "https://www.One.example/a")!, title: "")
        history.record(url: URL(string: "https://two.example/b")!, title: "")
        history.delete(url: URL(string: "https://two.example/b")!)
        #expect(history.hosts() == ["www.one.example"])
    }
}
