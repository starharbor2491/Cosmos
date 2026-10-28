import Foundation

/// The page engine's own settings, kept with Cosmos's. These are the settings Chromium has in its own Settings page,
/// minus the ones Cosmos's interface already owns (search engine, start-up pages, appearance, downloads, the address bar)
/// and the ones that need a Google account or Google API keys (sync, Safe Browsing).
public struct EngineSettings: Codable, Equatable, Sendable {
    public enum CookiePolicy: String, Codable, CaseIterable, Sendable { case allowAll, blockThirdPartyInPrivate, blockThirdParty }
    /// What a site gets when it asks, before the user has answered for it.
    public enum Ask: String, Codable, CaseIterable, Sendable { case ask, block }
    public enum SecureDNS: String, Codable, CaseIterable, Sendable { case off, automatic, secure }
    public enum WebRTCPolicy: String, Codable, CaseIterable, Sendable { case standard, publicInterfaceOnly, disableNonProxiedUDP }

    // Privacy and security
    public var cookies: CookiePolicy = .blockThirdPartyInPrivate
    public var doNotTrack = false
    public var preloadPages = true
    /// Try HTTPS first and warn before an insecure page.
    public var httpsFirst = false
    public var secureDNS: SecureDNS = .automatic
    /// The DNS-over-HTTPS server for `.secure` (`https://dns.example/dns-query{?dns}`); empty uses the system's.
    public var secureDNSTemplate = ""
    public var webRTC: WebRTCPolicy = .standard

    // Site defaults
    public var javaScript = true
    public var images = true
    public var popups = false
    public var sound = true
    public var automaticDownloads: Ask = .ask
    public var notifications: Ask = .ask
    public var location: Ask = .ask
    public var camera: Ask = .ask
    public var microphone: Ask = .ask
    public var clipboard: Ask = .ask

    // Fonts
    public var defaultFontSize = 16
    public var defaultFixedFontSize = 13
    public var minimumFontSize = 0
    /// Empty: the engine's own choice.
    public var standardFont = ""
    public var serifFont = ""
    public var sansSerifFont = ""
    public var fixedFont = ""

    // Languages: what pages are asked for, in order. Empty: the Mac's own preferred languages.
    public var languages: [String] = []

    // System
    public var hardwareAcceleration = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cookies, doNotTrack, preloadPages, httpsFirst, secureDNS, secureDNSTemplate, webRTC
        case javaScript, images, popups, sound, automaticDownloads, notifications, location, camera, microphone, clipboard
        case defaultFontSize, defaultFixedFontSize, minimumFontSize, standardFont, serifFont, sansSerifFont, fixedFont
        case languages, hardwareAcceleration
    }

    // Tolerant decoding, like the rest of the settings file.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ target: inout T) { if let v = try? c.decode(T.self, forKey: key) { target = v } }
        get(.cookies, &cookies); get(.doNotTrack, &doNotTrack); get(.preloadPages, &preloadPages); get(.httpsFirst, &httpsFirst)
        get(.secureDNS, &secureDNS); get(.secureDNSTemplate, &secureDNSTemplate); get(.webRTC, &webRTC)
        get(.javaScript, &javaScript); get(.images, &images); get(.popups, &popups); get(.sound, &sound)
        get(.automaticDownloads, &automaticDownloads); get(.notifications, &notifications); get(.location, &location)
        get(.camera, &camera); get(.microphone, &microphone); get(.clipboard, &clipboard)
        get(.defaultFontSize, &defaultFontSize); get(.defaultFixedFontSize, &defaultFixedFontSize); get(.minimumFontSize, &minimumFontSize)
        get(.standardFont, &standardFont); get(.serifFont, &serifFont); get(.sansSerifFont, &sansSerifFont); get(.fixedFont, &fixedFont)
        get(.languages, &languages); get(.hardwareAcceleration, &hardwareAcceleration)
        defaultFontSize = min(72, max(6, defaultFontSize))
        defaultFixedFontSize = min(72, max(6, defaultFixedFontSize))
        minimumFontSize = min(24, max(0, minimumFontSize))
    }
}
