import Foundation

// The radial menu replaces the page's right-click menu with a ring around the pointer. Everything that decides what is
// on the ring, where each slice is and where the menu is switched off lives here, without AppKit, so it can be tested.

/// What the pointer was over when the page asked for a context menu.
public enum RadialContext: String, Codable, CaseIterable, Sendable, Identifiable {
    case link, image, selection, editable, media, page

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .link: "Links"
        case .image: "Images"
        case .selection: "Selected text"
        case .editable: "Text fields"
        case .media: "Video and audio"
        case .page: "The page"
        }
    }

    /// The context a right click belongs to. A link wins over an image inside it, a text field over a selection in it.
    public static func detect(link: Bool, image: Bool, selection: Bool, editable: Bool, media: Bool) -> RadialContext {
        if media { return .media }
        if editable { return .editable }
        if link { return .link }
        if image { return .image }
        if selection { return .selection }
        return .page
    }
}

/// The actions the ring knows by name. WebKit's menu items are matched to them so a layout the user made keeps working
/// when WebKit rewords an item; anything else on the menu (spelling, fonts, services) is still reachable under "More".
public enum RadialAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case openLink, openLinkInNewTab, openLinkInPeek, openLinkInSplit, downloadLinkedFile, copyLink
    case openImageInNewTab, downloadImage, copyImage, copySubject, lookUpImage
    case openFrameInNewTab
    case lookUp, translate, searchWeb, copy, cut, paste, selectAll, copyLinkWithHighlight, share
    case back, forward, reload, stop
    case downloadMedia, copyMediaLink, toggleMediaControls, toggleLoop, fullScreen, pictureInPicture
    case inspect

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openLink: "Open Link"
        case .openLinkInNewTab: "Open in New Tab"
        case .openLinkInPeek: "Open in Peek"
        case .openLinkInSplit: "Open in Split View"
        case .downloadLinkedFile: "Download Linked File"
        case .copyLink: "Copy Link"
        case .openImageInNewTab: "Open Image in New Tab"
        case .downloadImage: "Download Image"
        case .copyImage: "Copy Image"
        case .copySubject: "Copy Subject"
        case .lookUpImage: "Look Up Image"
        case .openFrameInNewTab: "Open Frame in New Tab"
        case .lookUp: "Look Up"
        case .translate: "Translate"
        case .searchWeb: "Search the Web"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .copyLinkWithHighlight: "Copy Link with Highlight"
        case .share: "Share"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .stop: "Stop"
        case .downloadMedia: "Download Media"
        case .copyMediaLink: "Copy Media Address"
        case .toggleMediaControls: "Media Controls"
        case .toggleLoop: "Loop"
        case .fullScreen: "Full Screen"
        case .pictureInPicture: "Picture in Picture"
        case .inspect: "Inspect Element"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .openLink: "arrow.up.right.square"
        case .openLinkInNewTab: "plus.square.on.square"
        case .openLinkInPeek: "eye"
        case .openLinkInSplit: "rectangle.split.2x1"
        case .downloadLinkedFile, .downloadImage, .downloadMedia: "arrow.down.circle"
        case .copyLink, .copyMediaLink: "link"
        case .openImageInNewTab: "photo"
        case .copyImage, .copy: "doc.on.doc"
        case .copySubject: "person.crop.rectangle"
        case .lookUpImage, .lookUp: "character.book.closed"
        case .openFrameInNewTab: "rectangle.on.rectangle"
        case .translate: "translate"
        case .searchWeb: "magnifyingglass"
        case .cut: "scissors"
        case .paste: "doc.on.clipboard"
        case .selectAll: "selection.pin.in.out"
        case .copyLinkWithHighlight: "highlighter"
        case .share: "square.and.arrow.up"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .reload: "arrow.clockwise"
        case .stop: "xmark"
        case .toggleMediaControls: "slider.horizontal.3"
        case .toggleLoop: "repeat"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .pictureInPicture: "pip"
        case .inspect: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The contexts a layout can place this action in (what Settings offers).
    public var contexts: [RadialContext] {
        switch self {
        case .openLink, .openLinkInNewTab, .openLinkInPeek, .openLinkInSplit, .downloadLinkedFile, .copyLink: [.link]
        case .openImageInNewTab, .downloadImage, .copyImage, .copySubject, .lookUpImage: [.image]
        case .openFrameInNewTab: [.page]
        case .lookUp, .translate, .searchWeb, .copy, .copyLinkWithHighlight: [.selection, .editable]
        case .cut, .paste: [.editable]
        case .selectAll: [.editable, .page]
        case .share: [.link, .image, .selection, .editable, .page]
        case .back, .forward, .reload, .stop: [.page]
        case .downloadMedia, .copyMediaLink, .toggleMediaControls, .toggleLoop, .fullScreen, .pictureInPicture: [.media]
        case .inspect: RadialContext.allCases
        }
    }

    /// The ring a context starts with, before the user customises it.
    public static func defaultRing(for context: RadialContext) -> [RadialAction] {
        switch context {
        case .link: [.openLink, .openLinkInNewTab, .openLinkInPeek, .openLinkInSplit, .downloadLinkedFile, .copyLink, .share]
        case .image: [.openImageInNewTab, .downloadImage, .copyImage, .copySubject, .lookUpImage, .share]
        case .selection: [.lookUp, .translate, .searchWeb, .copy, .copyLinkWithHighlight, .share]
        case .editable: [.cut, .copy, .paste, .lookUp, .searchWeb, .translate, .share]
        case .media: [.toggleMediaControls, .pictureInPicture, .fullScreen, .toggleLoop, .downloadMedia, .copyMediaLink]
        case .page: [.back, .forward, .reload, .stop, .share, .selectAll, .inspect]
        }
    }

    private static let webKitIdentifiers: [String: RadialAction] = [
        "WKMenuItemIdentifierOpenLink": .openLink, "WKMenuItemIdentifierOpenLinkInNewWindow": .openLinkInNewTab,
        "WKMenuItemIdentifierDownloadLinkedFile": .downloadLinkedFile, "WKMenuItemIdentifierCopyLink": .copyLink,
        "WKMenuItemIdentifierOpenImageInNewWindow": .openImageInNewTab, "WKMenuItemIdentifierDownloadImage": .downloadImage,
        "WKMenuItemIdentifierCopyImage": .copyImage, "WKMenuItemIdentifierCopySubject": .copySubject,
        "WKMenuItemIdentifierRevealImage": .lookUpImage, "WKMenuItemIdentifierOpenFrameInNewWindow": .openFrameInNewTab,
        "WKMenuItemIdentifierLookUp": .lookUp, "WKMenuItemIdentifierTranslate": .translate, "WKMenuItemIdentifierSearchWeb": .searchWeb,
        "WKMenuItemIdentifierCopy": .copy, "WKMenuItemIdentifierCut": .cut, "WKMenuItemIdentifierPaste": .paste,
        "WKMenuItemIdentifierSelectAll": .selectAll, "WKMenuItemIdentifierCopyLinkWithHighlight": .copyLinkWithHighlight,
        "WKMenuItemIdentifierShareMenu": .share, "WKMenuItemIdentifierGoBack": .back, "WKMenuItemIdentifierGoForward": .forward,
        "WKMenuItemIdentifierReload": .reload, "WKMenuItemIdentifierStop": .stop,
        "WKMenuItemIdentifierDownloadMedia": .downloadMedia, "WKMenuItemIdentifierCopyMediaLink": .copyMediaLink,
        "WKMenuItemIdentifierShowMediaControls": .toggleMediaControls, "WKMenuItemIdentifierHideMediaControls": .toggleMediaControls,
        "WKMenuItemIdentifierToggleMediaLoop": .toggleLoop, "WKMenuItemIdentifierEnterFullScreen": .fullScreen,
        "WKMenuItemIdentifierExitFullScreen": .fullScreen, "WKMenuItemIdentifierPictureInPicture": .pictureInPicture,
        "WKMenuItemIdentifierInspectElement": .inspect,
        // Items Cosmos adds itself.
        "cosmos.openLinkInPeek": .openLinkInPeek, "cosmos.openLinkInSplit": .openLinkInSplit,
    ]

    /// Items whose identifier is only the name of the method that handles them are recognised by their title.
    private static let titles: [String: RadialAction] = [
        "cut": .cut, "copy": .copy, "paste": .paste, "select all": .selectAll, "back": .back, "forward": .forward,
        "reload": .reload, "reload page": .reload, "stop": .stop, "inspect element": .inspect,
    ]

    /// The action a WebKit menu item stands for, by its identifier and otherwise by its title.
    public static func resolve(identifier: String?, title: String) -> RadialAction? {
        if let identifier, let known = webKitIdentifiers[identifier] { return known }
        return titles[title.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}

/// One slice of the ring, or a group that opens a smaller ring of its own.
public struct RadialEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var action: RadialAction?
    public var title: String
    public var symbol: String?
    public var isEnabled: Bool
    public var children: [RadialEntry]

    public init(id: String, action: RadialAction? = nil, title: String, symbol: String? = nil, isEnabled: Bool = true, children: [RadialEntry] = []) {
        self.id = id; self.action = action; self.title = title; self.symbol = symbol; self.isEnabled = isEnabled; self.children = children
    }

    public var isGroup: Bool { !children.isEmpty }
}

