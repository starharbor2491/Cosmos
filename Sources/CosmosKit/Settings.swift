import Foundation
import CosmosCore

/// User preferences, persisted as `settings.json`.
public struct Settings: Codable, Equatable {
    public enum AppearanceMode: String, Codable, CaseIterable {
        case system, light, dark
    }

    public enum SidebarSide: String, Codable { case left, right }

    public var searchEngineID: String = SearchCatalog.bundled.defaultEngine
    public var appearance: AppearanceMode = .system
    public var sidebarWidth: Double = 248
    public var sidebarSide: SidebarSide = .left
    /// Slide the sidebar over the page when the pointer touches the window edge while it is hidden.
    public var revealSidebarOnHover = true
    public var adBlockingEnabled = true
    public var enabledFilterLists: [String] = ["easylist", "easyprivacy", "fanboy-cookiemonster"]
    public var autoPictureInPicture = true
    public var restoreTabsOnLaunch = true
    public var showSearchSuggestions = true
    /// Pinned tabs and Favorites open links to other sites in a Peek instead of navigating away.
    public var peekFromPinned = true
    /// Per-host answers to camera / microphone / location prompts.
    public var permissionDecisions: [String: Bool] = [:]
    /// Hosts where blocking is turned off from the Site Control Center.
    public var adBlockAllowlist: [String] = []
    public var hasCompletedOnboarding = false
    public var memorySaverMinutes: Int = 30
    public var showStatusBubble = true
    public var closeWindowOnLastTab = false
    /// Ticks under the finger on a Force Touch trackpad (a drop landing, a space changing).
    public var trackpadHaptics = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case searchEngineID, appearance, sidebarWidth, sidebarSide, revealSidebarOnHover, adBlockingEnabled, enabledFilterLists
        case autoPictureInPicture, restoreTabsOnLaunch, showSearchSuggestions, peekFromPinned, permissionDecisions
        case adBlockAllowlist, hasCompletedOnboarding, memorySaverMinutes, showStatusBubble, closeWindowOnLastTab, trackpadHaptics
    }

    // Tolerant decoding: a settings file written by an older/newer build must never lock the user out.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ target: inout T) { if let v = try? c.decode(T.self, forKey: key) { target = v } }
        get(.searchEngineID, &searchEngineID); get(.appearance, &appearance); get(.sidebarWidth, &sidebarWidth)
        get(.sidebarSide, &sidebarSide); get(.revealSidebarOnHover, &revealSidebarOnHover)
        get(.adBlockingEnabled, &adBlockingEnabled); get(.enabledFilterLists, &enabledFilterLists)
        get(.autoPictureInPicture, &autoPictureInPicture); get(.restoreTabsOnLaunch, &restoreTabsOnLaunch)
        get(.showSearchSuggestions, &showSearchSuggestions); get(.peekFromPinned, &peekFromPinned)
        get(.permissionDecisions, &permissionDecisions); get(.adBlockAllowlist, &adBlockAllowlist)
        get(.hasCompletedOnboarding, &hasCompletedOnboarding); get(.memorySaverMinutes, &memorySaverMinutes)
        get(.showStatusBubble, &showStatusBubble); get(.closeWindowOnLastTab, &closeWindowOnLastTab)
        get(.trackpadHaptics, &trackpadHaptics)
    }
}
