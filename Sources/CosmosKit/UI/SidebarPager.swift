import SwiftUI

/// Draws the sidebar's pages where `SidebarSlide` says they are: the one that is shown and, while the strip moves, the one
/// it is coming from or going to beside it. Both are the same views throughout (keyed by page), so a page keeps its
/// scrolling and its state when it goes from arriving to resting. Pages that are away from their place dim and draw back
/// (`PageLook`), so the strip changes pages the way a transition does and not only by moving.
struct SidebarPager<Content: View>: View {
    let slide: SidebarSlide
    /// How far apart pages are in `slide`'s offsets: the sidebar's width as the fingers count it.
    let unit: CGFloat
    /// The sidebar's width as drawn, which grows while the Library comes in; pages are drawn as far apart as that.
    let width: CGFloat
    @ViewBuilder let content: (SidebarPage) -> Content

    private struct Placed: Identifiable {
        let page: SidebarPage
        let x: CGFloat
        var id: SidebarPage { page }
    }

    private var placed: [Placed] {
        let scale = unit > 0 ? width / unit : 1
        var out = [Placed(page: slide.shown, x: slide.offset * scale)]
        if let other = slide.other, let x = slide.otherOffset(width: unit) { out.append(Placed(page: other.page, x: x * scale)) }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placed) { item in
                let look = PageLook.at(offset: item.x, width: width)
                content(item.page)
                    .frame(width: width)
                    .scaleEffect(look.scale)
                    .opacity(look.opacity)
                    .offset(x: item.x)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Moving the strip

extension SidebarView {
    /// The next page comes in under two fingers one to one, ticks under the finger when the swipe has gone far enough to
    /// count (and again if you pull back), and gives way at the Library and at the last space.
    func swipeMoved(_ delta: CGFloat) {
        // A slide is still settling: this gesture is not taken up, and what it had added up to is forgotten.
        guard !slide.isSettling, !slide.isPending else { swipe.reset(); return }
        slide.returnPage = .space(window.focusedSpaceID)
        let index = pages.firstIndex(of: slide.shown) ?? 0
        swipe.maxTravel = window.sidebarWidth
        swipe.canGoPrevious = index > 0
        swipe.canGoNext = slide.neighbour(direction: 1, in: pages) != nil
        if swipe.update(delta: delta, at: ProcessInfo.processInfo.systemUptime) != .none { store.haptics.alignment() }
        slide.drag(to: swipe.offset, in: pages)
        publish()
    }

    /// Fingers lifted: far enough goes to that page (the slide carries on from where the fingers left it), otherwise the
    /// page springs back.
    func swipeEnded() {
        guard !slide.isSettling, !slide.isPending else { swipe.reset(); return }
        if let direction = swipe.finish(at: ProcessInfo.processInfo.systemUptime), let page = slide.neighbour(direction: direction, in: pages) {
            store.show(page, in: window)
        } else {
            settle()
        }
    }

    /// The window moved to another page, by a swipe or a click or a key: the strip slides there.
    func slideTo(_ page: SidebarPage) {
        // The new page is put beside the old one at once, wherever the change came from (a click on a space asks for it in
        // an animation of its own), and the window's look turns over with it, so nothing on screen moves yet.
        var instant = Transaction()
        instant.disablesAnimations = true
        let moved = withTransaction(instant) {
            // The Library shows the sky of the space it is opened from.
            if page == .library { slide.returnPage = .space(window.focusedSpaceID) }
            return slide.slide(to: page, width: window.sidebarWidth, in: pages)
        }
        guard moved else { return }
        publish()
        // The new page is first drawn beside the old one, and only then moves in; asked for in the same breath the
        // slide would start from where the page was last drawn, which is not beside it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            settle()
        }
    }

    private func settle() {
        guard !Motion.reduced else { slide.finish(slide.arrive()); publish(); return }
        var token = 0
        withAnimation(Motion.slide, completionCriteria: .logicallyComplete) {
            token = slide.arrive()
            publish(animated: true)
        } completion: {
            slide.finish(token)
            publish()
        }
    }

    /// Tells the window how far the strip is between two pages (`SidebarLook`), for its sky and colours. A change goes
    /// straight through, but for the strip settling (`animated`), which they follow in the same animation.
    func publish(animated: Bool = false) {
        let look = self.look
        guard window.sidebarLook != look else { return }
        if animated { window.sidebarLook = look; return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { window.sidebarLook = look }
    }
}
