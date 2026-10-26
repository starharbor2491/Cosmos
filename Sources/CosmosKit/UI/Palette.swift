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
    /// The quietest text (hints, timestamps): 3:1, see `Legibility`.
    let tertiary: Color
    /// The hint in an empty text field the system draws, solid because it cannot draw a translucent one.
    let placeholder: Color
    /// Strokes, outlines and glyphs that are not text.
    let faint: Color
    let hover: Color
    /// A control under the pointer.
    let hoverStrong: Color
    let selected: Color
    let stroke: Color
    let accent: Color
    let accentRaw: RGBA
    /// The accent as a fill (primary buttons, switch tracks) and the colour of what sits on it.
    let accentFill: Color
    let onAccent: Color
    /// The accent as text (4.5:1) and as a glyph (3:1) on a panel.
    let accentText: Color
    let accentGlyph: Color
    /// Status text that reads on this theme.
    let positive: Color
    let negative: Color
    let warning: Color
    /// A solid-ish panel colour for popovers and the command bar.
    let panel: Color
    let shadow: Color

    init(theme: SpaceTheme) {
        let dark = theme.prefersLightForeground
        isDark = dark
        let base = Color(dark ? Legibility.white : Legibility.ink)
        text = base.opacity(Legibility.primary.alpha)
        secondary = base.opacity(Legibility.secondary.alpha)
        tertiary = base.opacity(Legibility.tertiary.alpha)
        placeholder = Color(Legibility.placeholder(lightInk: dark))
        faint = base.opacity(Legibility.faint.alpha)
        hover = Color(Legibility.hover(lightInk: dark))
        hoverStrong = Color(Legibility.hoverStrong(lightInk: dark))
        selected = Color(Legibility.selected(lightInk: dark))
        stroke = base.opacity(dark ? 0.14 : 0.12)
        accentRaw = theme.accent
        accent = Color(theme.accent).opacity(1)
        let filled = Legibility.filled(theme.accent)
        accentFill = Color(filled.fill)
        onAccent = Color(filled.label)
        let ground = theme.worstStop
        accentText = Color(theme.accent(onPanelMinimum: 4.5))
        accentGlyph = Color(theme.accent(onPanelMinimum: 3))
        positive = Color(Legibility.foreground(RGBA(0.30, 0.85, 0.45), on: ground))
        negative = Color(Legibility.foreground(RGBA(1, 0.42, 0.40), on: ground))
        warning = Color(Legibility.foreground(RGBA(1, 0.62, 0.20), on: ground))
        panel = Color(Legibility.panelTint(lightInk: dark))
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
