import CryptoKit
import Foundation

/// Helpers for installing extensions by Chrome Web Store id or link: id parsing and the package download address (the
/// package's signature is checked in `ChromeWebStore+Package.swift`, updates are found in `ChromeWebStore+Updates.swift`).
public enum ChromeWebStore {
    /// Web Store ids are 32 characters from a to p.
    public static func isExtensionID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    /// The id in a bare id or a Web Store link (`chromewebstore.google.com/detail/<name>/<id>`,
    /// `chrome.google.com/webstore/detail/<name>/<id>`), or `nil` when there is none.
    public static func extensionID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(trimmed) { return trimmed }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" || host.hasSuffix(".google.com") else { return nil }
        return url.pathComponents.last(where: isExtensionID)
    }

    /// The id Chromium gives the extension whose key (DER SubjectPublicKeyInfo) is `key`: the first 16 bytes of its SHA-256,
    /// each half-byte a letter from a to p.
    public static func extensionID(ofKey key: some DataProtocol) -> String {
        extensionID(hash: Array(SHA256.hash(data: Data(key)).prefix(16)))
    }

    static func extensionID(hash: [UInt8]) -> String {
        String(hash.flatMap { [$0 >> 4, $0 & 0x0F] }.map { Character(Unicode.Scalar(UInt8(ascii: "a") + $0)) })
    }

    /// Google's update endpoint, which redirects to the current `.crx` of an extension.
    public static func downloadURL(for id: String, chromiumVersion: String) -> URL? {
        guard isExtensionID(id) else { return nil }
        return updateService(answer: "redirect", chromiumVersion: chromiumVersion, extensions: ["id=\(id)&uc"])
    }

    /// Google's update service, asked as the Chromium Cosmos runs (`chromiumVersion`, "156.0.8078.48") so that it offers
    /// the versions made for it, about each of `extensions` ("id=…&v=…&uc").
    static func updateService(answer: String, chromiumVersion: String, extensions: [String]) -> URL? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: answer),
            URLQueryItem(name: "os", value: "mac"),
            URLQueryItem(name: "arch", value: "arm64"),
            URLQueryItem(name: "prod", value: "chromiumcrx"),
            URLQueryItem(name: "prodversion", value: chromiumVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
        ] + extensions.map { URLQueryItem(name: "x", value: $0) }
        return components.url
    }
}
