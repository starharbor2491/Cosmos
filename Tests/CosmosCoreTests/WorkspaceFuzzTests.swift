import Foundation
import Testing
@testable import CosmosCore

/// Random sequences of every structural operation. After each one the tree must still be healthy, an operation that
/// reports failure must have changed nothing, and what the sidebar indexes into (split weights, focus) must agree
/// with the children.
@Suite struct WorkspaceFuzzTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// What the views index into, beyond the parent/child links `problems()` already checks.
    static func uiProblems(_ ws: Workspace) -> [String] {
        var out: [String] = []
        for item in ws.items.values {
            guard case .split(let s) = item.content else { continue }
            if s.weights.count != item.childIDs.count { out.append("split \(item.id) has \(s.weights.count) weights for \(item.childIDs.count) panes") }
            if let f = s.focusedChildID, !item.childIDs.contains(f) { out.append("split \(item.id) focuses a pane it does not hold") }
            if item.childIDs.contains(where: { ws.items[$0]?.isTab != true }) { out.append("split \(item.id) holds something that is not a tab") }
        }
        for s in ws.spaces {
            _ = ws.navigationOrder(in: s)
            for id in ws.items.keys where ws.section(of: id) == nil { out.append("\(id) is in no section") }
        }
        return out
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64]) func randomOperationsKeepTheTreeHealthy(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D)
        var ws = Workspace.fresh()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var stash: [[SidebarItem]] = []
        var log: [String] = []

        func pick<T>(_ xs: [T]) -> T? { xs.randomElement(using: &rng) }
        func anyID() -> UUID { pick(Array(ws.items.keys)) ?? ws.favoritesRootID }
        func anyOf(_ keep: (SidebarItem) -> Bool) -> UUID? { pick(ws.items.values.filter(keep).map(\.id)) }
        func parentCandidate() -> UUID { rng.next() % 5 == 0 ? UUID() : anyID() }
        func index() -> Int? { [nil, nil, -3, 0, 1, 2, 99].randomElement(using: &rng)! }
        let urls = [nil, URL(string: "https://example.com/a"), URL(string: "https://example.org/b")]

        for step in 0..<400 {
            let before = ws
            var succeeded = true
            switch Int.random(in: 0..<19, using: &rng) {
            case 0, 1, 2:
                let parent = parentCandidate()
                log.append("addTab under \(parent)")
                succeeded = ws.addTab(url: pick(urls) ?? nil, under: parent, at: index(), now: t0) != nil
            case 3:
                log.append("addFolder")
                succeeded = ws.addFolder(title: "F", under: parentCandidate(), at: index(), now: t0) != nil
            case 4:
                if ws.spaces.count < 4 { log.append("addSpace"); ws.addSpace(title: "S") } else if let s = pick(ws.spaces) {
                    log.append("removeSpace"); succeeded = ws.removeSpace(s.id) != nil
                }
            case 5:
                if let id = anyOf({ $0.isTab || $0.isSplit }) { log.append("pin \(id)"); succeeded = ws.pin(id) }
            case 6:
                if let id = anyID() as UUID? { log.append("unpin \(id)"); succeeded = ws.unpin(id) }
            case 7:
                if let id = anyOf({ $0.isTab }) { log.append("favorite \(id)"); succeeded = ws.favorite(id) }
            case 8:
                if let id = anyOf({ $0.isTab }), let s = pick(ws.spaces) { log.append("unfavorite \(id)"); succeeded = ws.unfavorite(id, into: s.id) }
            case 9, 10, 11:
                if let id = anyOf({ !$0.isContainer }) { let p = parentCandidate(); log.append("move \(id) under \(p) at \(String(describing: index()))"); succeeded = ws.move(id, under: p, at: index()) }
            case 12, 13:
                if let id = anyOf({ !$0.isContainer }) { log.append("remove \(id)"); let gone = ws.remove(id); succeeded = !gone.isEmpty; if succeeded { stash.append(gone) } }
            case 14:
                if let sub = pick(stash) { log.append("restore"); succeeded = ws.restore(sub, under: parentCandidate(), at: index()) != nil }
            case 15, 16:
                if let a = anyOf({ $0.isTab }), let b = anyOf({ $0.isTab }) { log.append("combine \(a) \(b)"); succeeded = ws.combineIntoSplit(a, b) != nil }
            case 17:
                if let id = anyOf({ $0.isTab }) { log.append("separate \(id)"); succeeded = ws.separateFromSplit(id) }
            default:
                if let s = pick(ws.spaces) {
                    if rng.next() % 2 == 0 { log.append("clearUnpinned"); _ = ws.clearUnpinned(in: s.id, keeping: Set([anyID()])) }
                    else { log.append("resetPinned"); _ = ws.resetPinned(in: s.id) }
                    succeeded = true
                }
            }

            if !succeeded {
                #expect(ws == before, "step \(step): a refused operation changed the workspace (\(log.last ?? ""))")
                ws = before
            }
            let broken = ws.problems() + Self.uiProblems(ws)
            if !broken.isEmpty {
                Issue.record("seed \(seed) step \(step) after \(log.suffix(3)): \(broken.prefix(3))")
                return
            }
            if step % 40 == 0 {
                let back = try JSONDecoder.cosmos.decode(Workspace.self, from: JSONEncoder.cosmos.encode(ws))
                #expect(back.problems().isEmpty && Self.uiProblems(back).isEmpty, "step \(step): a saved copy came back broken")
                #expect(Set(back.items.keys) == Set(ws.items.keys))
            }
        }
    }

    /// Whatever a damaged file decodes to, repair leaves something the app can open.
    @Test(arguments: Array(1...60) as [UInt64]) func repairIsTotal(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &* 0x9E37_79B9_7F4A_7C15)
        var ws = Workspace.fresh()
        let second = ws.addSpace(title: "Work")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for space in ws.spaces {
            let made = ws.addFolder(title: "F", under: space.pinnedRootID, now: t0)
            let folder = try #require(made)
            for i in 0..<4 { _ = ws.addTab(url: URL(string: "https://e\(i).com"), under: i < 2 ? folder : space.unpinnedRootID, now: t0) }
        }
        let todays = ws.unpinned(in: ws.space(second)!).map(\.id)
        _ = ws.combineIntoSplit(todays[0], todays[1])

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.cosmos.encode(ws)) as? [String: Any])
        var items = try #require(json["items"] as? [[String: Any]])
        let ids = items.compactMap { $0["id"] as? String }
        let contents: [[String: Any]] = [
            ["kind": "tab", "tab": ["isMuted": false]], ["kind": "folder", "folder": ["isExpanded": true]],
            ["kind": "split", "split": ["orientation": "horizontal", "weights": []]], ["kind": "mystery"],
        ]
        for _ in 0..<Int.random(in: 1...12, using: &rng) {
            guard !items.isEmpty else { break }
            let i = Int.random(in: 0..<items.count, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: items.remove(at: i)
            case 1: items[i]["parentID"] = ids.randomElement(using: &rng)
            case 2: items[i]["parentID"] = UUID().uuidString
            case 3: items[i].removeValue(forKey: "parentID")
            case 4: items[i]["childIDs"] = (0..<Int.random(in: 0...5, using: &rng)).map { _ in (ids + [UUID().uuidString]).randomElement(using: &rng)! }
            case 5: items[i]["content"] = contents.randomElement(using: &rng)!
            default: items[i]["childIDs"] = []
            }
        }
        json["items"] = items
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: json["spaces"] = []
        case 1: json["profiles"] = []
        case 2: json["favoritesRootID"] = UUID().uuidString
        default: break
        }
        var broken = try JSONDecoder.cosmos.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        broken.repair()
        #expect(broken.problems().isEmpty, "\(broken.problems().prefix(3))")
        #expect(!broken.spaces.isEmpty && !broken.profiles.isEmpty)
    }
}
