import Testing
@testable import CosmosCore

/// A sky's stars are drawn from a seed taken from the theme's name, so the same space looks the same every launch.
/// Swift's `hashValue` changes on every launch and can't be used for that.
@Suite struct ThemeSeedTests {
    @Test func theSeedIsAFixedFunctionOfTheName() {
        // FNV-1a over the UTF-8 bytes; these constants are what any build of the app must produce.
        #expect(SpaceTheme.nebula.starSeed == 0x84c72c1c19f774c6)
        #expect(SpaceTheme.aurora.starSeed == 0x756bb304f4a88ca1)
    }

    @Test func eachPresetHasItsOwnSky() {
        let seeds = Set(SpaceTheme.presets.map(\.starSeed))
        #expect(seeds.count == SpaceTheme.presets.count)
    }

    @Test func renamingChangesTheSky() {
        var theme = SpaceTheme.nebula
        let before = theme.starSeed
        theme.name = "Nebula 2"
        #expect(theme.starSeed != before)
    }
}
