import SwiftUI
import AppKit
import CosmosCore

extension Color {
    init(_ c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

extension NSColor {
    convenience init(_ c: RGBA) { self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
}

/// Colours for chrome drawn over a space's theme. Derived from the theme (not the system appearance) so the sidebar
/// is legible on a bright "Solstice" gradient and a dark "Deep Field" alike.
struct Palette {
    let isDark: Bool
    let text: Color
    let secondary: Color
    let tertiary: Color
    let hover: Color
    let selected: Color
    let stroke: Color
    let accent: Color
    let accentRaw: RGBA
    /// A solid-ish panel colour for popovers and the command bar.
    let panel: Color
    let shadow: Color

    init(theme: SpaceTheme) {
        let dark = theme.prefersLightForeground
        isDark = dark
        let base: Color = dark ? .white : Color(red: 0.08, green: 0.07, blue: 0.14)
        text = base.opacity(0.94)
        secondary = base.opacity(0.66)
        tertiary = base.opacity(0.42)
        hover = base.opacity(dark ? 0.10 : 0.07)
        selected = dark ? Color.white.opacity(0.20) : Color.white.opacity(0.62)
        stroke = base.opacity(dark ? 0.14 : 0.12)
        accentRaw = theme.accent
        accent = Color(theme.accent).opacity(1)
        panel = dark ? Color(red: 0.07, green: 0.06, blue: 0.14).opacity(0.72) : Color.white.opacity(0.74)
        shadow = Color.black.opacity(dark ? 0.45 : 0.18)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(theme: .nebula)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
