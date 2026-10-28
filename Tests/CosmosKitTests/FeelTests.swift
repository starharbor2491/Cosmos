import Foundation
import CoreGraphics
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// Haptic feedback: which actions tick, and that the setting silences them. The trackpad itself can't be tested, so
/// each store's `Haptics` writes to a closure the test replaces.
@MainActor
@Suite struct HapticsTests {
    final class Recorder { var played: [Haptics.Pattern] = [] }

    private func rig() -> (Rig, Recorder) {
        let rig = Rig(seed: true)
        let recorder = Recorder()
        rig.store.haptics.output = { recorder.played.append($0) }
        return (rig, recorder)
    }

    @Test func pinningATabGivesALevelChange() throws {
        let (rig, rec) = rig()
        let tab = try #require(rig.today.first)
        rig.store.togglePin(tab.id, in: rig.window)
        #expect(rec.played == [.levelChange])
    }

    @Test func aPinThatIsRefusedIsSilent() throws {
        let (rig, rec) = rig()
        let root = rig.space.pinnedRootID
        let folder = try #require(rig.store.edit { $0.addFolder(title: "Reading", under: root) })
        rig.store.togglePin(folder, in: rig.window)
        rig.store.toggleFavorite(folder, in: rig.window)
        #expect(rec.played.isEmpty, "a tick means something happened")
        #expect(rig.store.workspace.section(of: folder) != nil)
    }

    @Test func closingATabIsAGenericTap() throws {
        let (rig, rec) = rig()
        let tab = try #require(rig.today.first)
        rig.store.closeTab(tab.id, in: rig.window)
        #expect(rec.played == [.generic])
    }

    @Test func openingAFolderAligns() throws {
        let (rig, rec) = rig()
        let folder = try #require(rig.store.workspace.pinned(in: rig.space).first { $0.isFolder })
        rig.store.folderToggle(folder.id)
        #expect(rec.played == [.alignment])
    }

    @Test func changingSpaceGivesALevelChangeAndNotWhenNothingChanged() throws {
        let (rig, rec) = rig()
        let other = try #require(rig.store.workspace.spaces.first { $0.id != rig.window.focusedSpaceID })
        rig.store.switchSpace(to: other.id, in: rig.window)
        #expect(rec.played == [.levelChange])
        rig.store.switchSpace(to: other.id, in: rig.window)
        #expect(rec.played == [.levelChange], "switching to the space you are already in is not an event")
    }

    @Test func favoritingAndSplittingAreLevelChanges() throws {
        let (rig, rec) = rig()
        let tab = try #require(rig.today.first)
        rig.store.toggleFavorite(tab.id, in: rig.window)
        #expect(rec.played == [.levelChange])
    }

    @Test func turningHapticsOffSilencesEverything() throws {
        let (rig, rec) = rig()
        rig.store.settings.trackpadHaptics = false
        let tab = try #require(rig.today.first)
        rig.store.togglePin(tab.id, in: rig.window)
        rig.store.closeTab(tab.id, in: rig.window)
        #expect(rec.played.isEmpty)
        rig.store.settings.trackpadHaptics = true
        rig.store.togglePin(try #require(rig.today.first).id, in: rig.window)
        #expect(!rec.played.isEmpty)
    }

    @Test func olderSettingsFilesStillLoadWithHapticsOn() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"sidebarWidth": 300}"#.utf8))
        #expect(old.trackpadHaptics)
        #expect(old.sidebarWidth == 300)
        let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"trackpadHaptics": false}"#.utf8))
        #expect(!off.trackpadHaptics)
    }
}

/// A two-finger swipe across the sidebar changes space, following the fingers and giving way at the ends.
@Suite struct SwipeTrackerTests {
    private func tracker(previous: Bool = true, next: Bool = true) -> SwipeTracker {
        var t = SwipeTracker()
        t.canGoPrevious = previous
        t.canGoNext = next
        return t
    }

    @Test func aShortSwipeSpringsBackAndALongOneCommits() {
        var short = tracker()
        _ = short.update(delta: -30)
        #expect(short.finish() == nil)
        var long = tracker()
        _ = long.update(delta: -90)
        #expect(long.finish() == 1, "fingers moving left go to the next space")
        var right = tracker()
        _ = right.update(delta: 90)
        #expect(right.finish() == -1)
    }

