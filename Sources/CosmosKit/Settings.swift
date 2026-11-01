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
    /// Warn before opening a page from a site on a public malware or phishing list (Settings ▸ Engine).
    public var warnAboutDangerousSites = true
    /// Cosmos asks whether to keep a password typed into a site's sign-in form (Settings ▸ Passwords).
    public var offerToSavePasswords = true
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
    /// The ring that replaces the page's right-click menu (see `RadialMenu` in CosmosCore).
    public var radialMenu = RadialSettings()
    /// The small browser under an icon in the menu bar (see `MenuBar` in CosmosCore).
    public var menuBar = MenuBarSettings()
    /// The page engine's own settings (Chromium's, folded into Cosmos's Settings). They apply when a profile's engine starts.
    public var engine = EngineSettings()
    /// The features switched off that have no setting of their own elsewhere (see `isOn`), by name, so a name this build
    /// does not know is kept rather than failing the file.
    public var disabledFeatures: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case searchEngineID, appearance, sidebarWidth, sidebarSide, revealSidebarOnHover, adBlockingEnabled, enabledFilterLists
        case autoPictureInPicture, restoreTabsOnLaunch, showSearchSuggestions, peekFromPinned, permissionDecisions
        case adBlockAllowlist, hasCompletedOnboarding, memorySaverMinutes, showStatusBubble, closeWindowOnLastTab, trackpadHaptics, radialMenu, menuBar
        case engine, warnAboutDangerousSites, offerToSavePasswords, disabledFeatures
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
        get(.trackpadHaptics, &trackpadHaptics); get(.radialMenu, &radialMenu); get(.menuBar, &menuBar)
        get(.engine, &engine); get(.warnAboutDangerousSites, &warnAboutDangerousSites)
        get(.offerToSavePasswords, &offerToSavePasswords); get(.disabledFeatures, &disabledFeatures)
    }
}

extension Settings {
    /// Whether a feature is on. Those that already had a switch of their own keep it, so the two places agree.
    public func isOn(_ feature: Feature) -> Bool {
        switch feature {
        case .revealSidebar: revealSidebarOnHover
        case .radialMenu: radialMenu.enabled
        case .pictureInPicture: autoPictureInPicture
        case .statusBubble: showStatusBubble
        case .adBlocking: adBlockingEnabled
        case .dangerousSites: warnAboutDangerousSites
        case .searchSuggestions: showSearchSuggestions
        case .menuBarBrowser: menuBar.enabled
        case .haptics: trackpadHaptics
        case .spaceSwipe, .peek, .boosts, .extensions, .utilities, .passwords: !disabledFeatures.contains(feature.rawValue)
        }
    }

    public mutating func set(_ feature: Feature, on: Bool) {
        switch feature {
        case .revealSidebar: revealSidebarOnHover = on
        case .radialMenu: radialMenu.enabled = on
        case .pictureInPicture: autoPictureInPicture = on
        case .statusBubble: showStatusBubble = on
        case .adBlocking: adBlockingEnabled = on
        case .dangerousSites: warnAboutDangerousSites = on
        case .searchSuggestions: showSearchSuggestions = on
        case .menuBarBrowser: menuBar.enabled = on
        case .haptics: trackpadHaptics = on
        case .spaceSwipe, .peek, .boosts, .extensions, .utilities, .passwords:
            if on { disabledFeatures.remove(feature.rawValue) } else { disabledFeatures.insert(feature.rawValue) }
        }
    }

    /// The features that are on, for telling when one has changed.
    public var featuresOn: [Feature] { Feature.allCases.filter(isOn) }
}
