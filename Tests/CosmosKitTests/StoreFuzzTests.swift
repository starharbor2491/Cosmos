import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// Random key presses and drags at the whole store, in two windows at once: whatever happens, the tree stays
/// healthy and no window points at a space or a tab that is gone.
@MainActor
@Suite struct StoreFuzzTests {
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

    @Test(arguments: Array(1...6) as [UInt64]) func randomUseKeepsTheStoreConsistent(seed: UInt64) async throws {
        var rng = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D)
        let rig = Rig(seed: seed % 2 == 0)
        let store = rig.store
        store.haptics.isEnabled = false
        let second = store.makeWindowState()
        store.register(second)
        let windows = [rig.window, second]
        var log: [String] = []

        func pick<T>(_ xs: [T]) -> T? { xs.randomElement(using: &rng) }
        func anyItem() -> UUID { pick(store.workspace.items.values.filter { !$0.isContainer }.map(\.id)) ?? UUID() }
        func anyTab() -> UUID { pick(store.workspace.items.values.filter(\.isTab).map(\.id)) ?? UUID() }
        func anyParent() -> UUID { pick(Array(store.workspace.items.keys)) ?? UUID() }
        func anySpace() -> UUID { pick(store.workspace.spaces)?.id ?? UUID() }
        func url() -> URL? { URL(string: "about:blank?\(Int.random(in: 0..<1000, using: &rng))") }

        for step in 0..<250 {
            // Web views are torn down by the run loop; without a turn now and then they pile up faster than they leave.
            if step % 10 == 0 { try await Task.sleep(for: .milliseconds(2)) }
            let w = windows.randomElement(using: &rng)!
            let op = Int.random(in: 0..<38, using: &rng)
            log.append("\(op)")
            switch op {
            case 0, 1, 2: store.newTab(url: url(), in: w)
            case 3: store.newTab(url: nil, in: w)
            case 4: if store.currentTabItemID(in: w) != nil { store.closeSelected(in: w) }
            case 5, 6: store.closeTab(anyItem(), in: w)
            case 7: store.reopenLastClosed(in: w)
            case 8: if let e = pick(store.archive.entries) { store.restore(e, in: w) }
            case 9: store.togglePin(anyItem(), in: w)
            case 10: store.toggleFavorite(anyItem(), in: w)
            case 11, 12: store.moveItem(anyItem(), under: anyParent(), at: pick([nil, 0, 1, 5, -2]) ?? nil)
            case 13: store.newFolder(in: w)
            case 14: store.duplicate(anyTab(), in: w)
            case 15: store.resetTab(anyTab(), in: w)
            case 16: store.resetPinned(in: w)
            case 17: store.toggleMute(anyTab(), in: w)
            case 18: store.folderToggle(anyItem())
            case 19: store.setAllFolders(expanded: Bool.random(using: &rng), in: w)
            case 20, 21: store.addSplit(in: w, with: url())
            case 22: store.closeFocusedPane(in: w)
            case 23: store.separateFromSplit(anyTab(), in: w)
            case 24, 25: store.splitWith(anyTab(), dragged: anyTab(), in: w)
            case 26: store.switchSpace(to: anySpace(), in: w)
            case 27: store.cycleSpace(Bool.random(using: &rng) ? 1 : -1, in: w)
            case 28: store.switchSpace(number: Int.random(in: 0...6, using: &rng), in: w)
            case 29: if store.workspace.spaces.count < 5 { store.addSpace(title: "S\(step)", icon: .symbol("star"), theme: .aurora, profileID: nil, in: Bool.random(using: &rng) ? w : nil) }
            case 30: store.deleteSpace(anySpace(), in: w)
            case 31: store.moveSpace(anySpace(), by: Int.random(in: -2...2, using: &rng))
            case 32: store.moveTab(anyItem(), toSpace: anySpace(), in: w)
            case 33, 34: store.select(anyItem(), in: w)
            case 35: store.selectAdjacentTab(Bool.random(using: &rng) ? 1 : -1, in: w)
            case 36: store.selectRecent(Int.random(in: 1...3, using: &rng), in: w)
            default:
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: store.clearUnpinned(in: w)
                case 1: if let u = url() { store.openPeek(u, from: anyItem(), in: w) }
                case 2: store.closePeek(in: w)
                case 3: store.promotePeek(in: w)
                default: store.discardIdleRuntimes()
                }
            }

            let broken = store.workspace.problems()
            if !broken.isEmpty { Issue.record("seed \(seed) step \(step) op \(op) (after \(log.suffix(4))): \(broken.prefix(3))"); return }
            for (n, window) in windows.enumerated() {
                if store.workspace.space(window.focusedSpaceID) == nil { Issue.record("seed \(seed) step \(step) op \(op): window \(n) shows a space that is gone"); return }
                if let stale = window.selection.first(where: { store.workspace.item($0.value) == nil }) {
                    Issue.record("seed \(seed) step \(step) op \(op) (after \(log.suffix(4))): window \(n) has selected an item that is gone (\(stale.key))"); return
                }
            }
        }
        for window in windows { store.closePeek(in: window) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
