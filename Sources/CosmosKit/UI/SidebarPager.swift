import SwiftUI

/// Draws the sidebar's pages where `SidebarSlide` says they are: the one that is shown and, while the strip moves, the one
/// it is coming from or going to beside it. Both are the same views throughout (keyed by page), so a page keeps its
/// scrolling and its state when it goes from arriving to resting.
struct SidebarPager<Content: View>: View {
    let slide: SidebarSlide
    let width: CGFloat
    @ViewBuilder let content: (SidebarPage) -> Content

    private struct Placed: Identifiable {
        let page: SidebarPage
        let x: CGFloat
        var id: SidebarPage { page }
    }

    private var placed: [Placed] {
        var out = [Placed(page: slide.shown, x: slide.offset)]
        if let other = slide.other, let x = slide.otherOffset(width: width) { out.append(Placed(page: other.page, x: x)) }
        return out
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placed) { item in
                content(item.page)
                    .frame(width: width)
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
        if swipe.update(delta: delta) != .none { store.haptics.alignment() }
        slide.drag(to: swipe.offset, in: pages)
    }

    /// Fingers lifted: far enough goes to that page (the slide carries on from where the fingers left it), otherwise the
    /// page springs back.
    func swipeEnded() {
        guard !slide.isSettling, !slide.isPending else { swipe.reset(); return }
        if let direction = swipe.finish(), let page = slide.neighbour(direction: direction, in: pages) {
            store.show(page, in: window)
        } else {
            settle()
        }
    }

    /// The window moved to another page, by a swipe or a click or a key: the strip slides there.
    func slideTo(_ page: SidebarPage) {
        guard slide.slide(to: page, width: window.sidebarWidth, in: pages) else { return }
        // The new page is first drawn beside the old one, and only then moves in; asked for in the same breath the
        // slide would start from where the page was last drawn, which is not beside it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            settle()
        }
    }

    private func settle() {
        guard !Motion.reduced else { slide.finish(slide.arrive()); return }
        var token = 0
        withAnimation(Motion.slide, completionCriteria: .logicallyComplete) {
            token = slide.arrive()
        } completion: {
            slide.finish(token)
        }
    }
}
