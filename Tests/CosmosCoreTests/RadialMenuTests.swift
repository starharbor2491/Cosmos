import CoreGraphics
import Foundation
import Testing
@testable import CosmosCore

@Suite struct RadialMenuTests {
    // MARK: Recognising WebKit's items

    @Test func webKitItemsAreMatchedByIdentifier() {
        #expect(RadialAction.resolve(identifier: "WKMenuItemIdentifierCopyLink", title: "Copy Link") == .copyLink)
        #expect(RadialAction.resolve(identifier: "WKMenuItemIdentifierOpenLinkInNewWindow", title: "Open Link in New Tab") == .openLinkInNewTab)
        #expect(RadialAction.resolve(identifier: "WKMenuItemIdentifierShareMenu", title: "Share…") == .share)
        #expect(RadialAction.resolve(identifier: "cosmos.openLinkInPeek", title: "Open Link in Peek") == .openLinkInPeek)
    }

    @Test func itemsKnownOnlyByTheirMethodNameAreMatchedByTitle() {
        // WebKit's Cut item carries "forwardContextMenuAction:" as its identifier.
        #expect(RadialAction.resolve(identifier: "forwardContextMenuAction:", title: "Cut") == .cut)
        #expect(RadialAction.resolve(identifier: nil, title: " Back ") == .back)
        #expect(RadialAction.resolve(identifier: "forwardContextMenuAction:", title: "Make Upper Case") == nil)
        #expect(RadialAction.resolve(identifier: "WKMenuItemIdentifierSpellingMenu", title: "Spelling and Grammar") == nil)
    }

    @Test func everyActionHasATitleASymbolAndAContext() {
        for action in RadialAction.allCases {
            #expect(!action.title.isEmpty && !action.symbol.isEmpty && !action.contexts.isEmpty, "\(action)")
        }
    }

