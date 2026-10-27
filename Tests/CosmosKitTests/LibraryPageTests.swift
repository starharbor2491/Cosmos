import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The Library is the sidebar page left of the first space. Which page a window shows is `sidebarPage`; the space it
/// remembers (for the sky, the tab in the page) stays the one it was on.
@MainActor
@Suite struct LibraryPageTests {
    @Test func aWindowStartsOnItsSpace() {
        let rig = Rig(seed: true)
        #expect(!rig.window.libraryOpen)
        #expect(rig.window.sidebarPage == .space(rig.window.focusedSpaceID))
    }

    @Test func showingTheLibraryKeepsTheSpaceUnderIt() {
        let rig = Rig(seed: true)
        let space = rig.window.focusedSpaceID
        rig.store.show(.library, in: rig.window)
        #expect(rig.window.sidebarPage == .library)
        #expect(rig.window.focusedSpaceID == space)
    }

    @Test func goingToASpaceLeavesTheLibrary() throws {
        let rig = Rig(seed: true)
        let other = try #require(rig.store.workspace.spaces.last?.id)
        rig.store.show(.library, in: rig.window)
        rig.store.show(.space(other), in: rig.window)
        #expect(rig.window.sidebarPage == .space(other))
    }

    /// The space the Library was opened from is a page too: going back to it is a move, not a no-op.
    @Test func goingBackToTheSpaceTheLibraryWasOpenedFromLeavesIt() {
        let rig = Rig(seed: true)
        let space = rig.window.focusedSpaceID
        rig.store.show(.library, in: rig.window)
        rig.store.show(.space(space), in: rig.window)
        #expect(rig.window.sidebarPage == .space(space))
    }

    @Test func choosingATabLeavesTheLibrary() throws {
        let rig = Rig(seed: true)
        let tab = try #require(rig.today.first)
        rig.store.show(.library, in: rig.window)
        rig.store.select(tab.id, in: rig.window)
        #expect(rig.window.sidebarPage == .space(rig.window.focusedSpaceID), "a tab was chosen: its space is what shows")
    }

    @Test func openingANewTabLeavesTheLibrary() {
        let rig = Rig(seed: true)
        rig.store.show(.library, in: rig.window)
        _ = rig.store.newTab(url: URL(string: "about:blank?library"), in: rig.window)
        #expect(!rig.window.libraryOpen)
    }

    @Test func theSpaceKeysStillMoveBetweenSpacesFromTheLibrary() {
        let rig = Rig(seed: true)
        let first = rig.window.focusedSpaceID
        rig.store.show(.library, in: rig.window)
        rig.store.cycleSpace(1, in: rig.window)
        #expect(!rig.window.libraryOpen)
        #expect(rig.window.focusedSpaceID != first)
    }

    @Test func theLibraryHasACommandOfItsOwn() {
        let rig = Rig(seed: true)
        rig.store.perform(.showLibrary, in: rig.window)
        #expect(rig.window.sidebarPage == .library)
    }

    /// History, the Archive, Downloads and System Resources are sections of the Library, whatever opens them.
    @Test(arguments: [(BrowserCommand.showHistory, LibrarySection.history), (.showArchive, .archive), (.showDownloads, .downloads), (.showResources, .resources)])
    func theCommandsForItsSectionsOpenTheLibraryOnThem(command: BrowserCommand, section: LibrarySection) {
        let rig = Rig(seed: true)
        rig.window.overlay = .shortcuts
        rig.store.perform(command, in: rig.window)
        #expect(rig.window.sidebarPage == .library)
        #expect(rig.window.librarySection == section)
        #expect(rig.window.overlay == nil, "a panel that was up gives way to it")
    }

    @Test func theLibraryRemembersWhichSectionWasShown() {
        let rig = Rig(seed: true)
        rig.store.openLibrary(.history, in: rig.window)
        rig.store.show(.space(rig.window.focusedSpaceID), in: rig.window)
        rig.store.show(.library, in: rig.window)
        #expect(rig.window.librarySection == .history)
    }

