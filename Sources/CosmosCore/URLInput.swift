import Foundation

/// Reads the Public Suffix List (bundled, trimmed of comments) so we can tell `github.com` from `foo.github.io`
/// and find the registrable domain ("site") of any host. Used by Peek's same-site test, favicons and ranking.
public final class PublicSuffixList: @unchecked Sendable {
    public static let shared = PublicSuffixList()

    private var exact: Set<String> = []
    private var wildcard: Set<String> = []   // "*.ck" stored as "ck"
    private var exception: Set<String> = []  // "!www.ck" stored as "www.ck"

    init() {
        guard let url = Bundle.module.url(forResource: "public_suffix_rules", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            if rule.hasPrefix("!") { exception.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { wildcard.insert(String(rule.dropFirst(2))) }
            else if !rule.isEmpty { exact.insert(rule) }
        }
    }

    /// Number of labels in the public suffix of `labels` (at least 1: unknown TLDs count as a suffix).
    private func suffixLength(_ labels: [Substring]) -> Int {
        var best = 1
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            let n = labels.count - i
            if exception.contains(candidate) { return n - 1 }
            if exact.contains(candidate) { best = max(best, n) }
            if i + 1 < labels.count, wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { best = max(best, n) }
        }
        return best
    }

    /// `www.bbc.co.uk` -> `bbc.co.uk`; `localhost` and IP addresses are returned unchanged.
    public func registrableDomain(of host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if URLInput.isIPAddress(h) { return h }
        let labels = h.split(separator: ".")
        guard labels.count > 1 else { return h }
        let n = suffixLength(labels)
        if labels.count <= n { return h }
        return labels[(labels.count - n - 1)...].joined(separator: ".")
    }

    /// The first label of the registrable domain: "github" for `gist.github.com`. Handy for matching typed names.
    public func siteName(of host: String) -> String {
        String(registrableDomain(of: host).split(separator: ".").first ?? "")
    }

    public func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let ha = a.host, let hb = b.host else { return false }
        return registrableDomain(of: ha) == registrableDomain(of: hb)
    }
}

/// Decides what the user meant by what they typed into the Command Bar.
public enum URLInput {
    public enum Resolution: Equatable, Sendable {
        case url(URL)
        case search(String)
    }

    static let tlds: Set<String> = {
        guard let url = Bundle.module.url(forResource: "tlds", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ["com", "org", "net", "io", "dev", "app"] }
        return Set(text.split(whereSeparator: \.isNewline).map { String($0) })
    }()

    private static let openSchemes: Set<String> = ["http", "https", "file", "about", "data", "mailto", "tel", "cosmos", "view-source", "ftp", "blob", "arc"]

    public static func isIPAddress(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        return s.contains(":") && s.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && s.filter({ $0 == ":" }).count >= 2
    }

    private static func isLocalHost(_ h: String) -> Bool {
        let l = h.lowercased()
        return l == "localhost" || l.hasSuffix(".localhost") || l.hasSuffix(".local") || l.hasSuffix(".test") || l.hasSuffix(".internal") || isIPAddress(l)
    }

    public static func resolve(_ raw: String) -> Resolution {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .search("") }

        // Explicit scheme.
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            let rest = text[text.index(after: colon)...]
            let looksLikePort = !rest.isEmpty && rest.prefix(while: \.isNumber).count > 0 && (rest.allSatisfy(\.isNumber) || rest.drop(while: \.isNumber).first == "/")
            if !looksLikePort, openSchemes.contains(scheme), !text.contains(" ") || scheme == "data" {
                if let u = URL(string: text) { return .url(u) }
            }
        }
        if text.contains(where: \.isWhitespace) { return .search(text) }

        // host[:port][/path][?query][#frag]
        var hostPort = text
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { hostPort = String(text[..<end]) }
        var host = hostPort
        var port: String?
        if hostPort.hasPrefix("[") { // [::1]:8080
            host = hostPort
        } else if let c = hostPort.lastIndex(of: ":"), hostPort.filter({ $0 == ":" }).count == 1 {
            host = String(hostPort[..<c]); port = String(hostPort[hostPort.index(after: c)...])
            if Int(port ?? "") == nil { return .search(text) }
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        let local = isLocalHost(bare) || hostPort.hasPrefix("[")
        let labels = bare.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let validLabels = !labels.isEmpty && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        let tldOK = labels.count >= 2 && tlds.contains(String(labels.last!))
        let isHost = local || (validLabels && tldOK)

        guard isHost else { return .search(text) }
        let scheme = local ? "http" : "https"
        if let u = URL(string: "\(scheme)://\(text)"), u.host != nil { return .url(u) }
        return .search(text)
    }

    /// The URL for a web search using `template` (with `%s`).
    public static func searchURL(template: String, query: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#?/:;@$,"))
        guard let enc = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: enc))
    }

    /// Short display form of a URL for sidebar rows and the URL pill: `github.com/foo`.
    public static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.scheme == "file" { return url.lastPathComponent }
        guard var host = url.host else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        if path == "/" { path = "" }
        return host + path
    }

    public static func hostForDisplay(_ url: URL?) -> String {
        guard var h = url?.host else { return url?.scheme == "file" ? "Local file" : "" }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
}
