import Foundation

extension ChromeWebStore {
    /// A newer version the Web Store has for an extension.
    public struct Update: Equatable, Sendable {
        public var id: String
        public var version: String
        /// Where its package is.
        public var codebase: URL
        /// The package's SHA-256, when the Web Store gives it (lowercase hex).
        public var sha256: String?
    }

    /// The address that asks Google's update service about the `installed` extensions at once, the way Chrome asks; its
    /// answer (`updates(fromResponse:)`) has the newer version of each that has one.
    public static func updateCheckURL(_ installed: [(id: String, version: String)], chromiumVersion: String) -> URL? {
        let valid = installed.filter { isExtensionID($0.id) }
        guard !valid.isEmpty else { return nil }
        return updateService(answer: "updatecheck", chromiumVersion: chromiumVersion, extensions: valid.map { "id=\($0.id)&v=\($0.version)&uc" })
    }

    /// The updates in the service's answer (its `gupdate` XML): each `app` whose `updatecheck` says "ok", with a version
    /// and a package address.
    public static func updates(fromResponse data: Data) -> [Update] {
        final class Reader: NSObject, XMLParserDelegate {
            var app: String?
            var found: [Update] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                switch name {
                case "app": app = attributes["appid"]
                case "updatecheck":
                    guard let app, attributes["status"] == "ok", let version = attributes["version"],
                          let codebase = attributes["codebase"].flatMap(URL.init(string:)), codebase.scheme == "https" else { return }
                    found.append(Update(id: app, version: version, codebase: codebase, sha256: attributes["hash_sha256"].flatMap { $0.isEmpty ? nil : $0.lowercased() }))
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "app" { app = nil }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return reader.found
    }

    /// Whether version `a` ("1.10.2") is later than `b`: Chrome's versions are up to four dot-separated numbers.
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