    /// The sections are picked on the rail, which is in the sidebar.
    @Test func aHiddenSidebarComesBackWithTheLibrary() {
        let rig = Rig(seed: true)
        rig.window.sidebarVisible = false
        rig.store.openLibrary(.downloads, in: rig.window)
        #expect(rig.window.sidebarVisible)
    }

    @Test func everySectionHasANameAndAGlyph() {
        for section in LibrarySection.allCases {
            #expect(!section.title.isEmpty && !section.symbol.isEmpty)
        }
        #expect(Set(LibrarySection.allCases.map(\.title)).count == LibrarySection.allCases.count)
    }

    // MARK: What acts on the page under the Library

    /// The Library covers the page, so anything that is about the page brings the page back first: otherwise it happens to a
    /// page nobody can see (a search typed in the address bar loads it, and nothing seems to have happened).
    @Test func goingToAnAddressLeavesTheLibrary() {
        let rig = Rig(seed: true)
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        rig.store.show(.library, in: rig.window)
        rig.store.openFromCommandBar(URL(string: "about:blank?b")!, mode: .currentTab, typed: true, in: rig.window)
        #expect(!rig.window.libraryOpen)
    }

    @Test(arguments: [BrowserCommand.reload, .hardReload, .stopLoading, .goBack, .goForward, .find, .zoomIn, .zoomOut, .resetZoom, .muteTab,
                      .copyLink, .togglePin, .toggleFavorite, .addSplit, .resetTab, .showSiteControls, .toggleDeveloperTools])
    func commandsAboutThePageLeaveTheLibrary(command: BrowserCommand) {
        let rig = Rig(seed: true)
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        rig.store.show(.library, in: rig.window)
        rig.store.perform(command, in: rig.window)
        #expect(!rig.window.libraryOpen, "\(command)")
    }

    /// What is about the focused space (its sky, its tabs, its folders, deleting it) is about something the Library is covering
    /// too: it comes back first.
    @Test(arguments: [BrowserCommand.showBoosts, .editTheme, .deleteSpace, .clearUnpinned, .resetPinned, .newFolder, .collapseFolders, .expandFolders])
    func commandsAboutTheSpaceLeaveTheLibraryToo(command: BrowserCommand) {
        let rig = Rig(seed: true)
        rig.store.show(.library, in: rig.window)
        rig.store.perform(command, in: rig.window)
        #expect(!rig.window.libraryOpen, "\(command)")
    }

    @Test(arguments: [BrowserCommand.showSettings, .showShortcuts, .showWelcome, .showLibrary, .pictureInPicture])
    func commandsThatAreAboutNeitherLeaveTheLibraryWhereItIs(command: BrowserCommand) {
        let rig = Rig(seed: true)
        rig.store.show(.library, in: rig.window)
        rig.store.perform(command, in: rig.window)
        #expect(rig.window.libraryOpen, "\(command)")
    }

    @Test func goingToTheNextSpaceFromTheLibraryLeavesIt() {
        let rig = Rig(seed: true)
        rig.store.show(.library, in: rig.window)
        rig.store.perform(.nextSpace, in: rig.window)
        #expect(!rig.window.libraryOpen)
    }

    /// The rail is in the sidebar. With the sidebar hidden the page controls in the bar over the page (Back, Forward, Reload)
    /// are what is left, and they act on the page, so the Library goes with the sidebar.
    @Test func hidingTheSidebarLeavesTheLibrary() {
        let rig = Rig(seed: true)
        rig.store.show(.library, in: rig.window)
        rig.window.sidebarVisible = false
        #expect(!rig.window.libraryOpen)
        rig.store.show(.library, in: rig.window)
        #expect(rig.window.sidebarVisible && rig.window.libraryOpen, "asking for the Library brings the sidebar back")
        rig.store.perform(.toggleSidebar, in: rig.window)
        #expect(!rig.window.libraryOpen && !rig.window.sidebarVisible)
    }

