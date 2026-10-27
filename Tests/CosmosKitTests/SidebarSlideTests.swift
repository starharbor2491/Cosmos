import CoreGraphics
import Foundation
import Testing
@testable import CosmosKit

/// The sidebar is a strip of pages (the Library, then each space) that slides under the viewer: where each page sits
/// while the fingers move, when they let go, and when something else (a click, a key) changes the page.
@Suite struct SidebarSlideTests {
    private let one = UUID(), two = UUID(), three = UUID()
    private var pages: [SidebarPage] { SidebarPage.all(spaces: [one, two, three]) }
    private let width: CGFloat = 248

    @Test func theLibraryIsLeftOfTheFirstSpace() {
        #expect(pages == [.library, .space(one), .space(two), .space(three)])
        #expect(SidebarPage.all(spaces: []) == [.library])
    }

    // MARK: Fingers

    @Test func pullingLeftBringsTheNextPageInFromTheRight() {
        var slide = SidebarSlide(shown: .space(one))
        slide.drag(to: -60, in: pages)
        #expect(slide.offset == -60)
        #expect(slide.other == .init(page: .space(two), side: 1))
        #expect(slide.otherOffset(width: width) == -60 + width, "it is one page width to the right of the one being pulled")
    }

    @Test func pullingRightBringsThePreviousPageInFromTheLeft() {
        var slide = SidebarSlide(shown: .space(one))
        slide.drag(to: 60, in: pages)
        #expect(slide.other == .init(page: .library, side: -1), "the Library is left of the first space")
        #expect(slide.otherOffset(width: width) == 60 - width)
    }

    @Test func thereIsNothingToBringInPastTheEnds() {
        var first = SidebarSlide(shown: .library)
        first.drag(to: 40, in: pages)
        #expect(first.other == nil)
        var last = SidebarSlide(shown: .space(three))
        last.drag(to: -40, in: pages)
        #expect(last.other == nil)
        #expect(last.offset == -40, "the page still gives a little, the tracker limits how much")
    }

    @Test func pullingBackThroughZeroSwitchesWhichNeighbourShows() {
        var slide = SidebarSlide(shown: .space(two))
        slide.drag(to: -30, in: pages)
        #expect(slide.other?.page == .space(three))
        slide.drag(to: 30, in: pages)
        #expect(slide.other?.page == .space(one))
        slide.drag(to: 0, in: pages)
        #expect(slide.other == nil)
    }

    @Test func aSwipeThatCommitsContinuesFromWhereTheFingersLeftIt() {
        var slide = SidebarSlide(shown: .space(one))
        slide.drag(to: -80, in: pages)
        let new = slide.neighbour(direction: 1, in: pages)
        #expect(new == .space(two))
        let moved = slide.slide(to: .space(two), width: width, in: pages)
        #expect(moved)
        // Nothing jumps: the page being left is still 80 points left of rest, the new one 168 right of it.
        #expect(slide.shown == .space(two))
        #expect(slide.otherOffset(width: width) == -80)
        #expect(slide.offset == -80 + width)
        #expect(slide.other?.page == .space(one))
    }

    // MARK: Clicks and keys

    @Test func goingForwardEntersFromTheRightAndTheOldPageLeavesLeft() {
        var slide = SidebarSlide(shown: .space(one))
        let moved = slide.slide(to: .space(three), width: width, in: pages)
        #expect(moved)
        #expect(slide.offset == width, "the new page starts one width to the right")
        #expect(slide.otherOffset(width: width) == 0, "the old page has not moved yet")
        _ = slide.arrive()
        #expect(slide.offset == 0)
        #expect(slide.otherOffset(width: width) == -width, "and ends one width to the left")
    }

    @Test func goingBackEntersFromTheLeft() {
        var slide = SidebarSlide(shown: .space(two))
        let moved = slide.slide(to: .library, width: width, in: pages)
        #expect(moved)
        #expect(slide.offset == -width)
        #expect(slide.otherOffset(width: width) == 0)
        _ = slide.arrive()
        #expect(slide.otherOffset(width: width) == width)
    }

    @Test func slidingToThePageAlreadyShownDoesNothing() {
        var slide = SidebarSlide(shown: .space(one))
        let before = slide
        let moved = slide.slide(to: .space(one), width: width, in: pages)
        #expect(!moved)
        #expect(slide == before)
    }

