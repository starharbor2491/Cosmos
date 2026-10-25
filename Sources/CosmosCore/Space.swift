import Foundation

public enum SpaceIcon: Hashable, Sendable {
    case emoji(String)
    /// An SF Symbol name.
    case symbol(String)
}

extension SpaceIcon: Codable {
    private enum CodingKeys: String, CodingKey { case emoji, symbol }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let e = try c.decodeIfPresent(String.self, forKey: .emoji) { self = .emoji(e) }
        else { self = .symbol(try c.decodeIfPresent(String.self, forKey: .symbol) ?? "circle.fill") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let e): try c.encode(e, forKey: .emoji)
        case .symbol(let s): try c.encode(s, forKey: .symbol)
        }
    }
}

public extension SpaceIcon {
    /// Space-flavoured defaults offered by the space editor.
    static let suggested: [SpaceIcon] = [
        .symbol("moon.stars.fill"), .symbol("sparkles"), .symbol("globe.americas.fill"), .symbol("sun.max.fill"),
        .symbol("star.fill"), .symbol("bolt.fill"), .symbol("flame.fill"), .symbol("leaf.fill"),
        .symbol("sailboat.fill"), .symbol("scope"), .symbol("atom"), .symbol("cloud.fill"),
        .emoji("🚀"), .emoji("🪐"), .emoji("🌙"), .emoji("☄️"), .emoji("👽"), .emoji("🛰️"),
    ]
}

/// A browsing profile: its own cookies, logins and site data. Each space belongs to exactly one.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The profile that existed before the user made any (Arc calls it `default`).
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public struct Space: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var icon: SpaceIcon
    public var profileID: UUID
    public var theme: SpaceTheme
    /// Root containers of the space's two sections.
    public var pinnedRootID: UUID
    public var unpinnedRootID: UUID

    public init(id: UUID = UUID(), title: String, icon: SpaceIcon = .symbol("moon.stars.fill"), profileID: UUID,
                theme: SpaceTheme = .nebula, pinnedRootID: UUID, unpinnedRootID: UUID) {
        self.id = id
        self.title = title
        self.icon = icon
        self.profileID = profileID
        self.theme = theme
        self.pinnedRootID = pinnedRootID
        self.unpinnedRootID = unpinnedRootID
    }
}
