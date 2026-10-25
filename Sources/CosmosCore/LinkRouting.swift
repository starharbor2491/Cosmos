import Foundation

/// Where a link that arrives from outside Cosmos (another app, the Dock, `open https://...`) should open.
public enum LinkDestination: Hashable, Sendable {
    /// Cosmos's small floating window ("Probe"; Arc calls it Little Arc).
    case probe
    /// A new tab in whichever space was used most recently.
    case mostRecentSpace
    /// A new tab in this specific space.
    case space(UUID)
}

extension LinkDestination: Codable {
    private enum CodingKeys: String, CodingKey { case kind, spaceID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "space": self = .space(try c.decode(UUID.self, forKey: .spaceID))
        case "mostRecentSpace": self = .mostRecentSpace
        default: self = .probe
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .probe: try c.encode("probe", forKey: .kind)
        case .mostRecentSpace: try c.encode("mostRecentSpace", forKey: .kind)
        case .space(let id): try c.encode("space", forKey: .kind); try c.encode(id, forKey: .spaceID)
        }
    }
}

public struct LinkRule: Codable, Hashable, Identifiable, Sendable {
    public enum Match: Codable, Hashable, Sendable {
        /// The link's host equals this or is a subdomain of it.
        case host(String)
        case urlContains(String)
        case urlPrefix(String)
        case urlSuffix(String)

        public func matches(_ url: URL) -> Bool {
            switch self {
            case .host(let h):
                guard let host = url.host?.lowercased() else { return false }
                let t = h.lowercased()
                return host == t || host.hasSuffix("." + t)
            case .urlContains(let s): return url.absoluteString.localizedCaseInsensitiveContains(s)
            case .urlPrefix(let s): return url.absoluteString.lowercased().hasPrefix(s.lowercased())
            case .urlSuffix(let s): return url.absoluteString.lowercased().hasSuffix(s.lowercased())
            }
        }
    }

    public var id: UUID
    /// All matches must hold (AND).
    public var matches: [Match]
    public var destination: LinkDestination

    public init(id: UUID = UUID(), matches: [Match], destination: LinkDestination) {
        self.id = id; self.matches = matches; self.destination = destination
    }

    public func applies(to url: URL) -> Bool { !matches.isEmpty && matches.allSatisfy { $0.matches(url) } }
}

/// Link routing: first matching rule wins, otherwise `defaultDestination`.
public struct LinkRouting: Codable, Equatable, Sendable {
    public var rules: [LinkRule]
    public var defaultDestination: LinkDestination

    public init(rules: [LinkRule] = [], defaultDestination: LinkDestination = .probe) {
        self.rules = rules; self.defaultDestination = defaultDestination
    }

    public func destination(for url: URL) -> LinkDestination {
        rules.first { $0.applies(to: url) }?.destination ?? defaultDestination
    }
}
