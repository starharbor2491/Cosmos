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
}
