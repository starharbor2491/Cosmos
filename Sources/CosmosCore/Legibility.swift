import Foundation

/// Whether text can be read on a space's theme (WCAG contrast). A theme may be as bright as its author likes; the
/// colours the window actually paints are pulled toward black (under light ink) or white (under dark ink) just far
/// enough that every role of text, on every surface the sidebar draws, reaches its minimum.
public enum Legibility {
    /// The opacity of the ink for a role of text, and the contrast it must reach.
    public struct Role: Sendable {
        public let alpha: Double
        public let minimum: Double
    }

    /// Titles and the selected row.
    public static let primary = Role(alpha: 1.0, minimum: 4.5)
    /// Addresses, sub-labels and the unselected navigation.
    public static let secondary = Role(alpha: 0.86, minimum: 4.5)
    /// Hints, placeholders, timestamps and group captions: the quietest text, held to 3:1.
    public static let tertiary = Role(alpha: 0.70, minimum: 3.0)
    /// Strokes, glyphs and dashed outlines are not text: WCAG asks 3:1 of them.
    public static let faint = Role(alpha: 0.55, minimum: 3.0)

    /// White, for themes that are dark, and a near-black violet for themes that are light.
    public static let white = RGBA(1, 1, 1)
    public static let ink = RGBA(0.08, 0.07, 0.14)

    /// The overlays a row is drawn with over the theme.
    public static func hover(lightInk: Bool) -> RGBA { (lightInk ? white : ink).withAlpha(lightInk ? 0.10 : 0.07) }
    /// A control under the pointer: stronger than a hovered row.
    public static func hoverStrong(lightInk: Bool) -> RGBA { (lightInk ? white : ink).withAlpha(lightInk ? 0.18 : 0.12) }
    public static func selected(lightInk: Bool) -> RGBA { white.withAlpha(lightInk ? 0.16 : 0.62) }

    /// `fg` laid over the opaque colour `bg`, in sRGB like the compositor does it.
    public static func composite(_ fg: RGBA, over bg: RGBA) -> RGBA {
        RGBA(bg.r + (fg.r - bg.r) * fg.a, bg.g + (fg.g - bg.g) * fg.a, bg.b + (fg.b - bg.b) * fg.a)
    }

    /// WCAG contrast ratio between two opaque colours (1...21).
    public static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let hi = max(a.luminance, b.luminance), lo = min(a.luminance, b.luminance)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Contrast of `role`'s ink over `background` (with an optional surface overlay such as a hovered row between them).
    public static func ratio(_ role: Role, lightInk: Bool, over background: RGBA, surface: RGBA? = nil) -> Double {
        let ground = surface.map { composite($0, over: background) } ?? background
        let text = (lightInk ? white : ink).withAlpha(role.alpha)
        return contrast(composite(text, over: ground), ground)
    }

    /// The lowest margin (ratio divided by the role's minimum) over every role and surface the sidebar uses on
    /// `background`. At 1 or more, all of them pass.
    public static func margin(of background: RGBA, lightInk: Bool) -> Double {
        let hover = Self.hover(lightInk: lightInk), selected = Self.selected(lightInk: lightInk)
        let strong = Self.hoverStrong(lightInk: lightInk)
        let checks: [(Role, RGBA?)] = [
            (primary, nil), (primary, hover), (primary, strong), (primary, selected),
            (secondary, nil), (secondary, hover), (secondary, strong), (secondary, selected),
            (tertiary, nil), (tertiary, hover), (tertiary, strong),
            (faint, nil),
        ]
        return checks.map { ratio($0.0, lightInk: lightInk, over: background, surface: $0.1) / $0.0.minimum }.min() ?? 1
    }

    /// `color` itself when it already passes `test`, otherwise the nearest point on the way to `anchor` that does.
    public static func pulled(_ color: RGBA, toward anchor: RGBA, until test: (RGBA) -> Bool) -> RGBA {
        let start = color.withAlpha(1)
        if test(start) { return start }
        var passing = 1.0, failing = 0.0
        for _ in 0..<24 {
            let mid = (passing + failing) / 2
            if test(start.mixed(with: anchor, mid)) { passing = mid } else { failing = mid }
        }
        return start.mixed(with: anchor, passing)
    }

    /// `color` as a background for text: unchanged when every role reads on it, otherwise moved toward black (light
    /// ink) or white (dark ink) as little as possible.
    public static func background(_ color: RGBA, lightInk: Bool) -> RGBA {
        pulled(color, toward: lightInk ? RGBA(0, 0, 0) : RGBA(1, 1, 1)) { margin(of: $0, lightInk: lightInk) >= 1 }
    }

    /// A filled control (primary button, switch track) in `accent`, with the label that reads on it: white on a dark
    /// accent, dark ink on a light one. Where neither reaches 4.5 as it is, the fill moves toward whichever label needs
    /// the smaller change, and white is preferred (a button is expected to carry white text) while it takes only a
    /// slight darkening, or at most three times the change dark ink does.
    public static func filled(_ accent: RGBA) -> (fill: RGBA, label: RGBA) {
        let solid = accent.withAlpha(1)
        let forWhite = pulled(solid, toward: RGBA(0, 0, 0)) { contrast(white, $0) >= 4.5 }
        let forInk = pulled(solid, toward: RGBA(1, 1, 1)) { contrast(ink, $0) >= 4.5 }
        let whiteChange = abs(forWhite.luminance - solid.luminance), inkChange = abs(forInk.luminance - solid.luminance)
        return whiteChange <= max(inkChange * 3, 0.05) ? (forWhite, white) : (forInk, ink)
    }

    /// `color` as text on `background`: unchanged when it reads, otherwise moved away from the background.
    public static func foreground(_ color: RGBA, on background: RGBA) -> RGBA {
        let anchor = background.luminance > 0.3 ? RGBA(0, 0, 0) : RGBA(1, 1, 1)
        return pulled(color, toward: anchor) { contrast($0, background) >= 4.5 }
    }
}

public extension SpaceTheme {
    /// The colours the window paints for this theme: every stop adjusted so text reads on it (see `Legibility`).
    var legible: SpaceTheme {
        var copy = self
        let light = prefersLightForeground
        copy.colors = colors.map { Legibility.background($0, lightInk: light) }
        return copy
    }

    /// The stop text is hardest to read on: the lightest under light ink, the darkest under dark ink.
    var worstStop: RGBA {
        let stops = legible.colors
        let pick = prefersLightForeground ? stops.max { $0.luminance < $1.luminance } : stops.min { $0.luminance < $1.luminance }
        return pick ?? stops[0]
    }
}
