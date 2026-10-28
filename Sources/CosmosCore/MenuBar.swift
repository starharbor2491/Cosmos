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
    public var rememberPage = true { didSet { if !rememberPage { lastAddress = nil } } }
    public var lastAddress: String?
    /// The size the user dragged each layout's panel to, by layout name. A layout with none uses its own size.
    public private(set) var customSizes: [String: CGSize] = [:]

    /// The most a panel can be made (the screen limits it further).
    public static let maximumSize = CGSize(width: 3000, height: 3000)

    public init() {}

    /// The size of the panel now: what the user dragged this layout's to, or the layout's own.
    public var size: CGSize { customSizes[layout.rawValue] ?? layout.size }
    public var hasCustomSize: Bool { customSizes[layout.rawValue] != nil }

    /// Keeps `size` as this layout's panel size, brought within what can work. Nothing is kept for a size that is not a number.
    public mutating func setSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        customSizes[layout.rawValue] = Self.clamped(size)
    }

    public mutating func resetSize() { customSizes[layout.rawValue] = nil }

    private static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, MenuBarPlacement.minimumSize.width), maximumSize.width),
               height: min(max(size.height, MenuBarPlacement.minimumSize.height), maximumSize.height))
    }

    private enum CodingKeys: String, CodingKey { case enabled, layout, profileID, homeAddress, rememberPage, lastAddress, customSizes }

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
        // Sizes that are not a size, or for a layout there is not, are dropped one by one.
        if let raw = try? c.decode([String: CGSize].self, forKey: .customSizes) {
            for (key, size) in raw where Layout(rawValue: key) != nil && size.width.isFinite && size.height.isFinite
                && size.width >= MenuBarPlacement.minimumSize.width && size.height >= MenuBarPlacement.minimumSize.height
                && size.width <= Self.maximumSize.width && size.height <= Self.maximumSize.height { customSizes[key] = size }
        }
        // A file left by an older build (or edited by hand) may still hold a page that is not meant to be kept.
        if !rememberPage { lastAddress = nil }
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
    /// How far below the top of the visible screen an icon can be and still be in the menu bar.
    static let iconSlack: CGFloat = 8

    /// Where the panel goes, in screen coordinates (y up): hanging centred under the icon, pushed back inside the screen
    /// at either side, and made shorter or narrower when the screen is too small for it. Without an icon it hangs from the
    /// top-right corner. `visible` is the screen without the menu bar and Dock.
    public static func frame(anchor: CGRect?, size: CGSize, visible: CGRect, gap: CGFloat = gap, margin: CGFloat = margin) -> CGRect {
        // An icon the menu bar has not laid out yet sits at a corner of the screen, not in the bar: no anchor at all.
        // (A button sits a point or two inside its window, and a menu bar that hides leaves the visible frame at the screen's top.)
        let icon = anchor.flatMap { $0.maxY >= visible.maxY - iconSlack ? $0 : nil } ?? CGRect(x: visible.maxX - 44, y: visible.maxY, width: 28, height: 0)
        let width = max(0, min(size.width, visible.width - 2 * margin))
        let top = min(icon.minY - gap, visible.maxY)
        let height = max(0, min(size.height, top - visible.minY - margin))
        let low = visible.minX + margin, high = visible.maxX - margin - width
        let x = min(max(icon.midX - width / 2, low), max(low, high))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

extension MenuBarPlacement {
    /// The least the panel can be made.
    public static let minimumSize = CGSize(width: 280, height: 240)

    /// The sides of the panel a drag has hold of: one for an edge, two for a corner.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
    }

    /// `frame` with the edges in `edges` moved by `delta` (screen coordinates, y up: dragging the top edge up grows the panel).
    /// The edges not taken stay where they are, the panel keeps at least `minimum`, and no edge goes past the visible screen
    /// (so the top never goes up under the menu bar).
    public static func resized(_ frame: CGRect, edges: Edges, delta: CGSize, visible: CGRect, minimum: CGSize = minimumSize) -> CGRect {
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        if edges.contains(.left) { minX = min(max(minX + delta.width, visible.minX), maxX - minimum.width) }
        if edges.contains(.right) { maxX = max(min(maxX + delta.width, visible.maxX), minX + minimum.width) }
        if edges.contains(.bottom) { minY = min(max(minY + delta.height, visible.minY), maxY - minimum.height) }
        if edges.contains(.top) { maxY = max(min(maxY + delta.height, visible.maxY), minY + minimum.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