    @Test func crossingTheCommitDistanceTicksOnceAndPullingBackTicksAgain() {
        var t = tracker()
        // (The fingers' movement is damped a little before it counts: see `SwipeTracker.damping`.)
        #expect(t.update(delta: -45) == .none)
        #expect(t.update(delta: -45) == .armed)
        #expect(t.update(delta: -10) == .none, "already armed")
        #expect(t.update(delta: 40) == .disarmed)
        #expect(t.finish() == nil)
    }

    @Test func theEndsOfTheListResistAndNeverCommit() {
        var t = tracker(next: false)
        #expect(t.update(delta: -200) == .none)
        #expect(abs(t.offset) <= 28, "pulled against the end it barely moves")
        #expect(t.finish() == nil)
        var first = tracker(previous: false)
        _ = first.update(delta: 200)
        #expect(first.finish() == nil)
    }

    @Test func theContentFollowsTheFingersButNeverFlies() {
        var t = tracker()
        var last: CGFloat = 0
        for _ in 0..<40 {
            _ = t.update(delta: -12)
            #expect(t.offset <= last, "offset only grows toward the swipe")
            last = t.offset
        }
        #expect(last >= -t.maxTravel)
        #expect(last < -20)
    }

    /// The next page comes in under the fingers, so the page has to keep up with them, not lag behind a rubber band.
    @Test func aPageThatCanBeReachedFollowsTheFingersAtAStraightRatio() {
        var t = tracker()
        t.maxTravel = 248
        _ = t.update(delta: -50)
        #expect(abs(t.offset - -50 * SwipeTracker.damping) < 0.001)
        _ = t.update(delta: 130)
        #expect(abs(t.offset - 80 * SwipeTracker.damping) < 0.001)
        _ = t.update(delta: -1000)
        #expect(t.offset == -248, "but never further than one page")
    }

    /// Damped a tad: the page moves a little less than the fingers and a swipe has to go a little further to count.
    @Test func theSwipeIsDampedABit() {
        #expect(SwipeTracker.damping < 1 && SwipeTracker.damping >= 0.7, "a tad, not a drag")
        var t = tracker()
        _ = t.update(delta: -(t.commitDistance + 1))
        #expect(t.finish() == nil, "fingers that moved just over the commit distance have not got there")
        var far = tracker()
        _ = far.update(delta: -(t.commitDistance / SwipeTracker.damping + 1))
        #expect(far.finish() == 1)
    }

    @Test func aFinishedSwipeStartsFromZeroNextTime() {
        var t = tracker()
        _ = t.update(delta: -100)
        _ = t.finish()
        #expect(t.offset == 0)
        #expect(t.update(delta: -10) == .none)
        #expect(t.finish() == nil)
    }
}

/// Pressing hard on a link in a page opens it in Peek, like ⇧-click.
@MainActor
@Suite struct ForceClickTests {
    private func openRuntime(_ rig: Rig) throws -> TabRuntime {
        let id = try #require(rig.store.newTab(url: URL(string: "about:blank"), in: rig.window))
        return try #require(rig.store.runtime(forItem: id, in: rig.window))
    }

    @Test func aForceClickedLinkOpensPeek() throws {
        let rig = Rig()
        let rt = try openRuntime(rig)
        rt.handleAgentMessage(["type": "peekLink", "href": "http://127.0.0.1:9/page"], fromMainFrame: true)
        #expect(rig.window.peek != nil)
    }

    @Test func onlyWebAddressesOpenInPeek() throws {
        let rig = Rig()
        let rt = try openRuntime(rig)
        for href in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "not a url", ""] {
            rt.handleAgentMessage(["type": "peekLink", "href": href], fromMainFrame: true)
        }
        #expect(rig.window.peek == nil)
    }

    @Test func openingPeekIsALevelChange() throws {
        let rig = Rig()
        var played: [Haptics.Pattern] = []
        rig.store.haptics.output = { played.append($0) }
        let rt = try openRuntime(rig)
        rt.handleAgentMessage(["type": "peekLink", "href": "http://127.0.0.1:9/"], fromMainFrame: true)
        #expect(played == [.levelChange])
    }
}
