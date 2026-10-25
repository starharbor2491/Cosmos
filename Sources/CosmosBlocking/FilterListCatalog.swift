import Foundation

/// A downloadable filter list.
public struct FilterListInfo: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case ads, privacy, cookies, annoyances, security, custom
    }

    public var id: String
    public var name: String
    public var url: URL
    public var category: Category
    public var defaultEnabled: Bool
    public var summary: String
    public var license: String
    public var isCustom: Bool

    public init(id: String, name: String, url: URL, category: Category, defaultEnabled: Bool = false, summary: String = "", license: String = "", isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.defaultEnabled = defaultEnabled
        self.summary = summary
        self.license = license
        self.isCustom = isCustom
    }
}

/// The public lists Cosmos offers. Ads, privacy and cookie-banner lists are on by default (the same ground Arc covers
/// with EasyList, EasyPrivacy and a cookie list); the others are opt-in because they are larger or more aggressive.
/// Every URL was checked to be live when this catalog was written.
public enum FilterListCatalog {
    public static let all: [FilterListInfo] = [
        FilterListInfo(
            id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            category: .ads, defaultEnabled: true,
            summary: "The standard ad-blocking list: banners, video ads, sponsored blocks.",
            license: "GPLv3+ or CC BY-SA 3.0 (easylist.to)"),
        FilterListInfo(
            id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            category: .privacy, defaultEnabled: true,
            summary: "Blocks trackers, analytics beacons and fingerprinting scripts.",
            license: "GPLv3+ or CC BY-SA 3.0 (easylist.to)"),
        FilterListInfo(
            id: "fanboy-cookiemonster", name: "Cookie banners (Fanboy Cookiemonster)", url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!,
            category: .cookies, defaultEnabled: true,
            summary: "Hides cookie-consent banners and overlays (the EasyList Cookie List).",
            license: "CC BY 3.0 (Fanboy / easylist.to)"),
        FilterListInfo(
            id: "ublock-filters", name: "uBlock Origin filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!,
            category: .ads, defaultEnabled: false,
            summary: "uBlock Origin's own ad and annoyance fixes, applied on top of EasyList.",
            license: "GPLv3 (uBlockOrigin/uAssets)"),
        FilterListInfo(
            id: "ublock-privacy", name: "uBlock Origin privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!,
            category: .privacy, defaultEnabled: false,
            summary: "uBlock Origin's additional tracker blocking.",
            license: "GPLv3 (uBlockOrigin/uAssets)"),
        FilterListInfo(
            id: "ublock-badware", name: "uBlock Origin badware", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!,
            category: .security, defaultEnabled: false,
            summary: "Malware, phishing and scam domains.",
            license: "GPLv3 (uBlockOrigin/uAssets)"),
        FilterListInfo(
            id: "fanboy-annoyance", name: "Fanboy Annoyances", url: URL(string: "https://secure.fanboy.co.nz/fanboy-annoyance.txt")!,
            category: .annoyances, defaultEnabled: false,
            summary: "Newsletter pop-ups, chat widgets, social buttons and other page clutter.",
            license: "CC BY 3.0 (Fanboy / easylist.to)"),
        FilterListInfo(
            id: "adguard-base", name: "AdGuard Base + EasyList", url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/2.txt")!,
            category: .ads, defaultEnabled: false,
            summary: "AdGuard Base filter merged with EasyList (large; replaces EasyList rather than adding to it).",
            license: "GPLv3 (AdguardTeam/AdguardFilters)"),
    ]

    public static var defaultEnabledIDs: [String] { all.filter(\.defaultEnabled).map(\.id) }

    public static func info(id: String) -> FilterListInfo? { all.first { $0.id == id } }
}
