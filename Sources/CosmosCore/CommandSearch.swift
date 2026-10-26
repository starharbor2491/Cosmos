import Foundation

/// One row the Command Bar can show.
public struct CommandCandidate: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// An open tab: Enter switches to it.
        case openTab(UUID)
        /// A pinned tab / favorite / folder item that may not be loaded.
        case sidebarItem(UUID)
        case archived(UUID)
        case history
        case topDomain
        /// A Type-Travel command ("New Space", "Toggle Sidebar", ...), by command id.
        case command(String)
        /// The thing the user typed, as a URL.
        case typedURL
        /// Search the web for the query.
        case webSearch
        /// "Search YouTube for ..." (site search), by site id.
        case siteSearch(String)
        /// A suggestion returned by the search engine.
        case suggestion
        case calculation
        case space(UUID)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var url: URL?
    /// SF Symbol for rows without a favicon.
    public var symbol: String?
    /// 0...1.5 from `Frecency` (0 when unknown).
    public var frecency: Double
    /// Extra text matched against the query but not shown (keywords for commands).
    public var keywords: [String]

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, url: URL? = nil, symbol: String? = nil,
                frecency: Double = 0, keywords: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.url = url
        self.symbol = symbol; self.frecency = frecency; self.keywords = keywords
    }
}

/// Remembers which result the user picked for a query so it floats up next time
/// (the same idea as Arc's `queriesToSelectedArchetype`, minus the on-device ML re-ranker).
public struct LearnedSelections: Codable, Equatable, Sendable {
    public struct Pick: Codable, Equatable, Sendable {
        public var count: Int
        public var lastAt: Date
    }
    /// normalised query -> candidate id -> pick
    public var picks: [String: [String: Pick]] = [:]
    public var maxQueries = 600

    public init() {}

    public static func normalise(_ q: String) -> String { q.lowercased().trimmingCharacters(in: .whitespaces) }

    public mutating func record(query: String, candidateID: String, at date: Date = Date()) {
        let key = Self.normalise(query)
        guard !key.isEmpty else { return }
        var forQuery = picks[key] ?? [:]
        var p = forQuery[candidateID] ?? Pick(count: 0, lastAt: date)
        p.count += 1; p.lastAt = date
        forQuery[candidateID] = p
        picks[key] = forQuery
        if picks.count > maxQueries {
            let oldest = picks.min { ($0.value.values.map(\.lastAt).max() ?? .distantPast) < ($1.value.values.map(\.lastAt).max() ?? .distantPast) }
            if let k = oldest?.key { picks[k] = nil }
        }
    }

    /// Forgets what was picked at or after `date`, and every query left with no pick. A pick carries the search or the
    /// address that was typed for it, so it is as much a record of the time as a visited page is.
    public mutating func forget(since date: Date) {
        for (query, forQuery) in picks {
            let kept = forQuery.filter { $0.value.lastAt < date }
            picks[query] = kept.isEmpty ? nil : kept
        }
    }

    /// Forgets every pick of the given candidates (a page whose history row was deleted).
    public mutating func forget(candidateIDs ids: Set<String>) {
        for (query, forQuery) in picks {
            let kept = forQuery.filter { !ids.contains($0.key) }
            picks[query] = kept.isEmpty ? nil : kept
        }
    }

    /// 0...1 boost: exact query picks count fully, picks made for a longer query that this one prefixes count less
    /// ("gi" benefits from what you chose for "github").
    public func boost(query: String, candidateID: String, now: Date = Date()) -> Double {
        let key = Self.normalise(query)
        guard !key.isEmpty else { return 0 }
        var best = 0.0
        for (q, forQuery) in picks {
            guard let p = forQuery[candidateID] else { continue }
            let weight: Double
            if q == key { weight = 1 } else if q.hasPrefix(key) { weight = 0.6 } else if key.hasPrefix(q) { weight = 0.4 } else { continue }
            let age = now.timeIntervalSince(p.lastAt)
            let decay = pow(0.5, age / (45 * 86400))
            best = max(best, min(1, 0.35 * Double(p.count) * decay) * weight)
        }
        return best
    }
}

