import Foundation
@testable import CosmosBlocking

/// Unique scratch directory, removed by the caller (or left to the OS temp cleaner).
func makeTempDirectory(_ label: String = "cosmos-blocking") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Shorthand for expected network filters in parser tables.
func net(
    _ glob: String, host: Bool = false, start: Bool = false, end: Bool = false, exception: Bool = false,
    types: Set<ResourceType> = [], third: Bool? = nil, include: [String] = [], exclude: [String] = [],
    matchCase: Bool = false, important: Bool = false, badfilter: Bool = false, hide: HideScope = []
) -> FilterParser.Line {
    var f = NetworkFilter(pattern: .glob(glob))
    f.hostAnchor = host
    f.startAnchor = start
    f.endAnchor = end
    f.isException = exception
    f.types = types
    f.thirdParty = third
    f.domains = DomainList(include: include, exclude: exclude)
    f.matchCase = matchCase
    f.important = important
    f.badfilter = badfilter
    f.hideScope = hide
    return .filter(.network(f))
}

func regexFilter(_ body: String, exception: Bool = false, types: Set<ResourceType> = [], third: Bool? = nil, matchCase: Bool = false) -> FilterParser.Line {
    var f = NetworkFilter(pattern: .regex(body))
    f.isException = exception
    f.types = types
    f.thirdParty = third
    f.matchCase = matchCase
    return .filter(.network(f))
}

func hide(_ selector: String, include: [String] = [], exclude: [String] = [], exception: Bool = false) -> FilterParser.Line {
    .filter(.cosmetic(CosmeticFilter(selector: selector, domains: DomainList(include: include, exclude: exclude), isException: exception)))
}

/// The rule JSON objects of the first network list for `filters`, without the two fixed top-level-navigation guards.
func networkRules(_ text: String, options: ContentRuleCompiler.Options = .init()) -> [String] {
    // A list made only of exceptions is pointless (and empty lists are invalid), so a throwaway block keeps it alive.
    let out = ContentRuleCompiler(options: options).compile(FilterParser.parse("||zz-base.invalid^\n" + text))
    guard let first = out.networkLists.first else { return [] }
    return first.filter { !protectionRules.contains($0) && !$0.contains("zz-base") }
}

func cosmeticRules(_ text: String, options: ContentRuleCompiler.Options = .init()) -> [String] {
    ContentRuleCompiler(options: options).compile(FilterParser.parse(text)).cosmeticLists.first ?? []
}

let protectionRules: Set<String> = [
    #"{"trigger":{"url-filter":".*","resource-type":["popup"]},"action":{"type":"ignore-previous-rules"}}"#,
    #"{"trigger":{"url-filter":".*","resource-type":["document"],"load-context":["top-frame"]},"action":{"type":"ignore-previous-rules"}}"#,
]

/// Evaluates a WebKit `url-filter` against a URL the way WebKit would (case-insensitively unless told otherwise),
/// using ICU regular expressions, which are a superset of the subset WebKit supports.
func urlFilterMatches(_ filter: String, _ url: String, caseSensitive: Bool = false) -> Bool {
    guard let re = try? NSRegularExpression(pattern: filter, options: caseSensitive ? [] : [.caseInsensitive]) else { return false }
    return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

/// Downloads public lists once per test run (several suites need the same text). `nil` when offline.
actor CorpusCache {
    static let shared = CorpusCache()
    private var cache: [String: String?] = [:]

    func text(_ urlString: String) async -> String? {
        if let hit = cache[urlString] { return hit }
        var text: String?
        if let url = URL(string: urlString) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("Cosmos tests", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count > 10_000 {
                text = String(decoding: data, as: UTF8.self)
            }
        }
        cache[urlString] = .some(text)
        return text
    }
}

enum Corpus {
    static let easylist = "https://easylist.to/easylist/easylist.txt"
    static let easyprivacy = "https://easylist.to/easylist/easyprivacy.txt"
}
