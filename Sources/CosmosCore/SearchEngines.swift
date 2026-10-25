import Foundation

public struct SearchEngine: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var keyword: String
    /// URL template with `%s` for the query.
    public var search: String
    /// Suggestions endpoint (OpenSearch-JSON style: `["q", ["s1", "s2"]]`), or `nil`.
    public var suggest: String?

    public init(id: String, name: String, keyword: String, search: String, suggest: String? = nil) {
        self.id = id; self.name = name; self.keyword = keyword; self.search = search; self.suggest = suggest
    }

    public func searchURL(for query: String) -> URL? { URLInput.searchURL(template: search, query: query) }
    public func suggestURL(for query: String) -> URL? { suggest.flatMap { URLInput.searchURL(template: $0, query: query) } }
}

/// "Type the site's name, press Tab, then search inside it" (Arc's Site Search).
public struct SiteSearch: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Names that trigger it ("youtube", "yt").
    public var names: [String]
    public var search: String
    public var domain: String

    public func searchURL(for query: String) -> URL? { URLInput.searchURL(template: search, query: query) }
}

public struct SearchCatalog: Codable, Sendable {
    public var defaultEngine: String
    public var engines: [SearchEngine]
    public var siteSearches: [SiteSearch]

    public static let bundled: SearchCatalog = {
        guard let url = Bundle.module.url(forResource: "search-engines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cat = try? JSONDecoder().decode(SearchCatalog.self, from: data) else {
            return SearchCatalog(defaultEngine: "google",
                                 engines: [SearchEngine(id: "google", name: "Google", keyword: "g", search: "https://www.google.com/search?q=%s")],
                                 siteSearches: [])
        }
        return cat
    }()

    public func engine(_ id: String) -> SearchEngine {
        engines.first { $0.id == id } ?? engines.first { $0.id == defaultEngine } ?? engines[0]
    }

    /// If `query` begins with a site-search trigger ("youtube lofi"), returns the site and the remaining text.
    public func siteSearch(matching query: String) -> (site: SiteSearch, rest: String)? {
        let lower = query.lowercased()
        for s in siteSearches {
            for n in s.names where lower == n || lower.hasPrefix(n + " ") {
                return (s, String(query.dropFirst(n.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Sites whose trigger name starts with what's typed ("yout" -> YouTube): offered as "Tab to search".
    public func siteSearchCompletions(for typed: String) -> [SiteSearch] {
        let t = typed.lowercased()
        guard t.count >= 2, !t.contains(" ") else { return [] }
        return siteSearches.filter { $0.names.contains { $0.hasPrefix(t) } }
    }
}