public enum CommandRanker {
    /// Lower-cases and strips diacritics so "café" matches "cafe".
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    static func tokens(_ q: String) -> [String] {
        fold(q).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func words(_ s: String) -> [Substring] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// Subsequence match ("nspc" in "new space", "ghb" in "github"). Only dense matches count: the matched letters
    /// must cover at least half the span they sit in, so long titles don't match everything.
    static func fuzzy(_ needle: String, in hay: String) -> Double {
        guard needle.count >= 3, hay.count >= needle.count else { return 0 }
        var hi = hay.startIndex
        var matched = 0, firstHit: String.Index?, lastHit = hay.startIndex
        for ch in needle {
            guard let found = hay[hi...].firstIndex(of: ch) else { return 0 }
            if firstHit == nil {
                // An abbreviation starts at the start of a word ("nspc" -> "new space"), never mid-word.
                if found != hay.startIndex, hay[hay.index(before: found)].isLetter || hay[hay.index(before: found)].isNumber { return 0 }
                firstHit = found
            }
            lastHit = found; matched += 1
            hi = hay.index(after: found)
        }
        let span = hay.distance(from: firstHit ?? hay.startIndex, to: lastHit) + 1
        let density = Double(matched) / Double(max(span, matched))
        return density >= 0.5 ? 0.25 + 0.2 * density : 0
    }

    /// 0 (no match) ... 1 (exact). Every query token has to match somewhere.
    public static func matchScore(_ queryTokens: [String], _ c: CommandCandidate) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let title = fold(c.title)
        let titleWords = words(title)
        var host = ""
        var site = ""
        var urlText = ""
        if let u = c.url {
            host = fold(u.host ?? "")
            if host.hasPrefix("www.") { host.removeFirst(4) }
            site = host.isEmpty ? "" : PublicSuffixList.shared.siteName(of: host)
            urlText = fold(u.absoluteString)
        }
        let kw = c.keywords.map(fold)
        var total = 0.0
        for t in queryTokens {
            var best = 0.0
            if host == t || site == t { best = 1.0 }
            else if site.hasPrefix(t) { best = 0.92 }
            else if host.hasPrefix(t) { best = 0.9 }
            if title == t { best = max(best, 0.95) }
            else if title.hasPrefix(t) { best = max(best, 0.85) }
            else if titleWords.contains(where: { $0.hasPrefix(t) }) { best = max(best, 0.78) }
            if kw.contains(where: { $0.hasPrefix(t) }) { best = max(best, 0.8) }
            if best < 0.6 {
                if host.contains(t) { best = max(best, 0.6) }
                if title.contains(t) { best = max(best, 0.55) }
                if kw.contains(where: { $0.contains(t) }) { best = max(best, 0.5) }
            }
            if best < 0.4, urlText.contains(t) { best = 0.38 }
            if best == 0 { best = max(fuzzy(t, in: title), fuzzy(t, in: host)) }
            if best == 0 { return 0 }
            total += best
        }
        var score = total / Double(queryTokens.count)
        // Whole-query prefix of the title ("new tab" in "New Tab Page") is a stronger signal than scattered words.
        let joined = queryTokens.joined(separator: " ")
        if title.hasPrefix(joined) { score = min(1, score + 0.08) }
        return score
    }

    static func kindWeight(_ k: CommandCandidate.Kind) -> Double {
        switch k {
        case .openTab: return 1.25
        case .space: return 1.15
        case .sidebarItem: return 1.2
        case .command: return 1.0
        case .topDomain: return 0.95
        case .history: return 0.9
        case .archived: return 0.8
        default: return 1.0
        }
    }

    public struct Scored: Hashable, Sendable {
        public var candidate: CommandCandidate
        public var score: Double
    }

