import AppKit
import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

/// Stands in for WebKit's menu target: what a ring slice runs when it is chosen.
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
            item("Open Link", id: "WKMenuItemIdentifierOpenLink", action: #selector(MenuTarget.openLink), target: target, enabled: openEnabled),
            item("Copy Link", id: "WKMenuItemIdentifierCopyLink", action: #selector(MenuTarget.copyLink), target: target),
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
            RadialFixture.item("Copy Link", id: "WKMenuItemIdentifierCopyLink", action: #selector(MenuTarget.copyLink), target: target),
            .separator(),
            { let hidden = RadialFixture.item("Hidden", action: #selector(MenuTarget.openLink), target: target); hidden.isHidden = true; return hidden }(),
            RadialFixture.item("  ", action: #selector(MenuTarget.openLink), target: target),
            RadialFixture.submenuItem("Spelling and Grammar", children: [RadialFixture.item("Show Spelling", action: #selector(MenuTarget.spelling), target: target)]),
            RadialFixture.submenuItem("Empty", children: []),
            RadialFixture.item("Copy Link Again", id: "WKMenuItemIdentifierCopyLink", action: #selector(MenuTarget.copyLink), target: target),
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

    @Test func theKeyboardStepsAroundTheEnabledSlicesAndWraps() {
        let target = MenuTarget()
        let menu = RadialFixture.menu([
            RadialFixture.item("Open Link", id: "WKMenuItemIdentifierOpenLink", action: #selector(MenuTarget.openLink), target: target),
            RadialFixture.item("Copy Link", id: "WKMenuItemIdentifierCopyLink", action: #selector(MenuTarget.copyLink), target: target, enabled: false),
            RadialFixture.item("Open Link in New Tab", id: "WKMenuItemIdentifierOpenLinkInNewWindow", action: #selector(MenuTarget.openLink), target: target),
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

    @Test func aSiteTurnedOffGetsTheSystemMenu() async throws {
        let rig = Rig()
        let page = try await PageServer(html: "<html><body>hello</body></html>")
        let runtime = try shown(rig, url: "about:blank")
        runtime.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(page.port)/")!))
        for _ in 0..<150 where runtime.webView.url?.host != "127.0.0.1" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(runtime.webView.url?.host == "127.0.0.1")

        #expect(show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        rig.window.radial = nil
        rig.store.settings.radialMenu.disable(host: "127.0.0.1")
        #expect(!show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
        #expect(rig.window.radial == nil)
        rig.store.settings.radialMenu.enable(host: "127.0.0.1")
        #expect(show(rig, runtime, menu: RadialFixture.linkMenu(MenuTarget())))
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
    /// The runtime's web view in a real (never shown) window, with what the page agent reports before a menu is asked for.
    private func rigWithWindow() throws -> (Rig, TabRuntime, NSWindow) {
        _ = NSApplication.shared
        let rig = Rig()
        _ = rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window)
        let runtime = try #require(rig.store.currentRuntime(in: rig.window))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(runtime.webView)
        runtime.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return (rig, runtime, window)
    }

    private func report(_ runtime: TabRuntime, _ body: [String: Any]) {
        runtime.handleAgentMessage(["type": "context"].merging(body) { $1 }, fromMainFrame: true)
    }

    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func theRingOpensWhereThePageSaidTheClickWasAndForWhatWasUnderIt() throws {
        let (rig, runtime, window) = try rigWithWindow()
        report(runtime, ["link": "https://example.com/a", "x": 120.0, "y": 80.0])

        #expect(runtime.presentRadialMenu(RadialFixture.linkMenu(MenuTarget())))

        let open = try #require(rig.window.radial)
        #expect(open.context == .link)
        #expect(open.origin == CGPoint(x: 120, y: 80))
        withExtendedLifetime(window) {}
    }

    @Test(.disabled(if: NSWorkspace.shared.isVoiceOverEnabled, "the ring steps aside for VoiceOver, on purpose"))
    func whatIsUnderThePointerChoosesTheRing() throws {
        let (rig, runtime, window) = try rigWithWindow()
        let menu = RadialFixture.menu([RadialFixture.item("Copy", id: "WKMenuItemIdentifierCopy", action: #selector(MenuTarget.copyLink), target: MenuTarget())])

        report(runtime, ["selection": "some words", "x": 50.0, "y": 50.0])
        #expect(runtime.presentRadialMenu(menu))
        #expect(rig.window.radial?.context == .selection)

        rig.window.radial = nil
        report(runtime, ["editable": true, "selection": "words", "x": 50.0, "y": 50.0])
        #expect(runtime.presentRadialMenu(menu))
        #expect(rig.window.radial?.context == .editable)
        withExtendedLifetime(window) {}
    }

    @Test func withoutAWindowOrWhenTurnedOffTheSystemMenuIsUsed() throws {
        let (rig, runtime, window) = try rigWithWindow()
        report(runtime, ["link": "https://example.com/a", "x": 10.0, "y": 10.0])

        rig.store.settings.radialMenu.enabled = false
        #expect(!runtime.presentRadialMenu(RadialFixture.linkMenu(MenuTarget())))
        rig.store.settings.radialMenu.enabled = true

        runtime.webView.removeFromSuperview()
        #expect(!runtime.presentRadialMenu(RadialFixture.linkMenu(MenuTarget())))
        #expect(rig.window.radial == nil)
        withExtendedLifetime(window) {}
    }
}