public enum RadialLayout {
    /// The most slices a ring holds; with more, the last slice is "More" and holds the rest.
    public static let maxSlices = 8
    public static let moreID = "radial.more"

    /// The ring for a menu's entries (separators already removed, in WebKit's order).
    ///
    /// With a layout the user made, the ring is exactly what they chose, in their order, and everything else the system
    /// menu offered waits under "More". Without one (or when none of their choices is on this menu) the context's
    /// default comes first and WebKit's remaining items follow, up to what fits; the rest go under "More". Nothing the
    /// system menu offered is ever lost. (That is everything WebKit puts on its menu; the extras the system adds when the
    /// menu is drawn, such as Services, only exist in the system menu, which ⌥-click opens.)
    public static func ring(entries: [RadialEntry], context: RadialContext, custom: [RadialAction]?) -> [RadialEntry] {
        if let custom, !custom.isEmpty {
            let (placed, rest) = place(entries, custom)
            if !placed.isEmpty {
                // "More" takes a slice of its own unless nothing needs it.
                let needsMore = !rest.isEmpty || placed.count > maxSlices
                let shown = Array(placed.prefix(needsMore ? maxSlices - 1 : maxSlices))
                let overflow = Array(placed.dropFirst(shown.count)) + rest
                return overflow.isEmpty ? shown : shown + [more(overflow)]
            }
        }
        let (placed, rest) = place(entries, RadialAction.defaultRing(for: context))
        let all = placed + rest
        guard all.count > maxSlices else { return all }
        return Array(all.prefix(maxSlices - 1)) + [more(Array(all.dropFirst(maxSlices - 1)))]
    }

