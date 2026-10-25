import Foundation

/// Per-site tweaks, Arc's best-loved feature: custom CSS and JavaScript, a colour filter, a font, a zoom level,
/// and "Zap" (hide elements you never want to see again). Arc implements these as Chromium per-host "effects";
/// Cosmos injects them as user scripts / style sheets when a page for a matching host loads.
public struct Boost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Host patterns this Boost applies to: `example.com` (that host and its subdomains) or `*.example.com`
    /// (subdomains only) or `*` (every site).
    public var hostPatterns: [String]
    public var css: String
    public var js: String
    /// CSS selectors hidden with `display: none !important`.
    public var zapSelectors: [String]
    public var colorFilter: ColorFilter?
    /// A font family forced onto the page, e.g. "Georgia".
    public var fontFamily: String?
    /// Page zoom multiplier (1 = 100%).
    public var zoom: Double?
    /// Limits the Boost to one profile; `nil` means every profile.
    public var profileID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, hostPatterns: [String], css: String = "", js: String = "",
                zapSelectors: [String] = [], colorFilter: ColorFilter? = nil, fontFamily: String? = nil, zoom: Double? = nil,
                profileID: UUID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.hostPatterns = hostPatterns
        self.css = css; self.js = js; self.zapSelectors = zapSelectors; self.colorFilter = colorFilter
        self.fontFamily = fontFamily; self.zoom = zoom; self.profileID = profileID
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Does this Boost apply to `host`?
    public func matches(host: String) -> Bool {
        let h = host.lowercased()
        return hostPatterns.contains { Boost.hostMatches(pattern: $0, host: h) }
    }

    public static func hostMatches(pattern raw: String, host: String) -> Bool {
        var p = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if p == "*" { return true }
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
        if p.hasPrefix("*.") {
            let base = String(p.dropFirst(2))
            return host.hasSuffix("." + base)
        }
        if p.hasPrefix("www.") { p.removeFirst(4) }
        return host == p || host.hasSuffix("." + p)
    }
}

/// A colour tweak applied to the whole page: the Boost colour wheel.
public struct ColorFilter: Codable, Hashable, Sendable {
    /// Hue rotation in degrees, -180...180.
    public var hue: Double
    /// 1 = unchanged.
    public var saturation: Double
    public var brightness: Double
    public var contrast: Double
    /// Invert lightness while keeping images natural: "dark mode for any site".
    public var invert: Bool

    public init(hue: Double = 0, saturation: Double = 1, brightness: Double = 1, contrast: Double = 1, invert: Bool = false) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.contrast = contrast; self.invert = invert
    }

    public var isIdentity: Bool { hue == 0 && saturation == 1 && brightness == 1 && contrast == 1 && !invert }

    /// The CSS `filter` value for the page root.
    public var cssFilter: String {
        var parts: [String] = []
        if invert { parts.append("invert(1) hue-rotate(180deg)") }
        if hue != 0 { parts.append("hue-rotate(\(Int(hue.rounded()))deg)") }
        if saturation != 1 { parts.append("saturate(\(String(format: "%.2f", saturation)))") }
        if brightness != 1 { parts.append("brightness(\(String(format: "%.2f", brightness)))") }
        if contrast != 1 { parts.append("contrast(\(String(format: "%.2f", contrast)))") }
        return parts.joined(separator: " ")
    }
}

public struct BoostLibrary: Codable, Equatable, Sendable {
    public var boosts: [Boost]
    public init(boosts: [Boost] = []) { self.boosts = boosts }

    public func boosts(for host: String, profileID: UUID? = nil) -> [Boost] {
        boosts.filter { $0.isEnabled && $0.matches(host: host) && ($0.profileID == nil || $0.profileID == profileID) }
    }
}