    /// ⌘W is "Archive Tab": with the Library over the page it would archive a tab that cannot be seen.
    @Test func closingWithTheLibraryUpOnlyLeavesIt() throws {
        let rig = Rig(seed: true)
        let tab = try #require(rig.today.first)
        rig.store.select(tab.id, in: rig.window)
        rig.store.show(.library, in: rig.window)
        rig.store.closeSelected(in: rig.window)
        #expect(!rig.window.libraryOpen)
        #expect(rig.store.workspace.item(tab.id) != nil && rig.window.selectedItemID == tab.id, "the tab is still there and still selected")
        #expect(rig.store.archive.entries.isEmpty)
    }

    @Test func theFindBarDoesNotStayUpOverTheLibrary() {
        let rig = Rig(seed: true)
        rig.window.overlay = .find
        rig.store.show(.library, in: rig.window)
        #expect(rig.window.overlay == nil)
    }

    /// The page under the Library is not looked at, so a playing video goes to Picture in Picture as it would when you switch
    /// tabs. (There is no video here: this checks only that the way out and back does not fall over.)
    @Test func leavingAndComingBackWithNoVideoIsQuiet() {
        let rig = Rig(seed: true)
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        rig.store.show(.library, in: rig.window)
        rig.store.show(.space(rig.window.focusedSpaceID), in: rig.window)
        #expect(!rig.window.libraryOpen)
    }

    /// Esc closes what is on top: a panel first, then the Library.
    /// A swipe left from the Library, through the sidebar's own swipe view, goes to the space it was opened from.
    @Test func swipingBackFromTheLibraryLandsOnTheSpaceItWasOpenedFrom() throws {
        let rig = Rig(seed: true)
        let third = try #require(rig.store.workspace.spaces.last?.id)
        rig.store.switchSpace(to: third, in: rig.window)
        rig.store.show(.library, in: rig.window)

        let host = NSHostingView(rootView: SidebarView(store: rig.store, window: rig.window))
        let hosting = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        hosting.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        host.layoutSubtreeIfNeeded()
        func swipeViews(_ view: NSView) -> [SwipeCatcher.SwipeView] {
            (view as? SwipeCatcher.SwipeView).map { [$0] } ?? view.subviews.flatMap(swipeViews)
        }
        let swipe = try #require(swipeViews(host).first)

        swipe.handle(.init(phase: .began))
        for _ in 0..<6 { swipe.handle(.init(phase: .changed, deltaX: -20)) }
        swipe.handle(.init(phase: .ended))
        #expect(rig.window.sidebarPage == .space(third), "not the first space")
    }

    @Test func escClosesAPanelBeforeItLeavesTheLibrary() {
        let rig = Rig(seed: true)
        let space = rig.window.focusedSpaceID
        rig.store.openLibrary(.history, in: rig.window)
        rig.window.overlay = .commandBar(.newTab)
        rig.store.dismiss(in: rig.window)
        #expect(rig.window.overlay == nil && rig.window.libraryOpen)
        rig.store.dismiss(in: rig.window)
        #expect(!rig.window.libraryOpen && rig.window.sidebarPage == .space(space))
    }

    @Test func escWithNothingOpenDoesNothing() {
        let rig = Rig(seed: true)
        let before = rig.window.sidebarPage
        rig.store.dismiss(in: rig.window)
        #expect(rig.window.sidebarPage == before && rig.window.overlay == nil)
    }

    @Test func eachWindowHasItsOwnPage() {
        let rig = Rig(seed: true)
        let second = rig.store.makeWindowState()
        rig.store.register(second)
        rig.store.show(.library, in: rig.window)
        #expect(!second.libraryOpen)
    }

    @Test func aDeletedSpaceLeavesTheLibraryOpen() throws {
        let rig = Rig(seed: true)
        let doomed = try #require(rig.store.workspace.spaces.last?.id)
        rig.store.show(.library, in: rig.window)
        rig.store.deleteSpace(doomed, in: rig.window)
        #expect(rig.window.libraryOpen, "the page being looked at is not one of the spaces")
        #expect(rig.store.workspace.space(rig.window.focusedSpaceID) != nil)
    }
}
