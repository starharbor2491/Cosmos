import Foundation
import CosmosCore

/// Arc's per-space look (`customInfo.windowTheme`) and icon (`customInfo.iconType`) as Cosmos values.
enum ArcSpaceStyle {
    // MARK: Theme

    /// `windowTheme` is `background.single._0.style.color._0.blendedGradient._0 {baseColors, overlayColors, wheel,
    /// modifiers}` plus `contentOverBackgroundAppearance`. The gradient stops come from `baseColors`, each nudged a
    /// quarter of the way towards its `overlayColors` entry (weighted by that colour's alpha); intensity and grain
    /// come from the modifiers. The result is always named "Imported" and gets a medium starfield.
    static func theme(from windowTheme: Any?, notes: ImportNotes) -> SpaceTheme {
        let fallback = SpaceTheme(name: "Imported", colors: SpaceTheme.nebula.colors, angle: SpaceTheme.nebula.angle,
                                  intensity: SpaceTheme.nebula.intensity, grain: SpaceTheme.nebula.grain, starfield: 0.5,
                                  appearance: SpaceTheme.nebula.appearance)
        guard let theme = ArcJSON.dict(windowTheme) else {
            notes.warn("A space had no theme; the default theme was used")
            return fallback
        }
        let gradient = ArcJSON.dict(ArcJSON.unwrap(ArcJSON.find(["blendedGradient"], in: theme)))

        var stops = (ArcJSON.list(gradient?["baseColors"]) ?? []).compactMap(color)
        let overlays = (ArcJSON.list(gradient?["overlayColors"]) ?? []).map(color)
        for i in stops.indices where i < overlays.count {
            if let overlay = overlays[i], overlay.a > 0 { stops[i] = stops[i].mixed(with: overlay.withAlpha(1), 0.25 * overlay.a) }
        }
        if stops.isEmpty, let palette = ArcJSON.dict(theme["primaryColorPalette"]) {
            stops = ["shadedDark", "midTone", "tintedLight"].compactMap { color(palette[$0]) }
        }
        guard !stops.isEmpty else {
            notes.warn("A space theme had no colors; the default theme was used")
            return fallback
        }

        let modifiers = ArcJSON.dict(gradient?["modifiers"])
        let angle = ArcJSON.number(ArcJSON.find(["angle", "rotation", "degrees"], in: gradient?["wheel"])).map(normalizedDegrees) ?? 135
        return SpaceTheme(name: "Imported", colors: sample(stops, 4), angle: angle,
                          intensity: ArcJSON.number(modifiers?["intensityFactor"]).map(ArcJSON.clamp01) ?? SpaceTheme.nebula.intensity,
                          grain: ArcJSON.number(modifiers?["noiseFactor"]).map(ArcJSON.clamp01) ?? SpaceTheme.nebula.grain,
                          starfield: 0.5, appearance: appearance(theme))
    }

    /// `contentOverBackgroundAppearance` says how the sidebar content should look over the background ("dark" means
    /// light text). `contrastingForeground`, in builds that write it, is the opposite way round: it names the text.
    static func appearance(_ theme: [String: Any]) -> Appearance {
        func named(_ s: String) -> Appearance {
            switch s.lowercased() { case "dark": return .dark; case "light": return .light; default: return .automatic }
        }
        if let s = ArcJSON.find(["contentOverBackgroundAppearance", "appearance"], in: theme) as? String { return named(s) }
        if let foreground = ArcJSON.find(["contrastingForeground"], in: theme) {
            if let s = foreground as? String {
                switch s.lowercased() { case "light": return .dark; case "dark": return .light; default: return .automatic }
            }
            if let rgba = color(foreground) { return rgba.luminance > 0.5 ? .dark : .light }
        }
        return .automatic
    }

    /// `{red, green, blue, alpha, colorSpace}`. Extended sRGB values can leave 0...1; they are clamped.
    static func color(_ value: Any?) -> RGBA? {
        guard let d = ArcJSON.dict(value), let r = ArcJSON.number(d["red"]), let g = ArcJSON.number(d["green"]), let b = ArcJSON.number(d["blue"]) else { return nil }
        return RGBA(ArcJSON.clamp01(r), ArcJSON.clamp01(g), ArcJSON.clamp01(b), ArcJSON.clamp01(ArcJSON.number(d["alpha"]) ?? 1))
    }