    /// The ring the Settings editor draws for a list of actions: what is on its slices and whether More is. A ring the
    /// user chose is exactly their actions with everything else the menu offers under More, so More is there whenever
    /// the menu has anything else, which it nearly always does. The default ring shows what fits and overflows into More.
    public static func preview(of actions: [RadialAction], customised: Bool) -> (shown: [RadialAction], hasMore: Bool, underMore: [RadialAction]) {
        if customised {
            let shown = Array(actions.prefix(maxSlices - 1))
            return (shown, true, Array(actions.dropFirst(shown.count)))
        }
        guard actions.count > maxSlices else { return (actions, false, []) }
        let shown = Array(actions.prefix(maxSlices - 1))
        return (shown, true, Array(actions.dropFirst(shown.count)))
    }

    /// The entries that stand for `actions`, in that order, and the entries that do not.
    private static func place(_ entries: [RadialEntry], _ actions: [RadialAction]) -> (placed: [RadialEntry], rest: [RadialEntry]) {
        var placed: [RadialEntry] = []
        var used: Set<String> = []
        for action in actions {
            if let entry = entries.first(where: { $0.action == action && !used.contains($0.id) }) {
                placed.append(entry)
                used.insert(entry.id)
            }
        }
        return (placed, entries.filter { !used.contains($0.id) })
    }

    private static func more(_ entries: [RadialEntry]) -> RadialEntry {
        RadialEntry(id: moreID, title: "More", symbol: "ellipsis", children: entries)
    }
}

/// Where slices are, and which one a pointer position selects. Angles run clockwise from the top; slice 0 is centred on
/// twelve o'clock. Points are in a y-down space (SwiftUI's), relative to the ring's centre unless stated.
public enum RadialGeometry {
    public static let innerRadius = 44.0
    public static let outerRadius = 132.0
    /// A pointer flicked past the ring still selects the slice it is heading for, up to this far from the centre.
    public static let reach = 420.0

    public static func sliceAngle(count: Int) -> Double { 2 * .pi / Double(max(1, count)) }

    /// The angle at the middle of slice `index`.
    public static func centerAngle(of index: Int, count: Int) -> Double { Double(index) * sliceAngle(count: count) }

    /// The offset from the ring's centre to the middle of a slice at `radius`.
    public static func offset(of index: Int, count: Int, radius: Double) -> CGPoint {
        let a = centerAngle(of: index, count: count)
        return CGPoint(x: sin(a) * radius, y: -cos(a) * radius)
    }

    /// The slice a pointer at `point` (relative to the centre) is over; nil in the hub or beyond `reach`.
    public static func slice(at point: CGPoint, count: Int, innerRadius: Double = innerRadius, reach: Double = reach) -> Int? {
        guard count > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let distance = hypot(Double(point.x), Double(point.y))
        guard distance >= innerRadius, distance <= reach else { return nil }
        var angle = atan2(Double(point.x), -Double(point.y))
        if angle < 0 { angle += 2 * .pi }
        let width = sliceAngle(count: count)
        return Int(((angle + width / 2).truncatingRemainder(dividingBy: 2 * .pi)) / width) % count
    }

