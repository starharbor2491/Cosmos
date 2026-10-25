import Foundation

/// How a browser stores its profile on disk; one importer per family.
public enum BrowserFamily: String, Codable, Sendable {
    case chromium, firefox, safari
}

/// The browsers Cosmos can import from.
public enum BrowserKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case arc, chrome, brave, edge, vivaldi, opera, chromium, firefox, safari

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .chromium: return "Chromium"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    public var family: BrowserFamily {
        switch self {
        case .firefox: return .firefox
        case .safari: return .safari
        default: return .chromium
        }
    }

    /// Where the browser keeps its profiles on macOS, for the given home directory.
    ///
    /// For Chromium browsers this is the "User Data" directory holding `Local State` and the profile folders (Opera
    /// keeps its single profile directly in it). For Firefox it is `Firefox/Profiles`; `profiles.ini` sits next to it.
    public func dataRoot(home: URL) -> URL {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch self {
        case .arc: return support.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .chrome: return support.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .brave: return support.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .edge: return support.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .vivaldi: return support.appendingPathComponent("Vivaldi", isDirectory: true)
        case .opera: return support.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
        case .chromium: return support.appendingPathComponent("Chromium", isDirectory: true)
        case .firefox: return support.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        case .safari: return home.appendingPathComponent("Library/Safari", isDirectory: true)
        }
    }

    /// `dataRoot(home:)` for the current user.
    public var defaultDataRoot: URL { dataRoot(home: FileManager.default.homeDirectoryForCurrentUser) }
}

/// The kinds of data Cosmos imports from a browser.
public enum BrowserDataKind: String, CaseIterable, Codable, Hashable, Sendable {
    case history, bookmarks
}
