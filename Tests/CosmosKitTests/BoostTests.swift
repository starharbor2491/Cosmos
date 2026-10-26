import Foundation
import Testing
import WebKit
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

    /// The name only labels console errors, so whatever it holds the Boost's own script must still run.
    @Test(arguments: ["plain", "it's", "back\\slash\\", "two\nlines", "</script>", "quote\"", "\u{2028}"]) func aBoostRunsWhateverItIsCalled(_ name: String) async throws {
        let server = try await PageServer(html: "<p>hello</p>")
        let boost = Boost(name: name, hostPatterns: ["localhost"], js: "document.documentElement.setAttribute('data-boosted', 'yes')")
        let configuration = WKWebViewConfiguration()
        for script in BoostInjector.scripts(for: boost) { configuration.userContentController.addUserScript(script) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = LoadWaiter()
        await waiter.load(try #require(URL(string: "http://localhost:\(server.port)/")), in: web)
        let ran = try await web.evaluateJavaScript("document.documentElement.getAttribute('data-boosted')") as? String
        withExtendedLifetime(waiter) {}
        #expect(ran == "yes")
    }
}
