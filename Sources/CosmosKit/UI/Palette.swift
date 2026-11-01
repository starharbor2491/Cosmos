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

    init(theme: SpaceTheme) { self.init(Inks(theme: theme)) }

    /// `t` of the way from `a`'s colours to `b`'s: the window while the sidebar slides from one space to the other. The
    /// light or dark half (`isDark`) is the nearer one's.
    init(theme a: SpaceTheme, _ b: SpaceTheme, t: Double) {
        self.init(Inks(theme: a).mixed(with: Inks(theme: b), t))
    }

    private init(_ inks: Inks) {
        isDark = inks.isDark
        text = Color(inks.text); secondary = Color(inks.secondary); tertiary = Color(inks.tertiary)
        placeholder = Color(inks.placeholder); faint = Color(inks.faint)
        hover = Color(inks.hover); hoverStrong = Color(inks.hoverStrong); selected = Color(inks.selected); stroke = Color(inks.stroke)
        accentRaw = inks.accent; accent = Color(inks.accent)
        accentFill = Color(inks.accentFill); onAccent = Color(inks.onAccent)
        accentText = Color(inks.accentText); accentGlyph = Color(inks.accentGlyph)
        positive = Color(inks.positive); negative = Color(inks.negative); warning = Color(inks.warning)
        panel = Color(inks.panel); shadow = Color(inks.shadow)
    }

    /// The palette's colours as numbers, so two can be mixed.
    struct Inks: Equatable {
        var isDark: Bool
        var text, secondary, tertiary, placeholder, faint, hover, hoverStrong, selected, stroke: RGBA
        var accent, accentFill, onAccent, accentText, accentGlyph, positive, negative, warning, panel, shadow: RGBA

        init(theme: SpaceTheme) {
            let dark = theme.prefersLightForeground
            isDark = dark
            let base = dark ? Legibility.white : Legibility.ink
            text = base.withAlpha(base.a * Legibility.primary.alpha)
            secondary = base.withAlpha(base.a * Legibility.secondary.alpha)
            tertiary = base.withAlpha(base.a * Legibility.tertiary.alpha)
            placeholder = Legibility.placeholder(lightInk: dark)
            faint = base.withAlpha(base.a * Legibility.faint.alpha)
            hover = Legibility.hover(lightInk: dark)
            hoverStrong = Legibility.hoverStrong(lightInk: dark)
            selected = Legibility.selected(lightInk: dark)
            stroke = base.withAlpha(base.a * (dark ? 0.14 : 0.12))
            accent = theme.accent
            let filled = Legibility.filled(theme.accent)
            accentFill = filled.fill
            onAccent = filled.label
            let ground = theme.worstStop
            accentText = theme.accent(onPanelMinimum: 4.5)
            accentGlyph = theme.accent(onPanelMinimum: 3)
            positive = Legibility.foreground(RGBA(0.30, 0.85, 0.45), on: ground)
            negative = Legibility.foreground(RGBA(1, 0.42, 0.40), on: ground)
            warning = Legibility.foreground(RGBA(1, 0.62, 0.20), on: ground)
            panel = Legibility.panelTint(lightInk: dark)
            shadow = RGBA(0, 0, 0, dark ? 0.45 : 0.18)
        }

        /// Each end is exactly that palette.
        func mixed(with other: Inks, _ t: Double) -> Inks {
            if !(t > 0) { return self }
            if t >= 1 { return other }
            var out = self
            out.isDark = t < 0.5 ? isDark : other.isDark
            let paths: [WritableKeyPath<Inks, RGBA>] = [\.text, \.secondary, \.tertiary, \.placeholder, \.faint, \.hover, \.hoverStrong,
                                                       \.selected, \.stroke, \.accent, \.accentFill, \.onAccent, \.accentText, \.accentGlyph,
                                                       \.positive, \.negative, \.warning, \.panel, \.shadow]
            for path in paths { out[keyPath: path] = self[keyPath: path].mixed(with: other[keyPath: path], t) }
            return out
        }
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
