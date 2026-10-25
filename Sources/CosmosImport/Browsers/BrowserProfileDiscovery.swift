import Foundation

/// Finds the browser profiles on this Mac. Nothing here throws: a browser that is not installed, a profile with
/// nothing to import or an unreadable database simply yields fewer (or count-less) profiles.
public enum BrowserProfileDiscovery {
    /// All profiles of `browsers` under `home`, grouped by browser in the order given, default profile first.
    /// `includeCounts` runs `COUNT(*)` queries on copies of the databases; pass `false` for a quick listing.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                browsers: [BrowserKind] = BrowserKind.allCases,
                                includeCounts: Bool = true, workDirectory: URL? = nil) -> [BrowserProfile] {
        browsers.flatMap { profiles(of: $0, root: $0.dataRoot(home: home), includeCounts: includeCounts, workDirectory: workDirectory) }
    }

    /// The profiles of one browser whose data lives under `root` (see `BrowserKind.dataRoot(home:)`).
    public static func profiles(of browser: BrowserKind, root: URL, includeCounts: Bool = true, workDirectory: URL? = nil) -> [BrowserProfile] {
        switch browser.family {
        case .chromium: return chromiumProfiles(browser, root: root, includeCounts: includeCounts, workDirectory: workDirectory)
        case .firefox: return firefoxProfiles(root: root, includeCounts: includeCounts, workDirectory: workDirectory)
        case .safari: return safariProfiles(root: root, includeCounts: includeCounts, workDirectory: workDirectory)
        }
    }

    // MARK: Chromium

    private static func chromiumProfiles(_ browser: BrowserKind, root: URL, includeCounts: Bool, workDirectory: URL?) -> [BrowserProfile] {
        guard BrowserFileAccess.directoryState(of: root) == .readable else { return [] }
        let state = localState(root)
        let fm = FileManager.default
        var candidates: [(dir: String, url: URL)] = []
        if fm.fileExists(atPath: ChromiumImporter.historyFile(in: root).path) || fm.fileExists(atPath: ChromiumImporter.bookmarksFile(in: root).path) {
            candidates.append(("Default", root))   // Opera keeps its one profile in the root itself
        }
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where name == "Default" || name.hasPrefix("Profile ") || state.names[name] != nil {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                candidates.append((name, root.appendingPathComponent(name, isDirectory: true)))
            }
        }

        var profiles: [BrowserProfile] = []
        for (dir, url) in candidates {
            let history = BrowserFileAccess.state(of: ChromiumImporter.historyFile(in: url))
            let bookmarks = BrowserFileAccess.state(of: ChromiumImporter.bookmarksFile(in: url))
            var kinds: Set<BrowserDataKind> = []
            if history != .missing { kinds.insert(.history) }
            if bookmarks != .missing { kinds.insert(.bookmarks) }
            guard !kinds.isEmpty else { continue }
            let denied = history == .denied || bookmarks == .denied
            let name = state.names[dir].flatMap { $0.isEmpty ? nil : $0 } ?? dir
            profiles.append(BrowserProfile(browser: browser, name: name, directory: url, dataKinds: kinds,
                                           approximateCounts: includeCounts && !denied ? ChromiumImporter.approximateCounts(profileDirectory: url, workDirectory: workDirectory) : [:],
                                           accessDenied: denied))
        }
        let defaultDir = [state.lastUsed, "Default"].compactMap { $0 }.first { d in candidates.contains { $0.dir == d } } ?? candidates.first?.dir
        return markDefault(profiles, where: { p in candidates.first { $0.url == p.directory }?.dir == defaultDir })
    }

    /// `profile.info_cache` (directory -> display name) and `profile.last_used` from Chromium's `Local State`.
    private static func localState(_ root: URL) -> (names: [String: String], lastUsed: String?) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let profile = json["profile"] as? [String: Any] else { return ([:], nil) }
        var names: [String: String] = [:]
        for (dir, info) in profile["info_cache"] as? [String: Any] ?? [:] {
            if let name = (info as? [String: Any])?["name"] as? String { names[dir] = name } else { names[dir] = "" }
        }
        return (names, profile["last_used"] as? String)
    }

    // MARK: Firefox

    private static func firefoxProfiles(root: URL, includeCounts: Bool, workDirectory: URL?) -> [BrowserProfile] {
        let fm = FileManager.default
        let iniDirectory = [root, root.deletingLastPathComponent()].first { fm.fileExists(atPath: $0.appendingPathComponent("profiles.ini").path) }
        var entries: [(name: String, url: URL, isDefault: Bool)] = []
        if let iniDirectory, let text = try? String(contentsOf: iniDirectory.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            let sections = parseINI(text)
            let installDefaults = Set(sections.filter { $0.name.hasPrefix("Install") }.compactMap { $0.values["Default"] })
            for s in sections where s.name.hasPrefix("Profile") {
                guard let path = s.values["Path"], !path.isEmpty else { continue }
                let url = s.values["IsRelative"] == "0" ? URL(fileURLWithPath: path, isDirectory: true) : iniDirectory.appendingPathComponent(path, isDirectory: true)
                entries.append((s.values["Name"] ?? url.lastPathComponent, url, installDefaults.contains(path) || s.values["Default"] == "1"))
            }
        } else {
            for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
                let display = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
                entries.append((display, root.appendingPathComponent(name, isDirectory: true), false))
            }
        }

        var profiles: [BrowserProfile] = []
        for e in entries {
            let places = BrowserFileAccess.state(of: FirefoxImporter.placesFile(in: e.url))
            guard places != .missing else { continue }
            profiles.append(BrowserProfile(browser: .firefox, name: e.name, directory: e.url, isDefault: e.isDefault,
                                           dataKinds: [.history, .bookmarks],
                                           approximateCounts: includeCounts && places == .readable ? FirefoxImporter.approximateCounts(profileDirectory: e.url, workDirectory: workDirectory) : [:],
                                           accessDenied: places == .denied))
        }
        if !profiles.contains(where: \.isDefault), !profiles.isEmpty { profiles[0].isDefault = true }
        return defaultFirst(profiles)
    }

    struct INISection { var name: String; var values: [String: String] }

    static func parseINI(_ text: String) -> [INISection] {
        var sections: [INISection] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append(INISection(name: String(line.dropFirst().dropLast()), values: [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1].values[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return sections
    }

    // MARK: Safari

    private static func safariProfiles(root: URL, includeCounts: Bool, workDirectory: URL?) -> [BrowserProfile] {
        let directory = BrowserFileAccess.directoryState(of: root)
        guard directory != .missing else { return [] }
        let history = BrowserFileAccess.state(of: SafariImporter.historyFile(in: root))
        let bookmarks = BrowserFileAccess.state(of: SafariImporter.bookmarksFile(in: root))
        // Behind the privacy gate we cannot tell what exists; Safari always has both.
        let denied = directory == .denied || history == .denied || bookmarks == .denied
        var kinds: Set<BrowserDataKind> = []
        if history != .missing || denied { kinds.insert(.history) }
        if bookmarks != .missing || denied { kinds.insert(.bookmarks) }
        guard !kinds.isEmpty else { return [] }
        return [BrowserProfile(browser: .safari, name: "Default", directory: root, isDefault: true, dataKinds: kinds,
                               approximateCounts: includeCounts && !denied ? SafariImporter.approximateCounts(directory: root, workDirectory: workDirectory) : [:],
                               accessDenied: denied)]
    }

    private static func markDefault(_ profiles: [BrowserProfile], where isDefault: (BrowserProfile) -> Bool) -> [BrowserProfile] {
        defaultFirst(profiles.map { p -> BrowserProfile in var q = p; q.isDefault = isDefault(p); return q })
    }

    private static func defaultFirst(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        profiles.filter(\.isDefault) + profiles.filter { !$0.isDefault }
    }
}
