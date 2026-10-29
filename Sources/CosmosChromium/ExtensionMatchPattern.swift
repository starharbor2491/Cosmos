import Foundation

/// A Chrome extension match pattern, as manifests write host permissions and where content scripts run:
/// `https://*.example.com/*`, `*://*/*`, `<all_urls>`. A pattern without a port matches every port.
struct ExtensionMatchPattern: Equatable {
    /// "*" is http or https (and their WebSocket schemes).
    let scheme: String
    /// "*" is every host; "*.example.com" is example.com and every host under it.
    let host: String
    let port: Int?
    /// Matched against the address's path and query; "*" stands for anything.
    let path: String

    private static let webSchemes: Set<String> = ["http", "https", "ws", "wss"]
    private static let allSchemes: Set<String> = webSchemes.union(["ftp", "file"])

    init?(_ text: String) {
        if text == "<all_urls>" {
            scheme = "<all>"; host = "*"; port = nil; path = "/*"
            return
        }
        guard let sep = text.range(of: "://") else { return nil }
        let s = String(text[..<sep.lowerBound]).lowercased()
        guard s == "*" || Self.allSchemes.contains(s) else { return nil }
        let rest = text[sep.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var hostPart = String(rest[..<slash]).lowercased()
        var port: Int?
        if let colon = hostPart.lastIndex(of: ":"), !hostPart.hasSuffix("]") {
            let p = hostPart[hostPart.index(after: colon)...]
            if p != "*" { guard let n = Int(p) else { return nil }; port = n }
            hostPart = String(hostPart[..<colon])
        }
        guard s == "file" || !hostPart.isEmpty else { return nil }
        if hostPart.contains("*"), hostPart != "*", !(hostPart.hasPrefix("*.") && !hostPart.dropFirst(2).contains("*")) { return nil }
        scheme = s; host = hostPart; self.port = port; path = String(rest[slash...])
    }

    func matches(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "<all>": guard Self.allSchemes.contains(s) else { return false }
        case "*": guard Self.webSchemes.contains(s) else { return false }
        default: guard s == scheme else { return false }
        }
        if s != "file" {
            let h = (url.host ?? "").lowercased()
            if host.hasPrefix("*.") {
                let base = String(host.dropFirst(2))
                guard h == base || h.hasSuffix("." + base) else { return false }
            } else if host != "*" {
                guard h == host else { return false }
            }
            if let port, url.port != port { return false }
        }
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?" + query }
        return Self.glob(path, matches: target)
    }

    /// `pattern` against `text`, where "*" in the pattern stands for anything, including nothing.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(text.unicodeScalars)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
