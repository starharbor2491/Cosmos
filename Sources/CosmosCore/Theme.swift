import Foundation

/// A colour in sRGB, components 0...1. Plain data so it can live in the model layer without AppKit.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    /// Relative luminance (WCAG), used to pick legible foreground colours over a theme.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// Hue/saturation/brightness (all 0...1), for the theme editor's colour wheel.
    public var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func fromHSB(h: Double, s: Double, b: Double, a: Double = 1) -> RGBA {
        let hh = (h - floor(h)) * 6
        let c = b * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r, g, bl): (Double, Double, Double)
        switch Int(hh) {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        default: (r, g, bl) = (c, 0, x)
        }
        return RGBA(r + m, g + m, bl + m, a)
    }
}

public enum Appearance: String, Codable, Sendable, CaseIterable {
    case automatic, light, dark
}

/// How a space looks: a gradient wash with grain over the window, plus a starfield.
///
/// Modelled on Arc's `windowTheme` (blended gradient of base colours, an overlay, `intensityFactor`,
/// `noiseFactor`, light/dark appearance) but flattened and without Arc's derived palettes: Cosmos derives
/// foreground/hover colours from the gradient at render time.
public struct SpaceTheme: Codable, Hashable, Sendable {
    public var name: String
    /// 1...4 gradient stops, blended in order along `angle`.
    public var colors: [RGBA]
    /// Gradient direction in degrees, 0 = left to right, 90 = bottom to top.
    public var angle: Double
    /// 0...1: how strongly the gradient tints the window versus plain system material.
    public var intensity: Double
    /// 0...1: film-grain amount (Arc's noise factor).
    public var grain: Double
    /// 0...1: density of the starfield painted over the gradient.
    public var starfield: Double
    public var appearance: Appearance

    public init(name: String, colors: [RGBA], angle: Double = 135, intensity: Double = 0.85,
                grain: Double = 0.25, starfield: Double = 0.5, appearance: Appearance = .dark) {
        self.name = name
        self.colors = colors.isEmpty ? [RGBA(hex: 0x1B1B3A)] : Array(colors.prefix(4))
        self.angle = angle
        self.intensity = intensity
        self.grain = grain
        self.starfield = starfield
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey { case name, colors, angle, intensity, grain, starfield, appearance }

    /// Goes through the designated initializer, so a file with no colors (or nine) gets the same treatment as code does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), colors: try c.decode([RGBA].self, forKey: .colors),
                  angle: try c.decode(Double.self, forKey: .angle), intensity: try c.decode(Double.self, forKey: .intensity),
                  grain: try c.decode(Double.self, forKey: .grain), starfield: try c.decode(Double.self, forKey: .starfield),
                  appearance: try c.decode(Appearance.self, forKey: .appearance))
    }

    /// True when text over this theme should be light.
    public var prefersLightForeground: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .automatic:
            let avg = colors.map(\.luminance).reduce(0, +) / Double(colors.count)
            return avg < 0.45
        }
    }

    /// The accent used for selection highlights and the "current" glow: the most saturated stop.
    public var accent: RGBA {
        colors.max { $0.hsb.s * (0.4 + $0.hsb.b) < $1.hsb.s * (0.4 + $1.hsb.b) } ?? colors[0]
    }
}

public extension SpaceTheme {
    static let nebula = SpaceTheme(name: "Nebula", colors: [RGBA(hex: 0x2A1055), RGBA(hex: 0x7B2D8E), RGBA(hex: 0xE0568D)], angle: 140)
    static let aurora = SpaceTheme(name: "Aurora", colors: [RGBA(hex: 0x04282F), RGBA(hex: 0x0E7C6B), RGBA(hex: 0x7BE0A6)], angle: 120)
    static let supernova = SpaceTheme(name: "Supernova", colors: [RGBA(hex: 0x3A0D0D), RGBA(hex: 0xC2410C), RGBA(hex: 0xFBBF24)], angle: 150)
    static let deepField = SpaceTheme(name: "Deep Field", colors: [RGBA(hex: 0x050816), RGBA(hex: 0x14246B), RGBA(hex: 0x3B5BDB)], angle: 160, starfield: 0.9)
    static let pulsar = SpaceTheme(name: "Pulsar", colors: [RGBA(hex: 0x03223B), RGBA(hex: 0x0891B2), RGBA(hex: 0x67E8F9)], angle: 130)
    static let eclipse = SpaceTheme(name: "Eclipse", colors: [RGBA(hex: 0x0B0B0F), RGBA(hex: 0x23232D), RGBA(hex: 0x4B4B5C)], angle: 145, intensity: 0.7, starfield: 0.6)
    static let moondust = SpaceTheme(name: "Moondust", colors: [RGBA(hex: 0xF4F1EA), RGBA(hex: 0xD9D3E8), RGBA(hex: 0xB9C6E6)], angle: 135, intensity: 0.8, grain: 0.3, starfield: 0.12, appearance: .light)
    static let solstice = SpaceTheme(name: "Solstice", colors: [RGBA(hex: 0xFFF1D6), RGBA(hex: 0xFFC48A), RGBA(hex: 0xF58F9B)], angle: 120, intensity: 0.8, starfield: 0.1, appearance: .light)

    static let presets: [SpaceTheme] = [.nebula, .aurora, .supernova, .deepField, .pulsar, .eclipse, .moondust, .solstice]
}