    /// Moves the ring's centre so the whole ring stays inside the window, keeping `margin` clear of its edges. A window
    /// too small for the ring gets it in the middle.
    public static func clamp(center: CGPoint, in size: CGSize, margin: Double = 12, outerRadius: Double = outerRadius) -> CGPoint {
        func axis(_ value: Double, _ length: Double) -> Double {
            let low = margin + outerRadius, high = length - margin - outerRadius
            return low > high ? length / 2 : min(max(value, low), high)
        }
        guard center.x.isFinite, center.y.isFinite else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: axis(Double(center.x), Double(size.width)), y: axis(Double(center.y), Double(size.height)))
    }
}

/// The user's choices: whether the ring replaces the system menu, where it stays out of the way, and what is on it.
public struct RadialSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Sites where the page's right click is left as the system menu.
    public var disabledHosts: [String] = []
    /// Per context (by raw value), the actions on the ring in order.
    public var rings: [String: [String]] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, disabledHosts, rings }

    // A file written by another build must not lock anyone out: unknown or missing keys keep their defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decode([String].self, forKey: .disabledHosts) { disabledHosts = v.compactMap(LinkRule.normalizedHost) }
        if let v = try? c.decode([String: [String]].self, forKey: .rings) { rings = v }
    }

    /// Whether the ring should open for a page on `host`.
    public func isActive(on host: String?) -> Bool {
        guard enabled else { return false }
        guard let host = host.flatMap(LinkRule.normalizedHost) else { return true }
        return !disabledHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func isDisabled(host: String) -> Bool { disablingEntry(for: host) != nil }

    /// Switches the ring off for a site. Returns false when what was typed is not a site, or it is already off.
    @discardableResult
    public mutating func disable(host: String) -> Bool {
        guard let host = LinkRule.normalizedHost(host), !disabledHosts.contains(host) else { return false }
        disabledHosts.append(host)
        return true
    }

    /// The entry in the list that turns the ring off for `host`: the host itself or a site above it.
    public func disablingEntry(for host: String) -> String? {
        guard let host = LinkRule.normalizedHost(host) else { return nil }
        return disabledHosts.first { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Switches the ring back on for a site. Whatever entry turned it off goes, which can be one for the whole site
    /// above it (turning it back on for docs.google.com when google.com is off clears google.com).
    public mutating func enable(host: String) {
        guard let host = LinkRule.normalizedHost(host) else { return }
        disabledHosts.removeAll { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The actions the user chose for a context, in order; nil when it has not been customised.
    public func customRing(for context: RadialContext) -> [RadialAction]? {
        guard let names = rings[context.rawValue] else { return nil }
        var seen: Set<RadialAction> = []
        return names.compactMap { RadialAction(rawValue: $0) }.filter { seen.insert($0).inserted }
    }

    /// The ring a context shows: the user's, or the default.
    public func ring(for context: RadialContext) -> [RadialAction] {
        customRing(for: context) ?? RadialAction.defaultRing(for: context)
    }

    public mutating func setRing(_ actions: [RadialAction], for context: RadialContext) {
        rings[context.rawValue] = actions.map(\.rawValue)
    }

    public mutating func resetRing(for context: RadialContext) { rings[context.rawValue] = nil }

    public func isCustomised(_ context: RadialContext) -> Bool { rings[context.rawValue] != nil }

    /// The actions that could still be added to a context's ring: the ones that make sense there and are not on it.
    public func available(for context: RadialContext) -> [RadialAction] {
        let on = Set(ring(for: context))
        return RadialAction.allCases.filter { $0.contexts.contains(context) && !on.contains($0) }
    }

    /// Adds an action to the end of a context's ring (starting from the default if it was never customised). False when
    /// the action does not belong in that context or is already on it.
    @discardableResult
    public mutating func add(_ action: RadialAction, to context: RadialContext) -> Bool {
        var actions = ring(for: context)
        guard action.contexts.contains(context), !actions.contains(action) else { return false }
        actions.append(action)
        setRing(actions, for: context)
        return true
    }

    /// Takes the action at `index` off a context's ring. A ring is never left empty (an empty one would only fall back
    /// to the default), so the last action stays.
    @discardableResult
    public mutating func remove(at index: Int, from context: RadialContext) -> Bool {
        var actions = ring(for: context)
        guard actions.indices.contains(index), actions.count > 1 else { return false }
        actions.remove(at: index)
        setRing(actions, for: context)
        return true
    }

    /// Moves the action at `index` by `delta` places along the ring; false when it is already at that end.
    @discardableResult
    public mutating func move(at index: Int, by delta: Int, in context: RadialContext) -> Bool {
        var actions = ring(for: context)
        guard actions.indices.contains(index) else { return false }
        let target = index + delta
        guard actions.indices.contains(target), target != index else { return false }
        actions.insert(actions.remove(at: index), at: target)
        setRing(actions, for: context)
        return true
    }
}
