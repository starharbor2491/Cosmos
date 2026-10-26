import Foundation
import CoreGraphics

// The menu-bar browser: a small browser in a panel under an icon in the menu bar, for a quick look at something. What
// it is called, where it opens, what it starts on and when a click should open it all lives here, without AppKit, so
// it can be tested. The panel and the status item are in CosmosKit.

/// The user's choices for the menu-bar browser.
public struct MenuBarSettings: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        /// Narrow, and sites are told they are on a phone, so they answer with their mobile pages.
        case phone
        /// A wider panel that shows the sites' desktop pages.
        case desktop

        public var size: CGSize {
            switch self {
            case .phone: CGSize(width: 390, height: 680)
            case .desktop: CGSize(width: 600, height: 680)
            }
        }

        public var isMobile: Bool { self == .phone }
    }

    /// Off until turned on: an icon that nobody asked for would be clutter in the menu bar.
    public var enabled = false
    public var layout: Layout = .phone
    /// Whose cookies and logins the panel uses: a profile of the main browser. Nil means the default profile.
    public var profileID: UUID?
    /// Where the panel starts. Empty (or anything that is not a web address) means the search engine's front page.
    public var homeAddress = ""
    /// Open on the page that was showing when the panel was last closed.
    public var rememberPage = true
    public var lastAddress: String?

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, layout, profileID, homeAddress, rememberPage, lastAddress }

    // A file written by another build must not lock anyone out: unknown or wrong-typed keys keep their defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decode(Layout.self, forKey: .layout) { layout = v }
        if let v = try? c.decode(UUID.self, forKey: .profileID) { profileID = v }
        if let v = try? c.decode(String.self, forKey: .homeAddress) { homeAddress = v }
        if let v = try? c.decode(Bool.self, forKey: .rememberPage) { rememberPage = v }
        if let v = try? c.decode(String.self, forKey: .lastAddress) { lastAddress = v }
    }

    /// The profile the panel uses: the chosen one, or the default if that is gone (or nothing was chosen).
    public func profile(in profiles: [Profile]) -> Profile? {
        profiles.first { $0.id == profileID } ?? profiles.first { $0.isDefault } ?? profiles.first
    }

    /// A typed address as a web page, or nil when it is not one (words to search for, a script, a file, nothing).
    public static func homeURL(from text: String) -> URL? {
        guard case .url(let url) = URLInput.resolve(text), isWeb(url) else { return nil }
        return url
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// The page the panel opens on: the one left open if that is on, else the home address, else the search page.
    public func startURL(engine: SearchEngine) -> URL? {
        if rememberPage, let last = lastAddress.flatMap(URL.init(string:)), Self.isWeb(last) { return last }
        return Self.homeURL(from: homeAddress) ?? engine.homeURL
    }

    /// Keeps `url` as the page to come back to. Only web pages are kept, and not at all when remembering is off.
    public mutating func remember(_ url: URL?) {
        guard rememberPage else { lastAddress = nil; return }
        guard let url, Self.isWeb(url), url.absoluteString.count <= 2048 else { return }
        lastAddress = url.absoluteString
    }
}

public enum MenuBarPlacement {
    /// Between the bottom of the icon and the top of the panel.
    public static let gap: CGFloat = 6
    /// The least the panel keeps clear of the screen's edges.
    public static let margin: CGFloat = 8

    /// Where the panel goes, in screen coordinates (y up): hanging centred under the icon, pushed back inside the screen
    /// at either side, and made shorter or narrower when the screen is too small for it. Without an icon it hangs from the
    /// top-right corner. `visible` is the screen without the menu bar and Dock.
    public static func frame(anchor: CGRect?, size: CGSize, visible: CGRect, gap: CGFloat = gap, margin: CGFloat = margin) -> CGRect {
        let icon = anchor ?? CGRect(x: visible.maxX - 44, y: visible.maxY, width: 28, height: 0)
        let width = max(0, min(size.width, visible.width - 2 * margin))
        let top = min(icon.minY - gap, visible.maxY)
        let height = max(0, min(size.height, top - visible.minY - margin))
        let low = visible.minX + margin, high = visible.maxX - margin - width
        let x = min(max(icon.midX - width / 2, low), max(low, high))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

public enum MenuBarToggle {
    /// Clicking the icon while the panel is open first takes the keyboard away from the panel, which closes it, and only
    /// then arrives as a click. That click must not open the panel again straight away.
    public static func shouldOpen(now: Date, closedAt: Date?, within window: TimeInterval = 0.25) -> Bool {
        guard let closedAt else { return true }
        return now.timeIntervalSince(closedAt) > window
    }
}
