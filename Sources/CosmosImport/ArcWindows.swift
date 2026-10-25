import Foundation

/// What `StorableWindows.json` adds to the sidebar: which space was showing, which folders were open, and a few
/// per-item dates for tabs whose own record lacks them. Every part is optional.
struct ArcWindows {
    var focusedSpace: UUID?
    var hasWindows = false
    var expandedItems = Set<UUID>()
    var lastActive: [UUID: Date] = [:]
    var created: [UUID: Date] = [:]

    init() {}

    init(_ root: Any?) {
        guard let d = ArcJSON.dict(root) else { return }
        let windows = (ArcJSON.list(d["windows"]) ?? []).compactMap { ArcJSON.dict($0) }
        hasWindows = !windows.isEmpty
        focusedSpace = ArcID.optional(d["lastFocusedSpaceID"]) ?? windows.lazy.compactMap { ArcID.optional($0["focusedSpaceID"]) }.first
        for window in windows {
            for raw in ArcJSON.allStrings(in: window["expandedItems"]) { expandedItems.insert(ArcID.uuid(raw)) }
            for (k, v) in ArcJSON.pairs(window["itemLastActiveDates"]) {
                if let id = ArcID.optional(k), let date = ArcJSON.date(v), date > (lastActive[id] ?? .distantPast) { lastActive[id] = date }
            }
            for (k, v) in ArcJSON.pairs(window["itemCreatedDates"]) {
                if let id = ArcID.optional(k), let date = ArcJSON.date(v), created[id] == nil { created[id] = date }
            }
        }
    }
}
