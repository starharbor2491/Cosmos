import Foundation
import Testing
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
}
