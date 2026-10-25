import AppKit
import CosmosCore

extension BrowserStore {
    /// ⌥⌘↓ / ⌥⌘↑: the next or previous tab in sidebar order (Favorites, Pinned, Today), wrapping around.
    func selectAdjacentTab(_ delta: Int, in window: WindowState) {
        guard let space = workspace.space(window.focusedSpaceID) else { return }
        let order = workspace.navigationOrder(in: space)
        guard !order.isEmpty else { return }
        let current = currentTabItemID(in: window).flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % order.count + order.count) % order.count
        select(order[next], in: window)
    }

    /// ⌃Tab: back to the tab used before this one; pressed again it returns, so two tabs can be flipped between.
    func selectRecent(_ steps: Int, in window: WindowState) {
        let candidates = window.recent.filter { workspace.item($0) != nil }
        guard candidates.count > 1 else { return }
        let index = min(max(steps, 1), candidates.count - 1)
        select(candidates[index], in: window)
    }

    /// ⌘1…⌘9: the nth Favorite.
    func selectFavorite(number: Int, in window: WindowState) {
        let favs = workspace.favorites
        guard number >= 1, number <= favs.count else { return }
        select(favs[number - 1].id, in: window)
    }
}