    private static func normalizedDegrees(_ v: Double) -> Double {
        let m = v.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    /// At most `limit` colours, evenly spread, keeping the first and the last.
    private static func sample(_ colors: [RGBA], _ limit: Int) -> [RGBA] {
        guard colors.count > limit else { return colors }
        return (0..<limit).map { colors[Int((Double($0) * Double(colors.count - 1) / Double(limit - 1)).rounded())] }
    }

    // MARK: Icon

    /// `iconType` is an enum: `{"icon": "planet"}` names one of Arc's own symbols, `{"emoji": "🚀"}` (and the newer
    /// `emoji_v2`, which stores Unicode scalars) an emoji.
    static func icon(from iconType: Any?, notes: ImportNotes) -> SpaceIcon {
        guard let d = ArcJSON.dict(iconType), let kind = ["icon", "emoji_v2", "emoji"].first(where: { d[$0] != nil && !(d[$0] is NSNull) }) else {
            return .symbol("moon.stars.fill")
        }
        let inner = ArcJSON.unwrap(d[kind])
        switch kind {
        case "icon":
            guard let name = ArcJSON.string(inner) else { return .symbol("moon.stars.fill") }
            if let mapped = symbols[name] { return mapped }
            if name.contains(".") { return .symbol(name) }
            notes.warn("A space used an Arc icon Cosmos does not have; a default icon was used")
            return .symbol("moon.stars.fill")
        case "emoji", "emoji_v2":
            if let e = emoji(from: inner) { return .emoji(e) }
            notes.warn("A space emoji could not be read; a default icon was used")
            return .symbol("moon.stars.fill")
        default:
            notes.warn("A space had an unknown icon kind; a default icon was used")
            return .symbol("moon.stars.fill")
        }
    }

    private static func emoji(from value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(t), let scalar = Unicode.Scalar(UInt32(clamping: n)) { return String(Character(scalar)) }
            return t.isEmpty || t.unicodeScalars.allSatisfy(\.isASCII) || t.count > 16 ? nil : t
        }
        if let n = ArcJSON.number(value), let scalar = Unicode.Scalar(UInt32(clamping: Int(n))) { return String(Character(scalar)) }
        if let a = value as? [Any] {
            let scalars = a.compactMap { ArcJSON.number($0) }.compactMap { Unicode.Scalar(UInt32(clamping: Int($0))) }
            return scalars.isEmpty ? nil : String(String.UnicodeScalarView(scalars))
        }
        return nil
    }

    /// Arc's built-in space icons (an Ionicons-style set) and the Cosmos symbols that stand in for them.
    static let symbols: [String: SpaceIcon] = [
        "star": .symbol("star.fill"), "bookmark": .symbol("bookmark.fill"), "heart": .symbol("heart.fill"),
        "flag": .symbol("flag.fill"), "flash": .symbol("bolt.fill"), "triangle": .symbol("triangle.fill"),
        "medical": .symbol("cross.case.fill"), "notifications": .symbol("bell.fill"), "bulb": .symbol("lightbulb.fill"),
        "shapes": .symbol("square.on.circle"), "grid": .symbol("square.grid.2x2.fill"), "apps": .symbol("square.grid.3x3.fill"),
        "layers": .symbol("square.3.layers.3d"), "server": .symbol("server.rack"), "albums": .symbol("rectangle.stack.fill"),
        "copy": .symbol("doc.on.doc.fill"), "folder": .symbol("folder.fill"), "fileTrayFull": .symbol("tray.full.fill"),
        "calendar": .symbol("calendar"), "mail": .symbol("envelope.fill"), "checkbox": .symbol("checkmark.square.fill"),
        "document": .symbol("doc.fill"), "book": .symbol("book.fill"), "chatBubbleEllipses": .symbol("ellipsis.bubble.fill"),
        "people": .symbol("person.2.fill"), "terminal": .symbol("terminal.fill"), "construction": .symbol("hammer.fill"),
        "square": .symbol("square.fill"), "ellipse": .symbol("circle.fill"), "moon": .symbol("moon.fill"),
        "sunny": .symbol("sun.max.fill"), "planet": .symbol("globe.americas.fill"), "leaf": .symbol("leaf.fill"),
        "cloud": .symbol("cloud.fill"), "cloudOutline": .symbol("cloud"), "gift": .symbol("gift.fill"),
        "restaurant": .symbol("fork.knife"), "barbell": .symbol("dumbbell.fill"), "airplane": .symbol("airplane"),
        "musicalNote": .symbol("music.note"), "colorPallete": .symbol("paintpalette.fill"), "colorPalette": .symbol("paintpalette.fill"),
        "bandage": .symbol("bandage.fill"), "code": .symbol("chevron.left.forwardslash.chevron.right"),
        "baseball": .symbol("baseball.fill"), "bonfire": .symbol("flame.fill"), "pizza": .emoji("🍕"),
        "skull": .emoji("💀"), "receipt": .emoji("🧾"), "thumbsUp": .symbol("hand.thumbsup.fill"),
        "train": .symbol("tram.fill"), "search": .symbol("magnifyingglass"),
    ]
}