    /// How far a slide has got is known only to the animation, so one that is cut short is finished at once and the new
    /// one starts from a page at rest.
    @Test func aChangeWhileAnotherSlideIsStillMovingFinishesThatOneFirst() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        _ = slide.arrive()
        let moved = slide.slide(to: .library, width: width, in: pages)
        #expect(moved)
        #expect(slide.shown == .library)
        #expect(slide.other == .init(page: .space(two), side: 1), "the page that had just arrived is the one that leaves")
        #expect(slide.otherOffset(width: width) == 0)
        #expect(slide.offset == -width)
    }

    // MARK: Settling

    @Test func aSlideEndsWithOnlyThePageShown() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        let token = slide.arrive()
        let finished = slide.finish(token)
        #expect(finished)
        #expect(slide.other == nil && slide.offset == 0 && slide.shown == .space(two))
    }

    @Test func theEndOfAnEarlierSlideDoesNotCutShortALaterOne() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        let earlier = slide.arrive()
        _ = slide.slide(to: .space(three), width: width, in: pages)
        let later = slide.arrive()
        let cutShort = slide.finish(earlier)
        #expect(!cutShort, "its animation was cut short by the second")
        #expect(slide.other != nil)
        let ended = slide.finish(later)
        #expect(ended)
        #expect(slide.other == nil)
    }

    @Test func aSwipeThatSpringsBackLeavesTheSamePageShown() {
        var slide = SidebarSlide(shown: .space(two))
        slide.drag(to: -30, in: pages)
        let token = slide.arrive()
        #expect(slide.offset == 0)
        #expect(slide.other != nil, "still there while it settles")
        let finished = slide.finish(token)
        #expect(finished)
        #expect(slide.shown == .space(two) && slide.other == nil)
    }

    /// SwiftUI may report that an animation that was cut short has ended; that must not end the slide that replaced it.
    @Test func theEndOfACutShortSlideCannotWipeTheNextOneBeforeItStarts() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        let first = slide.arrive()
        _ = slide.slide(to: .space(three), width: width, in: pages)   // the first animation is cut short here
        let late = slide.finish(first)                                 // and its completion arrives before the next arrive()
        #expect(!late)
        #expect(slide.other != nil, "the new slide still has its page to leave")
    }

    @Test func twoChangesBeforeEitherHasStartedLeaveTheLatestPageInViewNotABlankScreen() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        _ = slide.slide(to: .space(three), width: width, in: pages)   // within the same frame
        #expect(slide.shown == .space(three))
        #expect(slide.other == .init(page: .space(two), side: -1), "the page that had just been set up leaves; the first is gone")
        #expect(slide.otherOffset(width: width) == 0, "something is on screen where the viewer is looking")
        #expect(slide.offset == width, "and the new page is one width away, not two")
    }

    // MARK: Leaving the Library

    @Test func fromTheLibraryTheNextPageIsTheSpaceItWasOpenedFrom() {
        var slide = SidebarSlide(shown: .library)
        slide.returnPage = .space(three)
        #expect(slide.neighbour(direction: 1, in: pages) == .space(three), "not the first space")
        slide.drag(to: -40, in: pages)
        #expect(slide.other == .init(page: .space(three), side: 1))
        #expect(slide.neighbour(direction: -1, in: pages) == nil)
    }

    @Test func withNoSpaceToReturnToTheLibraryLeadsToTheFirst() {
        let slide = SidebarSlide(shown: .library)
        #expect(slide.neighbour(direction: 1, in: pages) == .space(one))
    }

    @Test func theReturnPageOnlyMattersFromTheLibrary() {
        var slide = SidebarSlide(shown: .space(two))
        slide.returnPage = .space(three)
        #expect(slide.neighbour(direction: 1, in: pages) == .space(three))
        #expect(slide.neighbour(direction: -1, in: pages) == .space(one))
        var first = SidebarSlide(shown: .space(one))
        first.returnPage = .space(one)
        #expect(first.neighbour(direction: -1, in: pages) == .library)
    }

    // MARK: Pages that go away

    @Test func aPageThatNoLongerExistsIsReplacedAtOnce() {
        var slide = SidebarSlide(shown: .space(two))
        let remaining = SidebarPage.all(spaces: [one, three])
        slide.repair(pages: remaining, current: .space(one))
        #expect(slide.shown == .space(one) && slide.other == nil && slide.offset == 0)
    }

    @Test func aLeavingPageThatNoLongerExistsIsDropped() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        slide.repair(pages: SidebarPage.all(spaces: [two, three]), current: .space(two))
        #expect(slide.shown == .space(two) && slide.other == nil)
    }

    @Test func pagesThatAreAllStillThereAreLeftAlone() {
        var slide = SidebarSlide(shown: .space(one))
        _ = slide.slide(to: .space(two), width: width, in: pages)
        let before = slide
        slide.repair(pages: pages, current: .space(two))
        #expect(slide == before)
    }
}