    /// Ranks `candidates` for `query`. Rows that don't match every token are dropped. Duplicate URLs keep their best row.
    public static func rank(query: String, candidates: [CommandCandidate], learned: LearnedSelections = LearnedSelections(),
                            now: Date = Date(), limit: Int = 12) -> [Scored] {
        let toks = tokens(query)
        guard !toks.isEmpty else { return [] }
        var scored: [Scored] = []
        scored.reserveCapacity(candidates.count / 4)
        for c in candidates {
            let m = matchScore(toks, c)
            guard m > 0.2 else { continue }
            let frec = 0.65 + 0.35 * min(1, c.frecency / 1.0)
            var s = m * kindWeight(c.kind) * frec
            s += 0.45 * learned.boost(query: query, candidateID: c.id, now: now)
            scored.append(Scored(candidate: c, score: s))
        }
        scored.sort { $0.score > $1.score }
        var seen = Set<String>(), out: [Scored] = []
        for s in scored {
            let key = s.candidate.url.map { dedupeKey($0) } ?? s.candidate.id
            if seen.insert(key).inserted { out.append(s) }
            if out.count >= limit { break }
        }
        return out
    }

    public static func dedupeKey(_ u: URL) -> String {
        var s = u.absoluteString
        if let i = s.firstIndex(of: "#") { s = String(s[..<i]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased().replacingOccurrences(of: "://www.", with: "://")
    }
}

/// Builds the final Command Bar list: the primary action first (typed URL or web search), then ranked matches, then
/// "Tab to search" / calculator / engine suggestions.
public enum CommandComposer {
    public struct Output: Sendable {
        public var rows: [CommandCandidate]
        /// If the top row is a strong site match, what to autocomplete into the field (the host).
        public var inlineCompletion: String?
        /// Set when Tab should enter site-search mode for this site.
        public var tabSearchSite: SiteSearch?
    }

    public static func compose(query: String, ranked: [CommandRanker.Scored], suggestions: [String], catalog: SearchCatalog,
                               engine: SearchEngine) -> Output {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Output(rows: ranked.map(\.candidate), inlineCompletion: nil, tabSearchSite: nil) }
        var rows: [CommandCandidate] = []

        if let calc = Calculator.evaluate(q) {
            rows.append(CommandCandidate(id: "calc", kind: .calculation, title: Calculator.format(calc), subtitle: q, symbol: "equal.square"))
        }

        var tabSite: SiteSearch?
        var siteRow: CommandCandidate?
        if let (site, rest) = catalog.siteSearch(matching: q), !rest.isEmpty, let url = site.searchURL(for: rest) {
            siteRow = CommandCandidate(id: "site:\(site.id):\(rest)", kind: .siteSearch(site.id), title: "Search \(site.name) for “\(rest)”", url: url, symbol: "magnifyingglass")
        } else {
            tabSite = catalog.siteSearchCompletions(for: q).first
        }

        let resolution = URLInput.resolve(q)
        var primary: CommandCandidate?
        var inline: String?
        if case .url(let u) = resolution {
            primary = CommandCandidate(id: "url:\(u.absoluteString)", kind: .typedURL, title: URLInput.display(u), subtitle: "Go to site", url: u, symbol: "globe")
        }
        // A strong ranked match beats a mere web search as the top row, and can autocomplete.
        if let top = ranked.first, top.score >= 0.8, case .url = resolution {} else if let top = ranked.first, top.score >= 0.85 {
            if let u = top.candidate.url, let h = u.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression),
               h.hasPrefix(q.lowercased()), q.count >= 2 {
                inline = h
            }
        }

        if let siteRow { rows.append(siteRow) }
        if let primary { rows.append(primary) }
        var rest = ranked.map(\.candidate)
        if primary == nil {
            let web = CommandCandidate(id: "web:\(q)", kind: .webSearch, title: q, subtitle: "Search \(engine.name)", url: engine.searchURL(for: q), symbol: "magnifyingglass")
            if let top = ranked.first, top.score >= 0.85 {
                rows.append(top.candidate)
                rest.removeFirst()
                rows.append(web)
            } else {
                rows.append(web)
            }
        }
        rows.append(contentsOf: rest.filter { c in !rows.contains(where: { $0.id == c.id }) })
        for s in suggestions.prefix(5) where s.lowercased() != q.lowercased() {
            rows.append(CommandCandidate(id: "sug:\(s)", kind: .suggestion, title: s, subtitle: nil, url: engine.searchURL(for: s), symbol: "magnifyingglass"))
        }
        return Output(rows: rows, inlineCompletion: inline, tabSearchSite: tabSite)
    }
}
