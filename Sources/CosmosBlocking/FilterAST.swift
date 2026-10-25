import Foundation

/// Request types an Adblock Plus / uBlock Origin filter can be restricted to (`$script,image`, `$~font`).
public enum ResourceType: String, CaseIterable, Sendable, Codable {
    case script, image, stylesheet, font, media, xmlhttprequest, subdocument, document, ping, websocket, other, popup

    /// What a filter without type options applies to: everything except page loads themselves.
    public static let defaultSet: Set<ResourceType> = Set(allCases).subtracting([.document, .popup])
}

/// Page-level cosmetic exemptions requested by `@@||site^$generichide` / `$elemhide` / `$specifichide`.
public struct HideScope: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let generic = HideScope(rawValue: 1)
    public static let specific = HideScope(rawValue: 2)
    public static let all: HideScope = [.generic, .specific]
}

/// The `domain=` option or the domain prefix of a cosmetic filter: hosts the filter applies to / is excluded from.
public struct DomainList: Hashable, Sendable {
    public var include: [String] = []
    public var exclude: [String] = []
    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }
    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty }
}

/// A URL-matching filter (`||ads.example.com^$third-party`, `@@/ads/*$script`).
public struct NetworkFilter: Hashable, Sendable {
    public enum Pattern: Hashable, Sendable {
        /// Wildcard pattern body (`*` and `^` are special) with anchors already stripped.
        case glob(String)
        /// Regular expression between the slashes of `/.../`.
        case regex(String)
    }

    public var pattern: Pattern
    /// Leading `||`: match at the start of a host or any of its subdomains.
    public var hostAnchor = false
    /// Leading `|`: match at the start of the URL.
    public var startAnchor = false
    /// Trailing `|`: match at the end of the URL.
    public var endAnchor = false
    /// `@@` exception: cancels blocks instead of blocking.
    public var isException = false
    /// Explicit resource types; empty means "default" (`ResourceType.defaultSet`).
    public var types: Set<ResourceType> = []
    /// `true` for `$third-party`, `false` for `$~third-party`/`$first-party`, `nil` for either.
    public var thirdParty: Bool?
    public var domains = DomainList()
    public var matchCase = false
    public var important = false
    public var badfilter = false
    /// `$generichide`, `$elemhide`, `$specifichide` on an exception.
    public var hideScope: HideScope = []

    public init(pattern: Pattern) { self.pattern = pattern }

    /// Whether the pattern is empty (the filter is just options such as `$popup,domain=a.com`).
    public var hasEmptyPattern: Bool {
        if hostAnchor || startAnchor || endAnchor { return false }
        switch pattern {
        case .glob(let g): return g.isEmpty || g.allSatisfy { $0 == "*" }
        case .regex(let r): return r.isEmpty
        }
    }

    /// The filter a `$badfilter` line disables: identical, minus the `badfilter` flag.
    var withoutBadfilter: NetworkFilter {
        var copy = self
        copy.badfilter = false
        return copy
    }
}

/// An element-hiding filter (`##.banner`, `site.com,~sub.site.com##.ad`, `site.com#@#.ad`).
public struct CosmeticFilter: Equatable, Sendable {
    public var selector: String
    public var domains = DomainList()
    /// `#@#`: stops `selector` hiding things (on `domains`, or everywhere when none are given).
    public var isException = false

    public init(selector: String, domains: DomainList = DomainList(), isException: Bool = false) {
        self.selector = selector
        self.domains = domains
        self.isException = isException
    }

    public var isGeneric: Bool { domains.include.isEmpty }
}

public enum Filter: Equatable, Sendable {
    case network(NetworkFilter)
    case cosmetic(CosmeticFilter)
}

/// Why a filter line was not turned into a rule. Free-form so reports can say exactly which `$option` was unsupported.
public struct SkipReason: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, Comparable, Error {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (a: SkipReason, b: SkipReason) -> Bool { a.rawValue < b.rawValue }

    /// `$redirect`, `$csp`, `$removeparam`, `$replace`, ... : behaviours WebKit rules cannot express.
    public static func unsupportedOption(_ name: String) -> SkipReason { SkipReason("option:\(name)") }
    /// `/regex/` filters using alternation, counted repeats, `\b` and friends.
    public static let regexNotRepresentable = SkipReason("regex-not-representable")
    /// `#?#`, `:has-text()`, `:xpath()`, `:matches-css()` ... (needs a script engine).
    public static let extendedSelector = SkipReason("extended-selector")
    public static let scriptlet = SkipReason("scriptlet")
    public static let htmlFilter = SkipReason("html-filter")
    public static let cssInjection = SkipReason("css-injection")
    public static let scriptRule = SkipReason("script-rule")
    /// Selector WebKit would silently drop (unknown pseudo-class, nested `:has`, ...).
    public static let invalidSelector = SkipReason("invalid-selector")
    /// `example.*` or `/regex/` in a domain list.
    public static let entityDomain = SkipReason("entity-domain")
    public static let nonASCII = SkipReason("non-ascii")
    /// A filter that would block (almost) everything.
    public static let tooBroad = SkipReason("too-broad")
    public static let malformed = SkipReason("malformed")
    /// `$document` exception for something other than a whole site.
    public static let documentException = SkipReason("document-exception")
    /// Cosmetic exception that cannot be expressed next to the hiding rule it targets.
    public static let cosmeticConflict = SkipReason("cosmetic-conflict")
    /// A mix of included and excluded domains cosmetic rules cannot express.
    public static let mixedDomains = SkipReason("mixed-domains")
    /// Dropped because the list would exceed its rule budget.
    public static let overLimit = SkipReason("over-limit")
    /// Disabled by a `$badfilter` line.
    public static let badfiltered = SkipReason("badfiltered")
    /// Lines excluded by `!#if` conditions for other browsers.
    public static let conditional = SkipReason("conditional")
}
