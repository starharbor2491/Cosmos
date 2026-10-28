import Foundation
import Testing
import JavaScriptCore
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct BoostInjectorTests {
    @Test func styleSheetCombinesFilterFontZapAndCSS() {
        let b = Boost(name: "t", hostPatterns: ["example.com"], css: "p { color: red }", zapSelectors: ["#ad", ".banner"],
                      colorFilter: ColorFilter(hue: 30, invert: true), fontFamily: "Georgia")
        let css = BoostInjector.styleSheet(for: b)
        #expect(css.contains("invert(1)"))
        #expect(css.contains("hue-rotate(30deg)"))
        #expect(css.contains("\"Georgia\""))
        #expect(css.contains("#ad,\n.banner { display: none !important; }"))
        #expect(css.hasSuffix("p { color: red }"))
    }

    @Test func anEmptyBoostInjectsNothing() {
        let b = Boost(name: "t", hostPatterns: ["example.com"])
        #expect(BoostInjector.styleSheet(for: b).isEmpty)
        #expect(BoostInjector.scripts(for: b).isEmpty)
    }

    @Test func fontNamesCannotBreakOutOfTheRule() {
        let b = Boost(name: "t", hostPatterns: ["x.com"], fontFamily: "Evil\"; } body { display: none")
        let css = BoostInjector.styleSheet(for: b)
        #expect(!css.contains("\"; }"))
    }

    @Test func jsLiteralsEscapeTerminatorsAndQuotes() {
        let lit = BoostInjector.jsString("a\"b\u{2028}c</script>")
        #expect(lit.hasPrefix("\"") && lit.hasSuffix("\""))
        #expect(!lit.contains("\u{2028}"))
    }

    @Test func scriptsAreGuardedByHostPatterns() {
        let b = Boost(name: "t", hostPatterns: ["*.example.com"], css: "a{}", js: "1+1")
        let scripts = BoostInjector.scripts(for: b)
        #expect(scripts.count == 2)
        #expect(scripts.allSatisfy { $0.source.contains("example.com") })
    }

    @Test func aBoostZoomIsHeldToTheRangeTheKeysUse() {
        #expect(TabRuntime.clampedZoom(0) == 0.25)
        #expect(TabRuntime.clampedZoom(-3) == 0.25)
        #expect(TabRuntime.clampedZoom(1e9) == 5)
        #expect(TabRuntime.clampedZoom(.nan) == 1)
        #expect(TabRuntime.clampedZoom(1.5) == 1.5)
    }

    /// Runs page scripts the way a page on `host` would, in JavaScriptCore with just enough of a document.
    private func run(_ scripts: [PageScript], on host: String) -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var location = { hostname: \(BoostInjector.jsString(host)) };
        var attributes = {}, styles = {};
        var root = { setAttribute: function (k, v) { attributes[k] = v; }, appendChild: function (s) { styles[s.id] = s.textContent; } };
        var document = { documentElement: root, head: null, getElementById: function () { return null; }, createElement: function () { return {}; } };
        var console = { error: function () { throw new Error('the Boost failed'); } };
        """)
        for script in scripts { context.evaluateScript(script.source) }
        return context
    }

    /// The name only labels console errors, so whatever it holds the Boost's own script must still run.
    @Test(arguments: ["plain", "it's", "back\\slash\\", "two\nlines", "</script>", "quote\"", "\u{2028}"]) func aBoostRunsWhateverItIsCalled(_ name: String) {
        let boost = Boost(name: name, hostPatterns: ["localhost"], js: "document.documentElement.setAttribute('data-boosted', 'yes')")
        let context = run(BoostInjector.scripts(for: boost), on: "localhost")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("attributes['data-boosted']").toString() == "yes")
    }

    @Test(arguments: [("example.com", "example.com", true), ("example.com", "www.example.com", true), ("example.com", "news.example.com", true),
                      ("example.com", "notexample.com", false), ("*.example.com", "news.example.com", true), ("*.example.com", "example.com", false),
                      ("https://Example.com/path", "example.com", true), ("*", "anything.test", true)])
    func aBoostRunsOnlyOnItsSites(_ pattern: String, _ host: String, _ runs: Bool) {
        let boost = Boost(name: "t", hostPatterns: [pattern], css: "p { color: red }", js: "document.documentElement.setAttribute('data-boosted', 'yes')")
        let context = run(BoostInjector.scripts(for: boost), on: host)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("attributes['data-boosted'] === 'yes'").toBool() == runs)
        #expect(context.evaluateScript("Object.keys(styles).length").toInt32() == (runs ? 1 : 0))
    }

    /// At document start Chromium has no root element yet: the style waits for it instead of failing.
    @Test func aStyleWaitsForTheDocumentsRootElement() {
        let boost = Boost(name: "t", hostPatterns: ["a.com"], css: "p { color: red }")
        let context = JSContext()!
        context.evaluateScript("""
        var location = { hostname: 'a.com' };
        var styles = {}, observers = [];
        var root = { appendChild: function (s) { styles[s.id] = s.textContent; } };
        var document = { documentElement: null, head: null, getElementById: function () { return null; }, createElement: function () { return {}; } };
        function MutationObserver(callback) { this.callback = callback; this.on = false; }
        MutationObserver.prototype.observe = function () { this.on = true; observers.push(this); };
        MutationObserver.prototype.disconnect = function () { this.on = false; };
        """)
        for script in BoostInjector.scripts(for: boost) { context.evaluateScript(script.source) }
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.keys(styles).length").toInt32() == 0)
        context.evaluateScript("document.documentElement = root; observers.forEach(function (o) { if (o.on) o.callback([], o); });")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.keys(styles).length").toInt32() == 1)
        #expect(context.evaluateScript("observers.every(function (o) { return !o.on; })").toBool(), "it stops watching once it is in")
    }

    /// Styles go in before the page draws and scripts once it is there; both run in the page's world (the agent's world
    /// is Cosmos's own).
    @Test func stylesRunAtTheStartAndScriptsAtTheEndInThePagesWorld() {
        let scripts = BoostInjector.scripts(for: Boost(name: "t", hostPatterns: ["a.com"], css: "p{}", js: "1"))
        #expect(scripts.map(\.time) == [.documentStart, .documentEnd])
        #expect(scripts.allSatisfy { $0.world == .page })
    }

    /// Every page gets the agent first, then the Boosts that are on and belong to its profile (or to every profile).
    @Test func aProfileGetsTheAgentThenItsOwnBoosts() throws {
        let rig = Rig()
        let profile = rig.store.workspace.profiles[0].id
        rig.store.boosts = BoostLibrary(boosts: [
            Boost(name: "mine", hostPatterns: ["a.com"], css: ".mine{}", profileID: profile),
            Boost(name: "everyone", hostPatterns: ["a.com"], css: ".everyone{}"),
            Boost(name: "off", isEnabled: false, hostPatterns: ["a.com"], css: ".off{}"),
            Boost(name: "theirs", hostPatterns: ["a.com"], css: ".theirs{}", profileID: UUID()),
        ])
        _ = rig.store.environment(forProfile: profile)
        let scripts = try #require(rig.store.fakeEngine.profiles.first?.scripts)
        #expect(scripts.first == PageScript(source: ProfileEnvironment.agentSource, world: .agent, time: .documentStart))
        #expect(!ProfileEnvironment.agentSource.isEmpty)
        let rest = scripts.dropFirst().map(\.source).joined()
        #expect(rest.contains(".mine{}") && rest.contains(".everyone{}"))
        #expect(!rest.contains(".off{}") && !rest.contains(".theirs{}"))
    }
}
