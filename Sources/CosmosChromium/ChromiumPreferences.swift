import Foundation
import CosmosCore

/// Writes Cosmos's settings into the files Chromium reads as it starts and as a profile opens (a profile's `Preferences`
/// and the browser's `Local State`), the same keys Chromium's own Settings page writes. Neither is open when this happens,
/// so nothing overwrites it.
enum ChromiumPreferences {
    static func flags(settings: EngineSettings) -> [String] {
        var flags: [String] = []
        if !settings.hardwareAcceleration { flags.append("--disable-gpu") }
        return flags
    }

    static func languages(_ settings: EngineSettings, system: [String] = Locale.preferredLanguages) -> String {
        let list = settings.languages.isEmpty ? system : settings.languages
        var out: [String] = []
        for tag in list {
            // Chromium wants "en-US,en": a region's language follows it, each once.
            let t = tag.replacingOccurrences(of: "_", with: "-")
            if !out.contains(t) { out.append(t) }
            if let base = t.split(separator: "-").first.map(String.init), base != t, !out.contains(base), !list.contains(base) { out.append(base) }
        }
        return out.isEmpty ? "en-US,en" : out.joined(separator: ",")
    }

    /// What goes into a profile's `Preferences`. Without `keepsHistory`, Chromium keeps no history of its own there (Cosmos
    /// keeps the one people see, and only the default profile can clear Chromium's).
    static func preferences(_ s: EngineSettings, keepsHistory: Bool, system: [String] = Locale.preferredLanguages) -> [String: Any] {
        func ask(_ a: EngineSettings.Ask) -> Int { a == .ask ? 3 : 2 }
        var fonts: [String: Any] = [:]
        if !s.standardFont.isEmpty { fonts["standard"] = ["Zyyy": s.standardFont] }
        if !s.serifFont.isEmpty { fonts["serif"] = ["Zyyy": s.serifFont] }
        if !s.sansSerifFont.isEmpty { fonts["sansserif"] = ["Zyyy": s.sansSerifFont] }
        if !s.fixedFont.isEmpty { fonts["fixed"] = ["Zyyy": s.fixedFont] }
        var webprefs: [String: Any] = ["default_font_size": s.defaultFontSize, "default_fixed_font_size": s.defaultFixedFontSize,
                                       "minimum_font_size": s.minimumFontSize, "minimum_logical_font_size": max(6, s.minimumFontSize)]
        if !fonts.isEmpty { webprefs["fonts"] = fonts }
        return [
            // Pages are drawn at the screen's own scale: 100% (level 0) by default.
            "partition": ["default_zoom_level": ["x": 0.0]],
            "profile": [
                "cookie_controls_mode": s.cookies == .allowAll ? 0 : (s.cookies == .blockThirdPartyInPrivate ? 1 : 2),
                "block_third_party_cookies": s.cookies == .blockThirdParty,
                "default_content_setting_values": [
                    "javascript": s.javaScript ? 1 : 2,
                    "images": s.images ? 1 : 2,
                    "popups": s.popups ? 1 : 2,
                    "sound": s.sound ? 1 : 2,
                    "automatic_downloads": ask(s.automaticDownloads),
                    "notifications": ask(s.notifications),
                    "geolocation": ask(s.location),
                    "media_stream_camera": ask(s.camera),
                    "media_stream_mic": ask(s.microphone),
                    "clipboard": ask(s.clipboard),
                ],
                // Chromium's own password and card prompts have nowhere to show here.
                "password_manager_enabled": false,
            ],
            "credentials_enable_service": false,
            "autofill": ["profile_enabled": false, "credit_card_enabled": false],
            "enable_do_not_track": s.doNotTrack,
            "net": ["network_prediction_options": s.preloadPages ? 0 : 2],
            "https_only_mode_enabled": s.httpsFirst,
            "webrtc": ["ip_handling_policy": ["standard": "default", "publicInterfaceOnly": "default_public_interface_only",
                                              "disableNonProxiedUDP": "disable_non_proxied_udp"][s.webRTC.rawValue]!],
            "intl": ["accept_languages": languages(s, system: system), "selected_languages": languages(s, system: system)],
            "webkit": ["webprefs": webprefs],
            "translate": ["enabled": false],
            "download": ["prompt_for_download": false, "directory_upgrade": true],
            "browser": ["has_seen_welcome_page": true, "check_default_browser": false],
            "history": ["saving_disabled": !keepsHistory],
        ]
    }

    /// What a site was allowed or refused, kept by Chromium from the last run, that Cosmos asks the user about: Cosmos
    /// puts the user's decisions back as pages open, so one taken back since is not left in place.
    static let decidedPermissions = ["geolocation", "notifications", "media_stream_camera", "media_stream_mic"]

    /// What goes into `Local State` (settings for the whole Chromium, not one profile).
    static func localState(_ s: EngineSettings) -> [String: Any] {
        var dns: [String: Any] = ["mode": s.secureDNS.rawValue]
        if s.secureDNS == .secure, !s.secureDNSTemplate.isEmpty { dns["templates"] = s.secureDNSTemplate }
        return ["dns_over_https": dns, "hardware_acceleration_mode": ["enabled": s.hardwareAcceleration]]
    }

    /// Writes `patch` over `base`, key by key, keeping everything `patch` does not name.
    static func merge(_ patch: [String: Any], into base: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch {
            if let inner = value as? [String: Any], let existing = out[key] as? [String: Any] {
                out[key] = merge(inner, into: existing)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// Writes a profile's settings into its `Preferences` (in the profile's own folder), and with `root`, the whole
    /// browser's into `Local State` there.
    static func prepare(profile: URL, root: URL?, settings: EngineSettings, keepsHistory: Bool) {
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        update(profile.appendingPathComponent("Preferences"), with: preferences(settings, keepsHistory: keepsHistory)) { existing in
            var existing = existing
            if var p = existing["profile"] as? [String: Any], var c = p["content_settings"] as? [String: Any],
               var exceptions = c["exceptions"] as? [String: Any] {
                for kind in decidedPermissions { exceptions[kind] = nil }
                c["exceptions"] = exceptions
                p["content_settings"] = c
                existing["profile"] = p
            }
            return existing
        }
        if let root { update(root.appendingPathComponent("Local State"), with: localState(settings)) }
    }

    private static func update(_ file: URL, with patch: [String: Any], removing: ([String: Any]) -> [String: Any] = { $0 }) {
        let existing = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: merge(patch, into: removing(existing))) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
