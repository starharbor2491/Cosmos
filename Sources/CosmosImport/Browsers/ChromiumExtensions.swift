import Foundation

/// An unpacked extension found in a Chromium-family profile (`<profile>/Extensions/<id>/<version>/`).
public struct DiscoveredExtension: Identifiable, Hashable, Sendable {
    /// The Chrome Web Store id (32 letters a to p), which is also the folder name.
    public var id: String
    public var name: String
    public var version: String
    public var manifestVersion: Int
    /// The folder that holds `manifest.json`.
    public var directory: URL
    public var browser: BrowserKind
    public var profileName: String
    /// API permissions the manifest asks for (`storage`, `tabs`, ...).
    public var permissions: [String]
    /// Sites the extension asks to read and change (`https://*.example.com/*`, `<all_urls>`).
    public var hostAccess: [String]

    /// "Arc" or "Google Chrome (Profile 1)".
    public var source: String { profileName.isEmpty || profileName == "Default" ? browser.displayName : "\(browser.displayName) (\(profileName))" }
}

/// Reads the extensions a Chromium browser has installed, without touching the browser's files.
public enum ChromiumExtensionScanner {
    /// Every extension of every Chromium-family profile under `home`.
    public static func scanAll(home: URL = FileManager.default.homeDirectoryForCurrentUser, browsers: [BrowserKind] = BrowserKind.allCases) -> [DiscoveredExtension] {
        let chromium = browsers.filter { $0.family == .chromium }
        return BrowserProfileDiscovery.discover(home: home, browsers: chromium, includeCounts: false).flatMap(scan(profile:))
    }

    public static func scan(profile: BrowserProfile) -> [DiscoveredExtension] {
        scan(extensionsDirectory: profile.directory.appendingPathComponent("Extensions", isDirectory: true), browser: profile.browser, profileName: profile.name)
    }

    public static func scan(extensionsDirectory: URL, browser: BrowserKind, profileName: String) -> [DiscoveredExtension] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: extensionsDirectory.path) else { return [] }
        var found: [DiscoveredExtension] = []
        for id in ids.sorted() where ChromeWebStore.isExtensionID(id) {
            let idDir = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
            // Several versions can sit side by side while an update settles: the newest one is the live one.
            let versions = ((try? fm.contentsOfDirectory(atPath: idDir.path)) ?? [])
                .filter { fm.fileExists(atPath: idDir.appendingPathComponent($0).appendingPathComponent("manifest.json").path) }
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            guard let newest = versions.first else { continue }
            let dir = idDir.appendingPathComponent(newest, isDirectory: true)
            guard let manifest = readManifest(dir) else { continue }
            // Themes and hosted/packaged apps are not extensions in the sense Cosmos can run.
            if manifest["theme"] != nil || manifest["app"] != nil { continue }
            let mv = (manifest["manifest_version"] as? Int) ?? 0
            let (api, hosts) = splitPermissions(manifest)
            found.append(DiscoveredExtension(
                id: id, name: displayName(manifest: manifest, directory: dir) ?? id, version: (manifest["version"] as? String) ?? newest,
                manifestVersion: mv, directory: dir, browser: browser, profileName: profileName, permissions: api, hostAccess: hosts))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func readManifest(_ directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        // Chrome tolerates a byte-order mark and // comments in manifests; JSONSerialization does not.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// The manifest's `name`, resolving `__MSG_key__` through `_locales/<default_locale>/messages.json`.
    public static func displayName(manifest: [String: Any], directory: URL) -> String? {
        guard let raw = manifest["name"] as? String, !raw.isEmpty else { return nil }
        return localized(raw, manifest: manifest, directory: directory)
    }

    static func localized(_ text: String, manifest: [String: Any], directory: URL) -> String {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = String(text.dropFirst(6).dropLast(2)).lowercased()
        let preferred = (Locale.preferredLanguages.first ?? "en").replacingOccurrences(of: "-", with: "_")
        let candidates = [preferred, String(preferred.prefix(2)), manifest["default_locale"] as? String, "en", "en_US"].compactMap { $0 }
        for locale in candidates {
            let file = directory.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // Message keys are case-insensitive.
            for (k, v) in messages where k.lowercased() == key {
                if let message = (v as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
            }
        }
        return text
    }

    /// Splits `permissions`, `optional_permissions` excluded, from the host patterns found in `permissions` (MV2) and
    /// `host_permissions` (MV3), plus the `content_scripts` match patterns.
    static func splitPermissions(_ manifest: [String: Any]) -> (api: [String], hosts: [String]) {
        var api: [String] = []
        var hosts: [String] = []
        func add(_ entry: String) {
            if entry == "<all_urls>" || entry.contains("://") || entry.hasPrefix("*") { if !hosts.contains(entry) { hosts.append(entry) } }
            else if !api.contains(entry) { api.append(entry) }
        }
        for entry in (manifest["permissions"] as? [Any]) ?? [] { if let s = entry as? String { add(s) } }
        for entry in (manifest["host_permissions"] as? [Any]) ?? [] { if let s = entry as? String, !hosts.contains(s) { hosts.append(s) } }
        for script in (manifest["content_scripts"] as? [[String: Any]]) ?? [] {
            for m in (script["matches"] as? [String]) ?? [] where !hosts.contains(m) { hosts.append(m) }
        }
        return (api, hosts)
    }
}
