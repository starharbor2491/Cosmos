import Foundation
import Testing
@testable import CosmosCore

@Suite struct LegibilityTests {
    @Test func contrastMatchesTheWCAGDefinition() {
        #expect(abs(Legibility.contrast(RGBA(0, 0, 0), RGBA(1, 1, 1)) - 21) < 0.001)
        #expect(abs(Legibility.contrast(RGBA(1, 1, 1), RGBA(1, 1, 1)) - 1) < 0.001)
        // #767676 on white is the textbook 4.54:1.
        #expect(abs(Legibility.contrast(RGBA(hex: 0x767676), RGBA(1, 1, 1)) - 4.54) < 0.01)
    }

    @Test func compositingIsAnAlphaBlend() {
        let blended = Legibility.composite(RGBA(1, 1, 1, 0.5), over: RGBA(0, 0, 0))
        #expect(abs(blended.r - 0.5) < 1e-9 && abs(blended.g - 0.5) < 1e-9 && blended.a == 1)
    }

    /// The reason the model exists: the presets, as written, have stops white text cannot be read on.
    @Test func someAuthoredThemesFailUntilTheyAreAdjusted() {
        let failing = SpaceTheme.presets.filter { theme in
            theme.colors.contains { Legibility.margin(of: $0, lightInk: theme.prefersLightForeground) < 1 }
        }
        #expect(!failing.isEmpty)
    }

    @Test(arguments: SpaceTheme.presets) func everyPresetIsReadableOnEveryStopAfterAdjusting(theme: SpaceTheme) {
        let light = theme.prefersLightForeground
        for stop in theme.legible.colors {
            for (name, role) in [("primary", Legibility.primary), ("secondary", Legibility.secondary), ("tertiary", Legibility.tertiary)] {
                for surface in [nil, Legibility.hover(lightInk: light), Legibility.hoverStrong(lightInk: light), Legibility.selected(lightInk: light)] {
                    if role.alpha == Legibility.tertiary.alpha, surface == Legibility.selected(lightInk: light) { continue }
                    let ratio = Legibility.ratio(role, lightInk: light, over: stop, surface: surface)
                    #expect(ratio >= role.minimum - 0.02, "\(theme.name) \(name) on \(String(describing: surface)): \(ratio)")
                }
            }
            #expect(Legibility.ratio(Legibility.faint, lightInk: light, over: stop) >= 2.98, "\(theme.name) faint glyphs")
        }
    }

    @Test func aThemeThatAlreadyReadsIsLeftAlone() {
        let theme = SpaceTheme(name: "Night", colors: [RGBA(hex: 0x0B0B0F), RGBA(hex: 0x101018), RGBA(hex: 0x1C1C2A)])
        #expect(theme.legible.colors == theme.colors)
        let dark = RGBA(hex: 0x101018)
        #expect(Legibility.background(dark, lightInk: true) == dark)
    }

    @Test func adjustingChangesLightnessAndKeepsTheHue() {
        let yellow = RGBA(hex: 0xFBBF24)
        let adjusted = Legibility.background(yellow, lightInk: true)
        #expect(adjusted.luminance < yellow.luminance)
        // Mixing with black scales every channel by the same factor, so the hue and saturation do not move.
        #expect(abs(adjusted.hsb.h - yellow.hsb.h) < 0.01 && abs(adjusted.hsb.s - yellow.hsb.s) < 0.01)
        #expect(Legibility.margin(of: adjusted, lightInk: true) >= 0.999)
    }

    @Test func adjustingNeverLeavesAThemeWorseOff() {
        // Any colour, either ink: the result passes, and is no farther from the original than the anchor is.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let c = RGBA(.random(in: 0...1, using: &rng), .random(in: 0...1, using: &rng), .random(in: 0...1, using: &rng))
            for light in [true, false] {
                let out = Legibility.background(c, lightInk: light)
                #expect(Legibility.margin(of: out, lightInk: light) >= 0.995, "\(c) light=\(light)")
                #expect(light ? out.luminance <= c.luminance + 1e-9 : out.luminance >= c.luminance - 1e-9)
            }
        }
    }

    @Test func aFilledControlCarriesALabelThatReadsOnIt() {
        for hex: UInt32 in [0xFBBF24, 0x67E8F9, 0x7BE0A6, 0xE0568D, 0x3B5BDB, 0xFFFFFF, 0x000000, 0x808080, 0x9A9A9A, 0xFFC48A] {
            let (fill, label) = Legibility.filled(RGBA(hex: hex))
            #expect(Legibility.contrast(label, fill) >= 4.49, "\(hex)")
        }
    }

    @Test func anAccentJustShortOfReadingWithWhiteStaysWhiteAndDarkensALittle() {
        // Nebula's pink: white on it is 4.1:1, dark ink 4.7:1, but a button is expected to carry white text.
        let pink = RGBA(hex: 0xD2547E)
        #expect(Legibility.contrast(Legibility.white, pink) < 4.5)
        let (fill, label) = Legibility.filled(pink)
        #expect(label == Legibility.white)
        #expect(fill.luminance >= pink.luminance * 0.85, "a small change, not a different colour")
        #expect(Legibility.contrast(label, fill) >= 4.49)
    }

    @Test func aBrightAccentGetsADarkLabelAndStaysBright() {
        let orange = RGBA(hex: 0xFFC48A)
        let (fill, label) = Legibility.filled(orange)
        #expect(label == Legibility.ink)
        #expect(fill == orange)
        let navy = RGBA(hex: 0x14246B)
        #expect(Legibility.filled(navy).label == Legibility.white)
        #expect(Legibility.filled(navy).fill == navy)
    }

    @Test func statusColoursAreMovedUntilTheyReadOnTheTheme() {
        let green = RGBA(0.2, 0.8, 0.4)
        for theme in SpaceTheme.presets {
            let ground = theme.worstStop
            #expect(Legibility.contrast(Legibility.foreground(green, on: ground), ground) >= 4.49, "\(theme.name)")
        }
    }

    @Test func aDamagedThemeStillGetsAnAnswer() {
        var odd = SpaceTheme(name: "Odd", colors: [RGBA(2, -1, .nan)])
        odd.colors = [RGBA(0.5, 0.5, 0.5, 0)]
        _ = odd.legible
        _ = odd.worstStop
    }
}
