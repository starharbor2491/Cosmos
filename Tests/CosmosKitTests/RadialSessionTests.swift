import AppKit
import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

/// Stands in for a menu item's target: what a ring slice runs when it is chosen.
@MainActor
final class MenuTarget: NSObject {
    var fired: [String] = []
    @objc func copyLink(_ sender: Any?) { fired.append("copyLink") }
    @objc func openLink(_ sender: Any?) { fired.append("openLink") }
    @objc func spelling(_ sender: Any?) { fired.append("spelling") }
}

@MainActor
enum RadialFixture {
    static func item(_ title: String, id: String? = nil, action: Selector? = nil, target: MenuTarget? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        if let id { item.identifier = NSUserInterfaceItemIdentifier(id) }
        return item
    }

    static func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    /// A link's menu: three actions the default ring knows.
    static func linkMenu(_ target: MenuTarget, openEnabled: Bool = true) -> NSMenu {
        menu([
            item("Open Link", id: "cosmos.openLink", action: #selector(MenuTarget.openLink), target: target, enabled: openEnabled),
            item("Copy Link", id: "cosmos.copyLink", action: #selector(MenuTarget.copyLink), target: target),
        ])
    }

    static func submenuItem(_ title: String, children: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu(children)
        return item
    }

    static func haptics() -> (Haptics, Recorder) {
        let haptics = Haptics()
        let recorder = Recorder()
        haptics.output = { recorder.played.append($0) }
        return (haptics, recorder)
    }

    final class Recorder { var played: [Haptics.Pattern] = [] }
}

@MainActor
@Suite struct RadialMenuBuilderTests {
    @Test func aSystemMenuBecomesEntriesWithSubmenusAsGroups() {
        let target = MenuTarget()
        let menu = RadialFixture.menu([
            RadialFixture.item("Copy Link", id: "cosmos.copyLink", action: #selector(MenuTarget.copyLink), target: target),
            .separator(),
            { let hidden = RadialFixture.item("Hidden", action: #selector(MenuTarget.openLink), target: target); hidden.isHidden = true; return hidden }(),
            RadialFixture.item("  ", action: #selector(MenuTarget.openLink), target: target),
            RadialFixture.submenuItem("Spelling and Grammar", children: [RadialFixture.item("Show Spelling", action: #selector(MenuTarget.spelling), target: target)]),
            RadialFixture.submenuItem("Empty", children: []),
            RadialFixture.item("Copy Link Again", id: "cosmos.copyLink", action: #selector(MenuTarget.copyLink), target: target),
        ])

        let built = RadialMenuBuilder.entries(from: menu)

        #expect(built.entries.map(\.title) == ["Copy Link", "Spelling and Grammar", "Copy Link Again"])
        #expect(built.entries[0].action == .copyLink)
        #expect(built.entries[1].isGroup && built.entries[1].children.map(\.title) == ["Show Spelling"])
        // A second item for an action that is already on the ring is kept, as itself.
        #expect(built.entries[2].action == nil)
        #expect(built.items.count == 3)
    }

    @Test func aDisabledItemStaysOnTheRingButCannotBePicked() {
        let built = RadialMenuBuilder.entries(from: RadialFixture.linkMenu(MenuTarget(), openEnabled: false))
        #expect(built.entries.first { $0.action == .openLink }?.isEnabled == false)
        #expect(built.entries.first { $0.action == .copyLink }?.isEnabled == true)
    }
}

@MainActor
@Suite struct RadialSessionTests {
    private let size = CGSize(width: 800, height: 600)

    private func session(_ menu: NSMenu, context: RadialContext = .link, center: CGPoint = CGPoint(x: 400, y: 300),
                         custom: [RadialAction]? = nil) -> (RadialSession, RadialFixture.Recorder, Counter) {
        _ = NSApplication.shared
        let (haptics, recorder) = RadialFixture.haptics()
        let session = RadialSession(menu: menu, context: context, center: center, windowSize: size, custom: custom, haptics: haptics)
        let counter = Counter()
        session.onFinish = { counter.finished += 1 }
        return (session, recorder, counter)
    }

    final class Counter { var finished = 0 }

    @Test func choosingASliceClosesTheRingThenRunsTheMenuItem() async throws {
        let target = MenuTarget()
        let (session, haptics, counter) = session(RadialFixture.linkMenu(target))
        let index = try #require(session.ring.firstIndex { $0.action == .copyLink })

        session.choose(index)

        #expect(counter.finished == 1)
        #expect(haptics.played == [.levelChange])
        // The action runs on the next turn of the run loop, after the ring is gone.
        #expect(target.fired.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        #expect(target.fired == ["copyLink"])
    }

    @Test func aGroupOpensItsOwnRingAndBackClosesItThenTheMenu() throws {
        let target = MenuTarget()
        let menu = RadialFixture.menu([
            RadialFixture.submenuItem("Spelling and Grammar", children: [RadialFixture.item("Show Spelling", action: #selector(MenuTarget.spelling), target: target)]),
        ])
        let (session, haptics, counter) = session(menu, context: .editable)
        #expect(session.depth == 0)

        session.choose(0)
        #expect(session.depth == 1)
        #expect(session.ring.map(\.title) == ["Show Spelling"])
        #expect(session.levels.last?.title == "Spelling and Grammar")
        #expect(haptics.played == [.alignment])
        #expect(counter.finished == 0)

        session.back()
        #expect(session.depth == 0)
        #expect(counter.finished == 0)
        session.back()
        #expect(counter.finished == 1)
    }

    @Test func aDisabledSliceIsNeitherLitNorChosen() throws {
        let target = MenuTarget()
        let (session, haptics, counter) = session(RadialFixture.linkMenu(target, openEnabled: false))
        let disabled = try #require(session.ring.firstIndex { !$0.isEnabled })

        session.choose(disabled)
        #expect(counter.finished == 0)
        #expect(haptics.played.isEmpty)

        let angle = RadialGeometry.offset(of: disabled, count: session.ring.count, radius: 90)
        session.pointerMoved(to: CGPoint(x: session.center.x + angle.x, y: session.center.y + angle.y))
        #expect(session.hovered == nil)
    }

    @Test func eachSliceTicksOnceAsThePointerEntersIt() throws {
        let target = MenuTarget()
        let (session, haptics, _) = session(RadialFixture.linkMenu(target))
        let count = session.ring.count
        func over(_ index: Int) -> CGPoint {
            let o = RadialGeometry.offset(of: index, count: count, radius: 90)
            return CGPoint(x: session.center.x + o.x, y: session.center.y + o.y)
        }

        session.pointerMoved(to: over(0))
        session.pointerMoved(to: over(0))
        #expect(session.hovered == 0)
        #expect(haptics.played == [.alignment])

        session.pointerMoved(to: over(1))
        #expect(session.hovered == 1)
        #expect(haptics.played == [.alignment, .alignment])

        session.pointerMoved(to: session.center)
        #expect(session.hovered == nil)
        #expect(haptics.played.count == 2)
        #expect(session.isInHub(session.center))
    }

    @Test func aFlickFromAWindowCornerIsReadFromWhereTheClickWas() {
        let target = MenuTarget()
        let (session, _, _) = session(RadialFixture.linkMenu(target), center: CGPoint(x: 10, y: 10))
        // The ring was pushed in from the corner, so its centre is not where the pointer started.
        #expect(session.center != session.origin)
        let up = CGPoint(x: session.origin.x, y: session.origin.y - 90)
        session.pointerMoved(to: up, flickingFromOrigin: true)
        #expect(session.hovered == 0)
        #expect(session.isInHub(CGPoint(x: 12, y: 12), flickingFromOrigin: true))
        #expect(!session.isInHub(CGPoint(x: 12, y: 12)))
    }

    /// The far reach exists for a flick with the button held. A click is a click on the ring or it is a click away.
    @Test func aClickBesideTheRingClosesItInsteadOfChoosingTheSliceInThatDirection() async throws {
        let target = MenuTarget()
        let (session, haptics, counter) = session(RadialFixture.linkMenu(target))
        let outside = CGPoint(x: session.center.x + 250, y: session.center.y)

        session.click(at: outside)

        #expect(counter.finished == 1)
        #expect(haptics.played.isEmpty, "nothing was chosen, so nothing ticks")
        try await Task.sleep(for: .milliseconds(80))
        #expect(target.fired.isEmpty)
    }

    @Test func aClickOnASliceChoosesItAndAClickOnTheHubGoesBack() async throws {
        let target = MenuTarget()
        let (session, _, counter) = session(RadialFixture.linkMenu(target))
        let count = session.ring.count
        let index = try #require(session.ring.firstIndex { $0.action == .copyLink })
        let at = RadialGeometry.offset(of: index, count: count, radius: 90)

        session.click(at: session.center)
        #expect(counter.finished == 1, "the hub of the first ring closes it")

        session.click(at: CGPoint(x: session.center.x + at.x, y: session.center.y + at.y))
        #expect(counter.finished == 2)
        try await Task.sleep(for: .milliseconds(80))
        #expect(target.fired == ["copyLink"])
    }

    @Test func aSliceLightsOnlyUnderThePointerOnTheRingButAFlickReachesFar() {
        let target = MenuTarget()
        let (session, haptics, _) = session(RadialFixture.linkMenu(target))
        let far = CGPoint(x: session.center.x, y: session.center.y - 250)

        session.pointerMoved(to: far)
        #expect(session.hovered == nil, "250 pt away is not on the ring")
        #expect(haptics.played.isEmpty)

        session.pointerMoved(to: CGPoint(x: session.origin.x, y: session.origin.y - 250), flickingFromOrigin: true)
        #expect(session.hovered == 0, "a flick with the button held still reaches")
    }

    @Test func theKeyboardStepsAroundTheEnabledSlicesAndWraps() {
        let target = MenuTarget()
        let menu = RadialFixture.menu([
            RadialFixture.item("Open Link", id: "cosmos.openLink", action: #selector(MenuTarget.openLink), target: target),
            RadialFixture.item("Copy Link", id: "cosmos.copyLink", action: #selector(MenuTarget.copyLink), target: target, enabled: false),
            RadialFixture.item("Open Link in New Tab", id: "cosmos.openLinkInNewTab", action: #selector(MenuTarget.openLink), target: target),
        ])
        let (session, _, _) = session(menu)
        let enabled = session.ring.indices.filter { session.ring[$0].isEnabled }
        #expect(enabled.count == 2)

        session.step(1)
        #expect(session.hovered == enabled.first)
        session.step(1)
        #expect(session.hovered == enabled.last)
        session.step(1)
        #expect(session.hovered == enabled.first)
        session.step(-1)
        #expect(session.hovered == enabled.last)
    }

    @Test func chooseHoveredPicksTheLitSliceAndDoesNothingWithoutOne() {
        let target = MenuTarget()
        let (session, _, counter) = session(RadialFixture.linkMenu(target))
        session.chooseHovered()
        #expect(counter.finished == 0)
        session.step(1)
        session.chooseHovered()
        #expect(counter.finished == 1)
    }

    @Test func aCustomRingIsHonouredAndTheRestWaitsUnderMore() throws {
        let target = MenuTarget()
        let (session, _, _) = session(RadialFixture.linkMenu(target), custom: [.copyLink])
        #expect(session.ring.first?.action == .copyLink)
        let more = try #require(session.ring.last)
        #expect(more.id == RadialLayout.moreID)
        #expect(more.children.map(\.action) == [.openLink])
    }
}

@MainActor
@Suite struct RadialStoreTests {
    private func shown(_ rig: Rig, url: String = "https://example.com/") throws -> TabRuntime {
        _ = NSApplication.shared
        _ = rig.store.newTab(url: URL(string: url), in: rig.window)
        return try #require(rig.store.currentRuntime(in: rig.window))
    }

    private func show(_ rig: Rig, _ runtime: TabRuntime, menu: NSMenu) -> Bool {
        rig.store.tab(runtime, showRadialMenu: menu, context: .link, center: CGPoint(x: 300, y: 200), windowSize: CGSize(width: 800, height: 600))
    }

    @Test func theRingOpensInTheWindowShowingTheTabAndClearsWhenItFinishes() throws {
        let rig = Rig()
        let runtime = try shown(rig)
        #expect(show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        let open = try #require(rig.window.radial)
        #expect(open.context == .link)
        open.finish()
        #expect(rig.window.radial == nil)
    }

    @Test func turnedOffEverywhereTheSystemMenuIsLeftAlone() throws {
        let rig = Rig()
        let runtime = try shown(rig)
        rig.store.settings.radialMenu.enabled = false
        #expect(!show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        #expect(rig.window.radial == nil)
    }

    @Test func aSiteTurnedOffGetsTheSystemMenu() throws {
        let rig = Rig()
        let runtime = try shown(rig, url: "https://quiet.example/")
        runtime.fake.navigate(to: URL(string: "https://quiet.example/")!)
        #expect(runtime.url?.host == "quiet.example")

        #expect(show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        rig.window.radial = nil
        rig.store.settings.radialMenu.disable(host: "quiet.example")
        #expect(!show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        #expect(rig.window.radial == nil)
        rig.store.settings.radialMenu.enable(host: "quiet.example")
        #expect(show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
    }

    /// An incognito window is a store of its own with default settings. What a person chose for the ring (off, off on a
    /// site, their own layout) has to hold there too, or private windows would quietly ignore it.
    @Test func anIncognitoWindowKeepsWhatWasChosenForTheRingAndTheHaptics() {
        let main = Rig()
        main.store.settings.radialMenu.enabled = false
        main.store.settings.radialMenu.disable(host: "example.com")
        main.store.settings.radialMenu.setRing([.copyLink], for: .link)
        main.store.settings.trackpadHaptics = false

        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        #expect(incognito.settings.radialMenu == RadialSettings(), "starts with the defaults")
        incognito.inheritPreferences(from: main.store)

        #expect(incognito.settings.radialMenu == main.store.settings.radialMenu)
        #expect(!incognito.settings.trackpadHaptics)
        #expect(!incognito.haptics.isEnabled)
        #expect(incognito.settings.menuBar == MenuBarSettings(), "nothing about the menu-bar browser or history is copied")
    }

    /// A ring belongs to the page it was opened over. Once the tab, the space or the overlay changes it would act on
    /// something that is no longer in front, and it would keep taking number keys meant for the Command Bar.
    @Test func theRingGoesWhenTheTabTheSpaceOrAnOverlayChanges() throws {
        let rig = Rig(seed: true)
        _ = try shown(rig)
        func openRing() throws {
            let current = try #require(rig.store.currentRuntime(in: rig.window))
            #expect(show(rig, current, menu: RadialFixture.linkMenu(MenuTarget())))
            #expect(rig.window.radial != nil)
        }

        try openRing()
        rig.window.overlay = .commandBar(.newTab)
        #expect(rig.window.radial == nil, "an overlay opened")

        rig.window.overlay = nil
        try openRing()
        _ = rig.store.newTab(url: URL(string: "about:blank?two"), in: rig.window)
        #expect(rig.window.radial == nil, "another tab was selected")

        try openRing()
        let space = try #require(rig.store.workspace.spaces.first { $0.id != rig.window.focusedSpaceID })
        rig.store.switchSpace(to: space.id, in: rig.window)
        #expect(rig.window.radial == nil, "another space came up")
    }

    @Test func theRingGoesWhenItsOwnPageIsReloadedOrLeaves() throws {
        let rig = Rig(seed: true)
        let current = try shown(rig)
        #expect(show(rig, current, menu: RadialFixture.linkMenu(MenuTarget())))
        #expect(rig.window.radial != nil)

        current.pageDidStartNavigation(current.page)

        #expect(rig.window.radial == nil, "the page the ring was made over is going away")
    }

    @Test func longSliceNamesAreShortenedAndTheOthersAreLeftWhole() {
        #expect(RadialMenuView.short("Spelling and Grammar") == "Spelling")
        #expect(RadialMenuView.short("Paragraph Direction") == "Paragraph")
        #expect(RadialMenuView.short("Open Link in New Tab") == "New Tab")
        #expect(RadialMenuView.short("Open Link") == "Open Link")
        #expect(RadialMenuView.short("Copy Link") == "Copy Link")
    }

    @Test func aMenuWithNothingOnItIsLeftToTheSystem() throws {
        let rig = Rig()
        let runtime = try shown(rig)
        let empty = RadialFixture.menu([.separator(), RadialFixture.item("  ")])
        #expect(!show(rig, runtime, menu: empty))
        #expect(rig.window.radial == nil)
    }

    @Test func aTabNoWindowShowsCannotOpenARing() throws {
        let rig = Rig()
        let first = try shown(rig)
        _ = rig.store.newTab(url: URL(string: "https://example.org/"), in: rig.window)
        // The first tab is still alive but no window is showing it.
        #expect(!show(rig, first, menu: RadialFixture.linkMenu(MenuTarget())))
    }
}

@MainActor
@Suite struct RadialPresentationTests {
    /// The runtime's page in a real (never shown) window, with what the page agent reports before a menu is asked for.
    private func rigWithWindow() throws -> (Rig, TabRuntime, NSWindow) {
        _ = NSApplication.shared
        let rig = Rig()
        _ = rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window)
        let runtime = try #require(rig.store.currentRuntime(in: rig.window))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(runtime.view)
        runtime.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return (rig, runtime, window)
    }

    /// What the agent reports on a right click. Marked as handled, so no menu goes up on its own here: each test asks.
    private func report(_ runtime: TabRuntime, _ body: [String: Any]) {
        runtime.handleAgentMessage(["type": "context", "handled": true].merging(body) { $1 }, fromMainFrame: true)
    }

    /// Asks for the ring where the menu for the last right click would go.
    private func present(_ runtime: TabRuntime, _ menu: NSMenu, in window: NSWindow) -> Bool {
        let at = runtime.contextMenuLocation(in: window)
        return runtime.presentRadialMenu(menu, at: at.point, modifiers: at.modifiers)
    }

    private func click(at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> ContextClick {
        ContextClick(location: point, modifiers: flags, uptime: ProcessInfo.processInfo.systemUptime)
    }

    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func theRingOpensWhereThePageSaidTheClickWasAndForWhatWasUnderIt() throws {
        let (rig, runtime, window) = try rigWithWindow()
        report(runtime, ["link": "https://example.com/a", "x": 120.0, "y": 80.0])

        #expect(present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window))

        let open = try #require(rig.window.radial)
        #expect(open.context == .link)
        #expect(open.origin == CGPoint(x: 120, y: 80))
        withExtendedLifetime(window) {}
    }

    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func whatIsUnderThePointerChoosesTheRing() throws {
        let (rig, runtime, window) = try rigWithWindow()
        let menu = RadialFixture.menu([RadialFixture.item("Copy", id: "cosmos.copy", action: #selector(MenuTarget.copyLink), target: MenuTarget())])

        report(runtime, ["selection": "some words", "x": 50.0, "y": 50.0])
        #expect(present(runtime, menu, in: window))
        #expect(rig.window.radial?.context == .selection)

        rig.window.radial = nil
        report(runtime, ["editable": true, "selection": "words", "x": 50.0, "y": 50.0])
        #expect(present(runtime, menu, in: window))
        #expect(rig.window.radial?.context == .editable)
        withExtendedLifetime(window) {}
    }

    /// The ring goes where the click was, read from the click itself. Without one (the keyboard's menu key) the page's
    /// report is used, in its own pixels times the page zoom.
    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func theRingOpensWhereTheClickWasEvenWhenThePageIsZoomed() throws {
        let (rig, runtime, window) = try rigWithWindow()
        runtime.fake.zoom = 2
        report(runtime, ["link": "https://example.com/a", "x": 10.0, "y": 10.0])
        #expect(present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window))
        #expect(rig.window.radial?.origin == CGPoint(x: 20, y: 20), "the page's pixels, zoomed")

        rig.window.radial = nil
        runtime.fake.contextClick = click(at: NSPoint(x: 300, y: 400))
        #expect(present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window))
        #expect(rig.window.radial?.origin == CGPoint(x: 300, y: 600 - 400), "the click, with y turned over for the ring")
        withExtendedLifetime(window) {}
    }

    /// ⌥ is read from the click, not from the keyboard at whatever moment the menu happens to be asked for.
    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func optionHeldOnTheClickAsksForTheSystemMenu() throws {
        let (rig, runtime, window) = try rigWithWindow()
        report(runtime, ["link": "https://example.com/a", "x": 10.0, "y": 10.0])

        runtime.fake.contextClick = click(at: NSPoint(x: 100, y: 100), flags: .option)
        #expect(!present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window), "⌥-click: the system menu")
        #expect(rig.window.radial == nil)

        runtime.fake.contextClick = click(at: NSPoint(x: 100, y: 100))
        #expect(present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window), "a later plain click: the ring")
    }

    /// Peek and Split View carry their link, so a page that moves on while the ring is open does not turn them into
    /// slices that silently do nothing.
    @Test func openInPeekAndSplitKeepTheirLinkWhileThePageMovesOn() throws {
        _ = NSApplication.shared
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        var opened: [(URL, LinkDisposition)] = []
        let runtime = session.prepare()
        let recorder = RecordingHost(store: rig.store) { opened.append(($0, $1)) }
        runtime.host = recorder
        report(runtime, ["link": "https://example.com/target", "x": 5.0, "y": 5.0])
        let menu = runtime.contextMenu()
        report(runtime, ["x": 5.0, "y": 5.0])   // the page moves on: nothing is under the pointer any more

        for id in ["cosmos.openLinkInPeek", "cosmos.openLinkInSplit"] {
            let item = try #require(menu.items.first { $0.identifier?.rawValue == id })
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }
        #expect(opened.map(\.0) == [URL(string: "https://example.com/target")!, URL(string: "https://example.com/target")!])
        #expect(opened.map(\.1) == [.peek, .split])
        withExtendedLifetime(recorder) {}
        session.teardown()
    }

    /// A page can link to a file or a script; Peek and Split are for web pages, as the force-click Peek is.
    @Test(arguments: ["file:///etc/hosts", "javascript:alert(1)", "ftp://example.com/a", "cosmos://settings"])
    func peekAndSplitAreOfferedOnlyForWebLinks(link: String) throws {
        _ = NSApplication.shared
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        report(runtime, ["link": link, "x": 5.0, "y": 5.0])
        let menu = runtime.contextMenu()
        #expect(menu.items.contains { $0.identifier?.rawValue == "cosmos.copyLink" })
        #expect(!menu.items.contains { $0.identifier?.rawValue.hasPrefix("cosmos.openLinkIn") == true })
        #expect(!TabRuntime.isWebLink(URL(string: link)!))
        session.teardown()
    }

    /// Chrome offers an extension's `page` items only when the click is on nothing more particular (a link, an image, a
    /// selection, a field), and `all` items everywhere.
    @Test func anExtensionsPageItemsAreForThePageAloneAndItsAllItemsForEverything() throws {
        _ = NSApplication.shared
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        let recorder = RecordingHost(store: rig.store) { _, _ in }
        recorder.extensionItems = [
            ExtensionMenuItem(extensionID: "e", itemID: "p", title: "Page item", contexts: ["page"]),
            ExtensionMenuItem(extensionID: "e", itemID: "l", title: "Link item", contexts: ["link"]),
            ExtensionMenuItem(extensionID: "e", itemID: "a", title: "Every item", contexts: ["all"]),
        ]
        runtime.host = recorder
        func titles() -> Set<String> { Set(runtime.contextMenu().items.filter { $0.identifier?.rawValue.hasPrefix("extension.") == true }.map(\.title)) }

        report(runtime, ["link": "https://example.com/a", "x": 5.0, "y": 5.0])
        #expect(titles() == ["Link item", "Every item"])
        report(runtime, ["x": 5.0, "y": 5.0])
        #expect(titles() == ["Page item", "Every item"])
        report(runtime, ["selection": "words", "x": 5.0, "y": 5.0])
        #expect(titles() == ["Every item"])
        withExtendedLifetime(recorder) {}
        session.teardown()
    }

    @Test func withoutAWindowOrWhenTurnedOffTheSystemMenuIsUsed() throws {
        let (rig, runtime, window) = try rigWithWindow()
        report(runtime, ["link": "https://example.com/a", "x": 10.0, "y": 10.0])

        rig.store.settings.radialMenu.enabled = false
        #expect(!present(runtime, RadialFixture.linkMenu(MenuTarget()), in: window))
        rig.store.settings.radialMenu.enabled = true

        runtime.view.removeFromSuperview()
        #expect(!runtime.presentRadialMenu(RadialFixture.linkMenu(MenuTarget()), at: NSPoint(x: 10, y: 10), modifiers: []))
        #expect(rig.window.radial == nil)
        withExtendedLifetime(window) {}
    }
}

/// Which key does what while a ring is open. (A `where` on one key of a combined `case` once made only Tab depend on
/// Shift, so Shift-Tab went on to move the focus out from under the ring.)
@Suite struct RadialKeyCommandTests {
    private func command(_ code: UInt16, shift: Bool = false, modified: Bool = false, characters: String? = nil) -> RadialKeyCommand? {
        RadialKeyCommand.from(keyCode: code, shift: shift, otherModifiers: modified, characters: characters)
    }

    @Test func escapeGoesBackAndReturnOrSpaceChoosesTheLitSlice() {
        #expect(command(53) == .back)
        for code: UInt16 in [36, 76, 49] { #expect(command(code) == .chooseHovered) }
    }

    @Test func rightAndDownStepForwardLeftAndUpStepBack() {
        #expect(command(124) == .step(1) && command(125) == .step(1))
        #expect(command(123) == .step(-1) && command(126) == .step(-1))
        // Shift does not change an arrow.
        #expect(command(125, shift: true) == .step(1))
    }

    @Test func tabStepsForwardAndShiftTabBack() {
        #expect(command(48) == .step(1))
        #expect(command(48, shift: true) == .step(-1))
    }

    @Test func aNumberKeyPicksThatSliceUpToEight() {
        for n in 1...8 { #expect(command(0, characters: "\(n)") == .choose(n - 1)) }
        #expect(command(0, characters: "9") == nil)
        #expect(command(0, characters: "0") == nil)
        #expect(command(0, characters: "a") == nil)
        #expect(command(0, characters: nil) == nil)
    }

    @Test func aShortcutWithAModifierIsLeftForWhoeverOwnsIt() {
        #expect(command(0, modified: true, characters: "3") == nil, "⌘3 is not slice 3")
        // ⌥⌘↓, ⌃Tab, ⌘Return and ⌘Esc are the app's own shortcuts, not the ring's arrows, Tab, Return and Esc.
        for code: UInt16 in [123, 124, 125, 126, 48, 36, 76, 49, 53] { #expect(command(code, modified: true) == nil, "key \(code) with ⌘, ⌃ or ⌥") }
        #expect(command(48, shift: true, modified: true) == nil)
    }

    /// A trackpad sends scroll events that move nothing (a finger resting down, one cancelled) and momentum events after a
    /// flick. Only a scroll that moves the page is a reason to put the ring away.
    @Test func onlyAScrollThatActuallyMovesThePageClosesTheRing() {
        #expect(RadialInput.scroll(deltaX: 0, deltaY: 12, momentum: false) == .scroll)
        #expect(RadialInput.scroll(deltaX: -4, deltaY: 0, momentum: false) == .scroll)
        #expect(RadialInput.scroll(deltaX: 0, deltaY: 0, momentum: false) == nil, "a phase-only event")
        #expect(RadialInput.scroll(deltaX: 0, deltaY: 30, momentum: true) == nil, "the tail of an earlier flick")
    }
}

/// What the ring does with the mouse and keys it is given while it is open. (The AppKit monitor only turns events into
/// these; none of this was reachable from the automation harness, which sends events around the monitors.)
@MainActor
@Suite struct RadialInputTests {
    private func open(_ target: MenuTarget) -> (RadialSession, RadialFixture.Recorder, RadialSessionTests.Counter) {
        _ = NSApplication.shared
        let (haptics, recorder) = RadialFixture.haptics()
        let session = RadialSession(menu: RadialFixture.linkMenu(target), context: .link, center: CGPoint(x: 400, y: 300), windowSize: CGSize(width: 800, height: 600), custom: nil, haptics: haptics)
        let counter = RadialSessionTests.Counter()
        session.onFinish = { counter.finished += 1 }
        return (session, recorder, counter)
    }

    private func over(_ index: Int, of session: RadialSession, radius: Double = 90) -> CGPoint {
        let o = RadialGeometry.offset(of: index, count: session.ring.count, radius: radius)
        return CGPoint(x: session.origin.x + o.x, y: session.origin.y + o.y)
    }

    @Test func lettingGoOfTheButtonOverASliceChoosesItAndTheEventGoesOn() async throws {
        let target = MenuTarget()
        let (session, _, counter) = open(target)
        let index = try #require(session.ring.firstIndex { $0.action == .copyLink })

        #expect(!session.receive(.rightDragged(over(index, of: session))))
        #expect(session.hovered == index)
        #expect(!session.receive(.rightUp(over(index, of: session))), "the release is not consumed")
        #expect(counter.finished == 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(target.fired == ["copyLink"])
    }

    @Test func lettingGoInTheHubLeavesTheRingOpenForAClick() {
        let (session, _, counter) = open(MenuTarget())
        _ = session.receive(.rightUp(session.origin))
        #expect(counter.finished == 0)
        #expect(!session.buttonIsDown)
        // A second release (the button of a later click) is not the one that opened it.
        _ = session.receive(.rightUp(over(0, of: session)))
        #expect(counter.finished == 0)
    }

    @Test func aFlickPastTheRingStillChoosesOnRelease() async throws {
        let target = MenuTarget()
        let (session, _, counter) = open(target)
        let index = try #require(session.ring.firstIndex { $0.action == .copyLink })
        let far = over(index, of: session, radius: 300)
        _ = session.receive(.rightDragged(far))
        _ = session.receive(.rightUp(far))
        #expect(counter.finished == 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(target.fired == ["copyLink"])
    }

    @Test func aNewRightClickOrAScrollPutsTheRingAway() {
        let (first, _, firstCounter) = open(MenuTarget())
        #expect(first.receive(.rightDown), "the click that closes it is used up, so it does not open another menu on top")
        #expect(firstCounter.finished == 1)
        let (second, _, secondCounter) = open(MenuTarget())
        #expect(!second.receive(.scroll))
        #expect(secondCounter.finished == 1)
    }

    @Test func returnPicksOnlyWhatIsLitAndOtherwiseIsNotTheRings() {
        let (session, _, counter) = open(MenuTarget())
        #expect(!session.receive(.key(.chooseHovered)), "nothing lit: Return and Space go to whoever they were for")
        #expect(counter.finished == 0)
        #expect(session.receive(.key(.step(1))))
        #expect(session.receive(.key(.chooseHovered)))
        #expect(counter.finished == 1)
    }

    @Test func numberKeysPickAndEscapeGoesBack() {
        let (session, _, counter) = open(MenuTarget())
        #expect(session.receive(.key(.choose(1))))
        #expect(counter.finished == 1)
        let (other, _, otherCounter) = open(MenuTarget())
        #expect(other.receive(.key(.back)))
        #expect(otherCounter.finished == 1)
    }
}

/// A host that only notes what pages ask it to open, with extension menu items a test sets.
@MainActor
private final class RecordingHost: TabHost {
    private let store: BrowserStore
    private let note: (URL, LinkDisposition) -> Void
    var extensionItems: [ExtensionMenuItem] = []
    init(store: BrowserStore, note: @escaping (URL, LinkDisposition) -> Void) { self.store = store; self.note = note }
    var settings: Settings { store.settings }
    var favicons: FaviconStore { store.favicons }
    var downloads: DownloadsManager { store.downloads }
    var isDraggingSidebarItem: Bool { false }
    func tabDidChange(_ tab: TabRuntime) {}
    func tabDidFinishLoading(_ tab: TabRuntime) {}
    func tabIsPinnedOrFavorite(_ tab: TabRuntime) -> Bool { false }
    func tab(_ tab: TabRuntime, open url: URL, as disposition: LinkDisposition) { note(url, disposition) }
    func tab(_ tab: TabRuntime, didOpen page: EnginePage, request: NewPageRequest) -> Bool { false }
    func tabRequestsClose(_ tab: TabRuntime) {}
    func tabRequestsEscape(_ tab: TabRuntime) {}
    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double? { nil }
    func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String) {}
    func tab(_ tab: TabRuntime, showRadialMenu menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize) -> Bool { false }
    func extensionMenuItems(for tab: TabRuntime, contexts: Set<String>) -> [ExtensionMenuItem] {
        extensionItems.filter { !contexts.isDisjoint(with: $0.contexts) }
    }
}

/// Who has the keyboard: the page in front, again once a panel over it (the Command Bar) has closed.
@MainActor
@Suite struct PageFocusTests {
    @Test func thePageHasTheKeyboardAgainWhenAPanelOverItCloses() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let content = try #require(window.contentView)
        let host = WebContentHostView(frame: content.bounds)
        content.addSubview(host)
        let runtime = TabRuntime(itemID: UUID(), profileID: nil, page: FakePage(), host: nil)
        func update(focus: Bool) async throws {
            host.update(panes: [.init(runtime: runtime, isFocused: true)], orientation: .horizontal, weights: [1], accent: .systemPink, wantsFocus: focus)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await update(focus: true)
        #expect(window.firstResponder === runtime.view)

        try await update(focus: false)           // the Command Bar opens, and its field takes the keyboard
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        content.addSubview(field)
        window.makeFirstResponder(field)
        field.removeFromSuperview()              // it closes
        try await update(focus: true)
        #expect(window.firstResponder === runtime.view)
    }
}
