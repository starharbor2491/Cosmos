import Foundation
@testable import CosmosCore

/// Swift Testing's `#expect` / `#require` wrap their argument in a closure, which cannot call `mutating` methods on a
/// local `var`. This reference-type shell lets tests write `ws.pin(id)` inside the macros.
@dynamicMemberLookup
final class WSBox {
    var value: Workspace
    init(_ v: Workspace = .fresh()) { value = v }

    subscript<T>(dynamicMember kp: KeyPath<Workspace, T>) -> T { value[keyPath: kp] }

    // Reads
    func problems() -> [String] { value.problems() }
    func item(_ id: UUID) -> SidebarItem? { value.item(id) }
    func space(_ id: UUID) -> Space? { value.space(id) }
    func children(of id: UUID) -> [SidebarItem] { value.children(of: id) }
    func pinned(in s: Space) -> [SidebarItem] { value.pinned(in: s) }
    func unpinned(in s: Space) -> [SidebarItem] { value.unpinned(in: s) }
    func section(of id: UUID) -> Workspace.Section? { value.section(of: id) }
    func spaceID(of id: UUID) -> UUID? { value.spaceID(of: id) }
    func tabs(under id: UUID) -> [SidebarItem] { value.tabs(under: id) }
    func idleUnpinnedItems(in id: UUID, interval: ArchiveInterval, now: Date = Date(), exempt: Set<UUID> = []) -> [UUID] {
        value.idleUnpinnedItems(in: id, interval: interval, now: now, exempt: exempt)
    }

    // Writes
    @discardableResult func addTab(url: URL?, title: String? = nil, under p: UUID, at i: Int? = nil, now: Date = Date()) -> UUID? {
        value.addTab(url: url, title: title, under: p, at: i, now: now)
    }
    @discardableResult func addFolder(title: String, under p: UUID, at i: Int? = nil) -> UUID? { value.addFolder(title: title, under: p, at: i) }
    @discardableResult func addSpace(title: String, theme: SpaceTheme = .nebula) -> UUID { value.addSpace(title: title, theme: theme) }
    @discardableResult func removeSpace(_ id: UUID) -> [SidebarItem]? { value.removeSpace(id) }
    @discardableResult func pin(_ id: UUID) -> Bool { value.pin(id) }
    @discardableResult func unpin(_ id: UUID) -> Bool { value.unpin(id) }
    @discardableResult func favorite(_ id: UUID) -> Bool { value.favorite(id) }
    @discardableResult func unfavorite(_ id: UUID, into s: UUID) -> Bool { value.unfavorite(id, into: s) }
    @discardableResult func move(_ id: UUID, under p: UUID, at i: Int? = nil) -> Bool { value.move(id, under: p, at: i) }
    @discardableResult func remove(_ id: UUID) -> [SidebarItem] { value.remove(id) }
    @discardableResult func restore(_ s: [SidebarItem], under p: UUID, at i: Int? = nil) -> UUID? { value.restore(s, under: p, at: i) }
    @discardableResult func combineIntoSplit(_ a: UUID, _ b: UUID, orientation: SplitData.Orientation = .horizontal) -> UUID? {
        value.combineIntoSplit(a, b, orientation: orientation)
    }
    @discardableResult func separateFromSplit(_ id: UUID) -> Bool { value.separateFromSplit(id) }
    @discardableResult func resetPinned(in s: UUID) -> [UUID] { value.resetPinned(in: s) }
    @discardableResult func clearUnpinned(in s: UUID, keeping k: Set<UUID> = []) -> [[SidebarItem]] { value.clearUnpinned(in: s, keeping: k) }
    func updateTab(_ id: UUID, _ change: (inout TabData) -> Void) { value.updateTab(id, change) }
    func archive(_ ids: [UUID], reason: ArchiveReason, now: Date = Date()) -> [ArchivedItem] { value.archive(ids, reason: reason, now: now) }
}
