import AppKit
import CosmosCore

public enum CommandBarMode: Equatable {
    /// ⌘T: Enter opens a new tab.
    case newTab
    /// ⌘L: Enter navigates the current tab.
    case currentTab
}

/// Modal-ish panels drawn over the page. At most one is up at a time.
public enum Overlay: Equatable {
    case commandBar(CommandBarMode)
    case find
    case archive
    case history
    case downloads
    case themeEditor(UUID)
    case boosts
    case welcome
    case siteControls
    case shortcuts
}

/// A link opened in Peek: a floating, disposable page over the current tab.
@MainActor
@Observable
public final class PeekSession: Identifiable {
    public let id = UUID()
    public let runtime: TabRuntime
    public let openedFrom: UUID?
    init(runtime: TabRuntime, openedFrom: UUID?) { self.runtime = runtime; self.openedFrom = openedFrom }
}

public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public var text: String
    public var symbol: String
    public var actionTitle: String?
    public static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    var action: (() -> Void)?
}

/// Everything that belongs to one window rather than to the whole browser: which space is showing, which tab is
/// selected in each space, panel state.
@MainActor
@Observable
public final class WindowState: Identifiable {
    public let id = UUID()
    public let isIncognito: Bool
    public var focusedSpaceID: UUID { didSet { radial = nil } }
    /// Selected sidebar item per space (a tab, or a split).
    public var selection: [UUID: UUID] = [:] { didSet { radial = nil } }
    public var sidebarVisible = true
    public var sidebarWidth: Double
    /// True while the hidden sidebar is slid over the page because the pointer touched the window edge.
    public var sidebarPeeking = false
    public var overlay: Overlay? { didSet { radial = nil } }
    public var peek: PeekSession? { didSet { radial = nil } }
    /// The radial menu that is open over the page, if any. It belongs to the page it was opened over, so a change of tab,
    /// space, overlay or Peek puts it away.
    public var radial: RadialSession?
    public var findQuery = ""
    public var findHadMatch = true
    public var toast: Toast?
    /// Most recently selected items, newest first (⌃Tab order).
    public var recent: [UUID] = []
    /// -1 / +1 while a space switch animates, so content slides the right way.
    public var spaceDirection = 1
    public var isFullScreen = false
    /// Bumped to ask the command bar's text field to take focus (e.g. ⌘L pressed while it is already open).
    public var commandBarFocusToken = 0
    /// The tab in this window that currently has a Pending `commandBar` navigation typed by the user.
    public var pendingTypedNavigation = false
    /// Hover status bubble text (bottom-left of the page).
    public var statusText: String?

    /// The widths the sidebar's drag handle allows. A width read from a file is brought into it too: a sidebar wider
    /// than the window cannot be dragged back, because its handle is off screen.
    public static let sidebarWidthRange = 190.0...420.0

    public init(focusedSpaceID: UUID, sidebarWidth: Double, isIncognito: Bool = false) {
        self.focusedSpaceID = focusedSpaceID
        self.sidebarWidth = sidebarWidth.isFinite
            ? min(max(sidebarWidth, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound) : 248
        self.isIncognito = isIncognito
    }

    public var selectedItemID: UUID? {
        get { selection[focusedSpaceID] }
        set { selection[focusedSpaceID] = newValue }
    }

    public func showToast(_ text: String, symbol: String = "checkmark.circle.fill", actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let t = Toast(text: text, symbol: symbol, actionTitle: actionTitle, action: action)
        toast = t
        let id = t.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(actionTitle == nil ? 2.2 : 5))
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    func noteSelected(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 60 { recent.removeLast(recent.count - 60) }
    }
}

/// The part of window state worth keeping between launches.
struct SessionState: Codable {
    struct Window: Codable {
        var focusedSpaceID: UUID
        var selection: [UUID: UUID]
        var sidebarVisible: Bool
        var sidebarWidth: Double
    }
    var windows: [Window] = []
}
