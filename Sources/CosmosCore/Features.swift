/// A part of Cosmos that can be switched off as a whole (Settings ▸ Features). One that is off has no buttons, menu items,
/// Command Bar commands, shortcuts or radial slices, and does no work in the background; switched on again it is as it
/// was, with what it had kept (Boosts, extensions, saved passwords).
public enum Feature: String, CaseIterable, Codable, Sendable, Identifiable {
    // Sidebar
    case spaceSwipe, revealSidebar
    // Pages
    case peek, boosts, extensions, utilities, radialMenu, pictureInPicture, statusBubble
    // Privacy and safety
    case adBlocking, dangerousSites, passwords, searchSuggestions
    // Elsewhere
    case menuBarBrowser, haptics

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case sidebar, pages, privacy, elsewhere
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .sidebar: "Sidebar"
            case .pages: "Pages"
            case .privacy: "Privacy and safety"
            case .elsewhere: "Around the Mac"
            }
        }
        public var features: [Feature] { Feature.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .spaceSwipe, .revealSidebar: .sidebar
        case .peek, .boosts, .extensions, .utilities, .radialMenu, .pictureInPicture, .statusBubble: .pages
        case .adBlocking, .dangerousSites, .passwords, .searchSuggestions: .privacy
        case .menuBarBrowser, .haptics: .elsewhere
        }
    }

    public var title: String {
        switch self {
        case .spaceSwipe: "Swipe between spaces"
        case .revealSidebar: "Show the hidden sidebar at the window's edge"
        case .peek: "Peek"
        case .boosts: "Boosts"
        case .extensions: "Extensions"
        case .utilities: "Utilities rail"
        case .radialMenu: "Radial menu"
        case .pictureInPicture: "Picture in Picture on leaving a video"
        case .statusBubble: "Link preview at the bottom of the page"
        case .adBlocking: "Ad and tracker blocking"
        case .dangerousSites: "Dangerous-site warnings"
        case .passwords: "Save and fill passwords"
        case .searchSuggestions: "Search suggestions"
        case .menuBarBrowser: "Menu-bar browser"
        case .haptics: "Trackpad haptics"
        }
    }

    /// One line on what it does, and what goes when it is off.
    public var detail: String {
        switch self {
        case .spaceSwipe: "Two fingers across the sidebar move to the next space or the Library."
        case .revealSidebar: "With the sidebar hidden, touching the left edge slides it over the page."
        case .peek: "A page over the current one for a quick look (Open in Peek, links from pinned tabs). Off, they open as tabs."
        case .boosts: "Your own colours, fonts and scripts for sites. Off, sites look as they come; your Boosts are kept."
        case .extensions: "Chrome extensions and their buttons, popups and shortcuts. Off, none of them run; they stay installed."
        case .utilities: "The column of tools at the window's right: Translate, Zoom, Downloads, Passwords, This Site."
        case .radialMenu: "A ring of actions on right-click. Off, right-click shows the standard menu."
        case .pictureInPicture: "A playing video follows you into a small window when you switch tabs."
        case .statusBubble: "Where a link goes, shown while the pointer is over it."
        case .adBlocking: "Ads and trackers are stopped before they load, with the lists in Blocking."
        case .dangerousSites: "A warning before opening a site known for malware or phishing."
        case .passwords: "Offers to save sign-ins and fills them in. Off, saved passwords stay in Settings ▸ Passwords."
        case .searchSuggestions: "The search engine suggests searches as you type in the Command Bar."
        case .menuBarBrowser: "A small browser under an icon in the menu bar."
        case .haptics: "A tick under the finger when a swipe will change page, and on other moves."
        }
    }

    public var symbol: String {
        switch self {
        case .spaceSwipe: "hand.draw"
        case .revealSidebar: "sidebar.left"
        case .peek: "rectangle.on.rectangle"
        case .boosts: "paintbrush.pointed"
        case .extensions: "puzzlepiece.extension"
        case .utilities: "sidebar.right"
        case .radialMenu: "circle.circle"
        case .pictureInPicture: "pip"
        case .statusBubble: "text.bubble"
        case .adBlocking: "shield.lefthalf.filled"
        case .dangerousSites: "exclamationmark.shield"
        case .passwords: "key"
        case .searchSuggestions: "magnifyingglass"
        case .menuBarBrowser: "menubar.rectangle"
        case .haptics: "hand.tap"
        }
    }
}
