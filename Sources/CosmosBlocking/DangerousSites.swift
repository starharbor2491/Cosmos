import Foundation

/// Sites known to spread malware or to phish, from public lists. Cosmos warns before a page from one of them opens: its
/// stand-in for Safe Browsing, which Chromium cannot use without Google's own keys.
public struct DangerousSites: Sendable, Equatable {
    public enum Reason: String, Sendable, Codable { case malware, phishing }

    private var hosts: [String: Reason] = [:]

    public init() {}

    public var count: Int { hosts.count }

    /// Hosts-file lines (`0.0.0.0 host`), bare hosts and `||host^` filters; comments and anything else are skipped.
    public static func parse(_ text: String, reason: Reason) -> DangerousSites {
        var sites = DangerousSites()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var host: String
            if words.count == 2, isAddress(words[0]) { host = words[1] }
            else if words.count == 1 { host = words[0] }
            else { continue }
            if host.hasPrefix("||") && host.hasSuffix("^") { host = String(host.dropFirst(2).dropLast()) }
            host = host.lowercased()
            guard isHost(host) else { continue }
            sites.hosts[host] = reason
        }
        return sites
    }

    /// Adds `other`'s sites; a site on both lists keeps the reason it had.
    public mutating func merge(_ other: DangerousSites) {
        hosts.merge(other.hosts) { mine, _ in mine }
    }

    /// Why `url` is dangerous: its host, or a domain it is part of, is listed.
    public func reason(for url: URL) -> Reason? {
        guard !hosts.isEmpty, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var name = Substring(host)
        while true {
            if let reason = hosts[String(name)] { return reason }
            guard let dot = name.firstIndex(of: ".") else { return nil }
            name = name[name.index(after: dot)...]
        }
    }

    private static func isAddress(_ s: String) -> Bool { s == "0.0.0.0" || s == "127.0.0.1" || s == "::" || s == "::1" }

    /// A name with a dot in it, of letters, digits, dots and hyphens: not an address (`0.0.0.0`) and not a word.
    private static func isHost(_ s: String) -> Bool {
        s.contains(".") && !isAddress(s) && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
            || s == "localhost"
    }
}

/// Keeps the dangerous-site lists downloaded: twice a day, asking first whether they changed, and keeping what was there
/// when the network fails. They live beside the filter lists, in `FilterLists/`.
public actor DangerousSiteLists {
    public struct Source: Sendable, Equatable {
        public let id: String
        public let name: String
        public let url: URL
        public let reason: DangerousSites.Reason
        public let license: String
        public let homepage: URL
    }

    public static let catalog: [Source] = [
        Source(id: "urlhaus", name: "URLhaus malicious hosts", url: URL(string: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts-online.txt")!,
               reason: .malware, license: "CC0 (data from abuse.ch URLhaus)", homepage: URL(string: "https://gitlab.com/malware-filter/urlhaus-filter")!),
        Source(id: "phishing", name: "Phishing hosts", url: URL(string: "https://malware-filter.gitlab.io/malware-filter/phishing-filter-hosts.txt")!,
               reason: .phishing, license: "CC BY-SA 4.0 (data from OpenPhish, IPThreat, PhishTank)",
               homepage: URL(string: "https://gitlab.com/malware-filter/phishing-filter")!),
    ]

    static let refreshInterval: TimeInterval = 12 * 3600

    private struct Meta: Codable { var etag: String?; var lastModified: String?; var checked: Date }

    private let directory: URL
    private let fetcher: FilterListFetching
    private let now: @Sendable () -> Date

    public init(directory: URL, fetcher: FilterListFetching = URLSessionFilterListFetcher(), now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.fetcher = fetcher
        self.now = now
    }

    private func textFile(_ s: Source) -> URL { directory.appendingPathComponent("dangerous-\(s.id).txt") }
    private func metaFile(_ s: Source) -> URL { directory.appendingPathComponent("dangerous-\(s.id).meta.json") }

    /// What is on disk now, without the network.
    public func cached() -> DangerousSites {
        var all = DangerousSites()
        for source in Self.catalog {
            guard let text = try? String(contentsOf: textFile(source), encoding: .utf8) else { continue }
            all.merge(DangerousSites.parse(text, reason: source.reason))
        }
        return all
    }

    /// Downloads the lists last checked twelve or more hours ago (all of them with `force`), then returns what is on disk.
    public func refresh(force: Bool = false) async -> DangerousSites {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in Self.catalog {
            let meta = (try? Data(contentsOf: metaFile(source))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            if !force, let meta, now().timeIntervalSince(meta.checked) < Self.refreshInterval, now() >= meta.checked { continue }
            let hasText = FileManager.default.fileExists(atPath: textFile(source).path)
            guard let result = try? await fetcher.fetch(source.url, etag: hasText ? meta?.etag : nil, lastModified: hasText ? meta?.lastModified : nil) else { continue }
            var next = meta ?? Meta(checked: now())
            next.checked = now()
            if case .downloaded(let data, let etag, let lastModified) = result {
                // A web page where a list should be (an error, a captive portal) is not a list.
                guard let text = String(data: data, encoding: .utf8), !text.lowercased().contains("<html"),
                      (try? data.write(to: textFile(source), options: .atomic)) != nil else { continue }
                next.etag = etag
                next.lastModified = lastModified
            }
            if let encoded = try? JSONEncoder().encode(next) { try? encoded.write(to: metaFile(source), options: .atomic) }
        }
        return cached()
    }
}
