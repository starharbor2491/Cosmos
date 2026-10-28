import CoreGraphics
import Foundation

/// The sidebar's pages from left to right: the Library, then every space.
enum SidebarPage: Hashable {
    case library
    case space(UUID)

    static func all(spaces: [UUID]) -> [SidebarPage] { [.library] + spaces.map { .space($0) } }
}

/// How a page looks while it is away from its place: it dims and draws back a little the further it is, so two pages passing
/// each other dissolve into one another as well as moving. Pure, so it can be tested; the pager applies it to every page
/// while the fingers are down and while the strip settles.
struct PageLook: Equatable {
    var opacity: CGFloat
    var scale: CGFloat

    /// A page a whole width away is this much dimmer and smaller. Both change in a straight line with the distance, so the
    /// animation that settles the page (which moves its offset) carries them along with it.
    static let fade: CGFloat = 0.75
    static let shrink: CGFloat = 0.06

    static let rest = PageLook(opacity: 1, scale: 1)

    /// `offset` is how far the page is from its place at rest, to either side.
    static func at(offset: CGFloat, width: CGFloat) -> PageLook {
        guard width > 0, offset.isFinite else { return .rest }
        let distance = min(abs(offset) / width, 1)
        return PageLook(opacity: 1 - fade * distance, scale: 1 - shrink * distance)
    }
}

/// Where the sidebar's pages sit while it slides from one to another. At rest only `shown` is on screen. While it moves,
/// `other` is the page it is coming from or going to, one width to the side of `shown`.
///
/// Pure, so the movement can be tested; the view only animates `offset` back to zero.
struct SidebarSlide: Equatable {
    struct Neighbour: Equatable {
        var page: SidebarPage
        /// -1 when it sits one width to the left of `shown`, +1 to the right.
        var side: Int
    }

    private(set) var shown: SidebarPage
    /// Where `shown` sits, relative to its place at rest.
    private(set) var offset: CGFloat = 0
    private(set) var other: Neighbour?
    /// The Library's way back: the space it was opened from. A swipe left from the Library goes there, like the button and Esc
    /// do, instead of to the first space.
    var returnPage: SidebarPage?
    private var settling = false
    /// A slide has been set up (`slide`) but not let go (`arrive`) yet.
    private var pending = false
    private var generation = 0

    init(shown: SidebarPage) { self.shown = shown }

    var isSettling: Bool { settling }
    /// Set up by `slide` and not let go by `arrive` yet.
    var isPending: Bool { pending }

    func otherOffset(width: CGFloat) -> CGFloat? { other.map { offset + CGFloat($0.side) * width } }

    /// The page a swipe in `direction` (+1 for the next page, -1 for the previous one) would arrive at.
    func neighbour(direction: Int, in pages: [SidebarPage]) -> SidebarPage? {
        if shown == .library, direction >= 0, let returnPage, pages.contains(returnPage) { return returnPage }
        guard let index = pages.firstIndex(of: shown) else { return nil }
        let target = index + (direction < 0 ? -1 : 1)
        return pages.indices.contains(target) ? pages[target] : nil
    }

    /// Fingers on the trackpad: the page is pulled to `offset` and the one it is being pulled toward comes in beside it.
    mutating func drag(to offset: CGFloat, in pages: [SidebarPage]) {
        self.offset = offset
        guard offset != 0, let page = neighbour(direction: offset < 0 ? 1 : -1, in: pages) else { other = nil; return }
        other = Neighbour(page: page, side: offset < 0 ? 1 : -1)
    }

    /// Whatever changes the page: the end of a swipe, a click on a space, a key, a tab chosen in another space. The page
    /// being left stays where it is and the new one starts one width to the side of it, so the strip moves on from
    /// exactly what is on screen. False when there is nothing to slide.
    @discardableResult
    mutating func slide(to page: SidebarPage, width: CGFloat, in pages: [SidebarPage]) -> Bool {
        guard page != shown else { return false }
        // One that is still moving, or was set up a moment ago and has not started, is finished at once: how far it has got is
        // known only to the animation. Its completion must not end this slide, so the count moves on.
        if settling || pending { other = nil; offset = 0; settling = false; pending = false; generation += 1 }
        guard let to = pages.firstIndex(of: page), let from = pages.firstIndex(of: shown) else { jump(to: page); return false }
        let side = to > from ? -1 : 1
        offset -= CGFloat(side) * width
        other = Neighbour(page: shown, side: side)
        shown = page
        pending = true
        return true
    }

    /// The slide is let go: `offset` goes to zero (the view animates it). The token is given back to `finish`.
    mutating func arrive() -> Int {
        offset = 0
        settling = true
        pending = false
        generation += 1
        return generation
    }

    /// The animation ended: only the page that is shown stays. False when another slide has started since.
    @discardableResult
    mutating func finish(_ token: Int) -> Bool {
        guard token == generation else { return false }
        other = nil
        offset = 0
        settling = false
        pending = false
        return true
    }

    mutating func jump(to page: SidebarPage) {
        shown = page
        offset = 0
        other = nil
        settling = false
        pending = false
        generation += 1
    }

    /// Pages come and go (a space is deleted): one that is gone is not shown or left from.
    mutating func repair(pages: [SidebarPage], current: SidebarPage) {
        if !pages.contains(shown) { jump(to: current); return }
        if let other, !pages.contains(other.page) { self.other = nil }
    }
}
