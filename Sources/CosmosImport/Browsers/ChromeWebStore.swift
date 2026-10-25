import Foundation

/// Helpers for installing extensions by Chrome Web Store id or link: id parsing, the package download address and
/// unwrapping the `.crx` container to its zip payload.
public enum ChromeWebStore {
    public enum CRXError: Error, Equatable { case notAPackage, truncated, unsupportedVersion(UInt32) }

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

    /// Google's update endpoint, which redirects to the current `.crx` of an extension.
    public static func downloadURL(for id: String) -> URL? {
        guard isExtensionID(id) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "os", value: "mac"),
            URLQueryItem(name: "arch", value: "arm64"),
            URLQueryItem(name: "prod", value: "chromiumcrx"),
            URLQueryItem(name: "prodversion", value: "130.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url
    }

    /// The zip inside a CRX2 or CRX3 file (a plain zip passes through unchanged). The signature is not checked: the
    /// package comes straight from the publisher's channel over HTTPS, and Cosmos runs it with WebKit's extension sandbox.
    public static func zipPayload(fromCRX data: Data) throws -> Data {
        func u32(_ offset: Int) -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            let b = data.startIndex + offset
            return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
        }
        if data.starts(with: [0x50, 0x4B]) { return data }                      // already a zip
        guard data.starts(with: Array("Cr24".utf8)) else { throw CRXError.notAPackage }
        guard let version = u32(4) else { throw CRXError.truncated }
        let start: Int
        switch version {
        case 2:
            guard let keyLength = u32(8), let signatureLength = u32(12) else { throw CRXError.truncated }
            start = 16 + Int(keyLength) + Int(signatureLength)
        case 3:
            guard let headerLength = u32(8) else { throw CRXError.truncated }
            start = 12 + Int(headerLength)
        default:
            throw CRXError.unsupportedVersion(version)
        }
        guard start < data.count else { throw CRXError.truncated }
        return data.subdata(in: (data.startIndex + start)..<data.endIndex)
    }
}