    @Test func everyDefaultRingFitsAndOnlyUsesActionsFromItsContext() {
        for context in RadialContext.allCases {
            let ring = RadialAction.defaultRing(for: context)
            #expect(ring.count <= RadialLayout.maxSlices && !ring.isEmpty, "\(context)")
            for action in ring { #expect(action.contexts.contains(context), "\(action) is not offered for \(context)") }
            #expect(Set(ring).count == ring.count, "\(context) lists an action twice")
        }
    }

    // MARK: Contexts

    @Test func theContextFollowsWhatIsUnderThePointer() {
        func detect(link: Bool = false, image: Bool = false, selection: Bool = false, editable: Bool = false, media: Bool = false) -> RadialContext {
            RadialContext.detect(link: link, image: image, selection: selection, editable: editable, media: media)
        }
        #expect(detect() == .page)
        #expect(detect(link: true) == .link)
        #expect(detect(link: true, image: true) == .link, "a linked image is a link")
        #expect(detect(image: true) == .image)
        #expect(detect(selection: true) == .selection)
        #expect(detect(selection: true, editable: true) == .editable)
        #expect(detect(link: true, media: true) == .media)
    }

    // MARK: The ring

    private func entry(_ action: RadialAction?, _ title: String? = nil, id: String? = nil) -> RadialEntry {
        RadialEntry(id: id ?? action?.rawValue ?? UUID().uuidString, action: action, title: title ?? action?.title ?? "Other")
    }

    @Test func aShortMenuIsTheDefaultOrderThenWebKitsExtras() {
        let entries = [entry(.copyLink), entry(.openLink), entry(nil, "Spelling", id: "x1"), entry(.share)]
        let ring = RadialLayout.ring(entries: entries, context: .link, custom: nil)
        #expect(ring.map(\.id) == ["openLink", "copyLink", "share", "x1"])
    }

    @Test func aLongMenuKeepsSevenAndHidesTheRestUnderMore() {
        let entries = RadialAction.defaultRing(for: .editable).map { entry($0) } + (0..<7).map { entry(nil, "Extra \($0)", id: "x\($0)") }
        let ring = RadialLayout.ring(entries: entries, context: .editable, custom: nil)
        #expect(ring.count == RadialLayout.maxSlices)
        let more = try! #require(ring.last)
        #expect(more.id == RadialLayout.moreID && more.isGroup)
        #expect(ring.dropLast().count + more.children.count == entries.count, "nothing is lost")
        #expect(Set(ring.dropLast().map(\.id) + more.children.map(\.id)) == Set(entries.map(\.id)))
    }

    @Test func exactlyEightEntriesNeedNoMore() {
        let entries = (0..<8).map { entry(nil, "E\($0)", id: "e\($0)") }
        let ring = RadialLayout.ring(entries: entries, context: .page, custom: nil)
        #expect(ring.count == 8 && !ring.contains { $0.id == RadialLayout.moreID })
    }

    @Test func aCustomRingIsExactlyWhatWasChosenAndTheRestWaitsUnderMore() {
        let entries = [entry(.openLink), entry(.openLinkInNewTab), entry(.openLinkInPeek), entry(.downloadLinkedFile), entry(.copyLink), entry(.share)]
        let ring = RadialLayout.ring(entries: entries, context: .link, custom: [.copyLink, .openLinkInPeek])
        #expect(ring.map(\.id) == ["copyLink", "openLinkInPeek", RadialLayout.moreID])
        #expect(Set(ring.last!.children.map(\.id)) == ["openLink", "openLinkInNewTab", "downloadLinkedFile", "share"])
    }

    @Test func aCustomRingThatUsesEverythingHasNoMore() {
        let entries = [entry(.copyLink), entry(.openLink)]
        let ring = RadialLayout.ring(entries: entries, context: .link, custom: [.openLink, .copyLink])
        #expect(ring.map(\.id) == ["openLink", "copyLink"])
    }

    @Test func aCustomRingNamingNothingOnThisMenuFallsBackToTheDefault() {
        let entries = [entry(.back), entry(.reload)]
        let ring = RadialLayout.ring(entries: entries, context: .page, custom: [.copyLink, .copyImage])
        #expect(ring.map(\.id) == ["back", "reload"], "an empty ring would be a trap")
    }

    @Test func aCustomRingLongerThanTheRingSpillsIntoMore() {
        let entries = RadialAction.allCases.prefix(12).map { entry($0) }
        let ring = RadialLayout.ring(entries: entries, context: .link, custom: Array(RadialAction.allCases.prefix(12)))
        #expect(ring.count == RadialLayout.maxSlices && ring.last?.id == RadialLayout.moreID)
        #expect(ring.dropLast().count + ring.last!.children.count == 12)
    }

    @Test func anEmptyMenuMakesAnEmptyRing() {
        #expect(RadialLayout.ring(entries: [], context: .page, custom: nil).isEmpty)
    }

    // MARK: Geometry

    @Test func sliceZeroIsCentredOnTwelveOClockAndTheRestRunClockwise() {
        // Four slices: top, right, bottom, left.
        func slice(_ x: Double, _ y: Double) -> Int? { RadialGeometry.slice(at: CGPoint(x: x, y: y), count: 4) }
        #expect(slice(0, -90) == 0)
        #expect(slice(90, 0) == 1)
        #expect(slice(0, 90) == 2)
        #expect(slice(-90, 0) == 3)
    }

    @Test func aSliceOwnsHalfAWidthEitherSideOfItsCentre() {
        // Eight slices are 45° wide: 22° either side of straight up is still slice 0, 23° is slice 1.
        func slice(degrees: Double) -> Int? {
            let a = degrees * .pi / 180
            return RadialGeometry.slice(at: CGPoint(x: sin(a) * 90, y: -cos(a) * 90), count: 8)
        }
        #expect(slice(degrees: 0) == 0 && slice(degrees: 22) == 0 && slice(degrees: -22) == 0)
        #expect(slice(degrees: 23) == 1 && slice(degrees: -23) == 7)
        #expect(slice(degrees: 180) == 4)
    }

    @Test func theHubAndTheFarDistanceSelectNothing() {
        #expect(RadialGeometry.slice(at: .zero, count: 6) == nil)
        #expect(RadialGeometry.slice(at: CGPoint(x: 0, y: -(RadialGeometry.innerRadius - 1)), count: 6) == nil)
        #expect(RadialGeometry.slice(at: CGPoint(x: 0, y: -(RadialGeometry.innerRadius + 1)), count: 6) == 0)
        #expect(RadialGeometry.slice(at: CGPoint(x: 0, y: -(RadialGeometry.reach + 5)), count: 6) == nil)
    }

    @Test func aFlickPastTheRingStillSelectsTheSliceItHeadsFor() {
        #expect(RadialGeometry.slice(at: CGPoint(x: 300, y: 0), count: 4) == 1, "well past the outer radius")
    }

    @Test func nonsenseInputSelectsNothing() {
        #expect(RadialGeometry.slice(at: CGPoint(x: Double.nan, y: 0), count: 4) == nil)
        #expect(RadialGeometry.slice(at: CGPoint(x: 90, y: 0), count: 0) == nil)
        #expect(RadialGeometry.slice(at: CGPoint(x: Double.infinity, y: 5), count: 4) == nil)
    }

    @Test func everySliceIsSelectedByItsOwnCentre() {
        for count in 1...8 {
            for index in 0..<count {
                let at = RadialGeometry.offset(of: index, count: count, radius: 88)
                #expect(RadialGeometry.slice(at: at, count: count) == index, "\(index) of \(count)")
            }
        }
    }

    @Test func theRingIsKeptInsideTheWindow() {
        let size = CGSize(width: 1000, height: 700)
        let nearCorner = RadialGeometry.clamp(center: CGPoint(x: 5, y: 5), in: size)
        #expect(nearCorner.x == 12 + RadialGeometry.outerRadius && nearCorner.y == 12 + RadialGeometry.outerRadius)
        let far = RadialGeometry.clamp(center: CGPoint(x: 5000, y: 5000), in: size)
        #expect(far.x == 1000 - 12 - RadialGeometry.outerRadius && far.y == 700 - 12 - RadialGeometry.outerRadius)
        let inside = CGPoint(x: 500, y: 350)
        #expect(RadialGeometry.clamp(center: inside, in: size) == inside)
    }

    @Test func aWindowTooSmallForTheRingGetsItInTheMiddle() {
        #expect(RadialGeometry.clamp(center: CGPoint(x: 10, y: 10), in: CGSize(width: 200, height: 200)) == CGPoint(x: 100, y: 100))
        #expect(RadialGeometry.clamp(center: CGPoint(x: CGFloat.nan, y: 3), in: CGSize(width: 800, height: 600)) == CGPoint(x: 400, y: 300))
    }

    // MARK: Settings

    /// Settings written by another version can name actions this one does not know. The pane and the real ring must agree
    /// that such a list is no choice at all, rather than the pane showing an empty ring the menu then ignores.
    @Test func aListOfUnknownActionsIsNotACustomRing() throws {
        var settings = RadialSettings()
        settings.rings[RadialContext.link.rawValue] = ["flyToTheMoon", "renamedInTheFuture"]
        #expect(settings.customRing(for: .link) == nil)
        #expect(!settings.isCustomised(.link))
        #expect(settings.ring(for: .link) == RadialAction.defaultRing(for: .link))
        settings.setRing([], for: .link)
        #expect(settings.customRing(for: .link) == [], "an empty ring the user made on purpose stays")
        #expect(settings.isCustomised(.link))
    }

    @Test func theRingIsOnEverywhereUntilTurnedOff() {
        var settings = RadialSettings()
        #expect(settings.isActive(on: "example.com") && settings.isActive(on: nil))
        settings.enabled = false
        #expect(!settings.isActive(on: "example.com") && !settings.isActive(on: nil))
    }

    @Test func aSiteCanBeLeftToTheSystemMenu() {
        var settings = RadialSettings()
        let first = settings.disable(host: "https://www.Figma.com/files")
        #expect(first)
        #expect(settings.disabledHosts == ["figma.com"])
        #expect(!settings.isActive(on: "figma.com"))
        #expect(!settings.isActive(on: "www.figma.com") && !settings.isActive(on: "app.figma.com"), "its subdomains too")
        #expect(settings.isActive(on: "notfigma.com") && settings.isActive(on: "example.com"))
        let again = settings.disable(host: "figma.com")
        #expect(!again, "already off")
        let nonsense = settings.disable(host: "not a site")
        #expect(!nonsense)
        settings.enable(host: "www.figma.com")
        #expect(settings.isActive(on: "figma.com"))
    }

    @Test func theEntryThatTurnsASiteOffIsKnown() {
        var settings = RadialSettings()
        _ = settings.disable(host: "google.com")
        #expect(settings.disablingEntry(for: "docs.google.com") == "google.com")
        #expect(settings.disablingEntry(for: "https://www.google.com/search") == "google.com")
        #expect(settings.disablingEntry(for: "example.com") == nil)
        #expect(settings.disablingEntry(for: "not a site") == nil)
    }

    @Test func turningASiteBackOnClearsWhateverTurnedItOff() {
        var settings = RadialSettings()
        _ = settings.disable(host: "google.com")
        _ = settings.disable(host: "example.com")
        // The ring has to work on docs.google.com afterwards, so the entry for the whole of google.com goes.
        settings.enable(host: "docs.google.com")
        #expect(settings.isActive(on: "docs.google.com"))
        #expect(settings.disabledHosts == ["example.com"])
    }

    @Test func aRingIsCustomisedPerContext() {
        var settings = RadialSettings()
        #expect(settings.customRing(for: .link) == nil)
        #expect(settings.ring(for: .link) == RadialAction.defaultRing(for: .link))
        settings.setRing([.copyLink, .openLinkInPeek], for: .link)
        #expect(settings.customRing(for: .link) == [.copyLink, .openLinkInPeek])
        #expect(settings.ring(for: .image) == RadialAction.defaultRing(for: .image), "other contexts are untouched")
        settings.resetRing(for: .link)
        #expect(settings.customRing(for: .link) == nil)
    }

    @Test func settingsSurviveAFileWrittenByAnotherBuild() throws {
        var settings = RadialSettings()
        settings.enabled = false
        _ = settings.disable(host: "example.com")
        settings.setRing([.copy, .paste], for: .editable)
        let back = try JSONDecoder.cosmos.decode(RadialSettings.self, from: JSONEncoder.cosmos.encode(settings))
        #expect(back == settings)

        let odd = Data(#"{"enabled": "yes", "disabledHosts": ["https://A.com/x", "no no", 7], "rings": {"link": ["copyLink", "teleport", "copyLink"]}, "extra": 1}"#.utf8)
        let tolerant = try JSONDecoder.cosmos.decode(RadialSettings.self, from: odd)
        #expect(tolerant.enabled, "a wrong type keeps the default")
        #expect(tolerant.disabledHosts.isEmpty || tolerant.disabledHosts == ["a.com"])
        #expect(tolerant.customRing(for: .link) == [.copyLink], "unknown actions and repeats are dropped")
        #expect(try JSONDecoder.cosmos.decode(RadialSettings.self, from: Data("{}".utf8)) == RadialSettings())
    }

    // MARK: Editing a ring

    @Test func theActionsLeftToAddAreTheOnesForThatContextNotAlreadyOnItsRing() {
        let settings = RadialSettings()
        #expect(settings.available(for: .link) == [.inspect])
        #expect(settings.available(for: .page) == [.openFrameInNewTab])
        for context in RadialContext.allCases {
            let left = settings.available(for: context)
            #expect(left.allSatisfy { $0.contexts.contains(context) })
            #expect(Set(left).isDisjoint(with: Set(settings.ring(for: context))))
        }
    }

    @Test func addingStartsFromTheDefaultRingAndKeepsToTheContext() {
        var settings = RadialSettings()
        let customisedBefore = settings.isCustomised(.image)
        let added = settings.add(.inspect, to: .image)
        let again = settings.add(.inspect, to: .image)
        let wrongContext = settings.add(.paste, to: .image)
        #expect(!customisedBefore)
        #expect(added)
        #expect(settings.isCustomised(.image))
        #expect(settings.ring(for: .image) == RadialAction.defaultRing(for: .image) + [.inspect])
        #expect(!again, "already there")
        #expect(!wrongContext, "a paste slice makes no sense on an image")
        #expect(!settings.isCustomised(.link), "other contexts are untouched")
    }

    @Test func removingKeepsTheRestInOrderButNeverEmptiesARing() {
        var settings = RadialSettings()
        settings.setRing([.copyLink, .openLink, .share], for: .link)
        let removedMiddle = settings.remove(at: 1, from: .link)
        let afterMiddle = settings.ring(for: .link)
        let tooFar = settings.remove(at: 9, from: .link)
        let negative = settings.remove(at: -1, from: .link)
        let removedFirst = settings.remove(at: 0, from: .link)
        let removedLast = settings.remove(at: 0, from: .link)
        #expect(removedMiddle)
        #expect(afterMiddle == [.copyLink, .share])
        #expect(!tooFar && !negative)
        #expect(removedFirst)
        #expect(!removedLast, "a ring with nothing on it would fall back to the default")
        #expect(settings.ring(for: .link) == [.share])
    }

    @Test func movingSwapsWithTheNeighbourAndStopsAtTheEnds() {
        var settings = RadialSettings()
        settings.setRing([.openLink, .copyLink, .share], for: .link)
        let up = settings.move(at: 2, by: -1, in: .link)
        let afterUp = settings.ring(for: .link)
        let pastStart = settings.move(at: 0, by: -1, in: .link)
        let pastEnd = settings.move(at: 2, by: 1, in: .link)
        let missing = settings.move(at: 5, by: 1, in: .link)
        let jump = settings.move(at: 0, by: 2, in: .link)
        #expect(up)
        #expect(afterUp == [.openLink, .share, .copyLink])
        #expect(!pastStart && !pastEnd && !missing)
        #expect(jump)
        #expect(settings.ring(for: .link) == [.share, .copyLink, .openLink])
    }

    @Test func resettingBringsBackTheDefaultAndLeavesTheOthers() {
        var settings = RadialSettings()
        settings.setRing([.copy], for: .selection)
        settings.setRing([.copyLink], for: .link)
        settings.resetRing(for: .selection)
        #expect(!settings.isCustomised(.selection))
        #expect(settings.ring(for: .selection) == RadialAction.defaultRing(for: .selection))
        #expect(settings.isCustomised(.link))
    }

    // MARK: What the Settings preview shows

    @Test func aChosenRingAlwaysHasMoreBecauseTheMenuUsuallyOffersOtherThings() {
        // A ring the user chose is exactly their actions, and everything else the menu offers waits under More: so More
        // is on the ring whenever there is anything else, which is nearly always.
        let few = RadialLayout.preview(of: [.copyLink, .openLink], customised: true)
        #expect(few.shown == [.copyLink, .openLink] && few.hasMore)
        let seven = RadialLayout.preview(of: Array(RadialAction.defaultRing(for: .link).prefix(7)), customised: true)
        #expect(seven.shown.count == 7 && seven.hasMore)
        let eight = RadialLayout.preview(of: [.openLink, .openLinkInNewTab, .openLinkInPeek, .openLinkInSplit, .downloadLinkedFile, .copyLink, .share, .inspect], customised: true)
        #expect(eight.shown.count == RadialLayout.maxSlices - 1 && eight.hasMore, "an eighth action goes under More, as on the real ring")
    }

    @Test func theDefaultRingShowsWhatFitsAndOnlyOverflowsIntoMore() {
        let link = RadialLayout.preview(of: RadialAction.defaultRing(for: .link), customised: false)
        #expect(link.shown.count == 7 && !link.hasMore)
        let nine = RadialLayout.preview(of: Array(RadialAction.allCases.prefix(9)), customised: false)
        #expect(nine.shown.count == RadialLayout.maxSlices - 1 && nine.hasMore)
    }

    @Test func everyPreviewFitsOnARing() {
        for context in RadialContext.allCases {
            for customised in [true, false] {
                let p = RadialLayout.preview(of: RadialAction.defaultRing(for: context), customised: customised)
                #expect(p.shown.count + (p.hasMore ? 1 : 0) <= RadialLayout.maxSlices)
            }
        }
    }

    /// The rows in the editor say which actions sit under More: those past the last visible slice.
    @Test func theActionsPastTheLastSliceAreTheOnesUnderMore() {
        let actions: [RadialAction] = [.openLink, .openLinkInNewTab, .openLinkInPeek, .openLinkInSplit, .downloadLinkedFile, .copyLink, .share, .inspect]
        #expect(RadialLayout.preview(of: actions, customised: true).underMore == [.inspect])
        #expect(RadialLayout.preview(of: [.copyLink], customised: true).underMore.isEmpty)
    }
}
