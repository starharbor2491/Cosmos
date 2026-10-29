import Foundation

/// Files Cosmos ships for Chromium: the bridge extension, the helper script for Cosmos's isolated world and the one for
/// the page's world.
enum ChromiumResources {
    static var bridgeExtension: URL? { Bundle.module.url(forResource: "Bridge", withExtension: nil) }
    /// The bridge's id, which the `key` in its manifest fixes: its worker is known by it, not by anything an extension
    /// could copy (a file name).
    static let bridgeExtensionID = "pbkfjgepnjdbbaajkbdcjeoplapljeme"

    static let engineHelper: String? = {
        guard let url = Bundle.module.url(forResource: "engine-helper", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static let pageBridge: String? = {
        guard let url = Bundle.module.url(forResource: "page-bridge", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// `s` as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
