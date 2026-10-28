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

/// The network rules `text` compiles to, each decoded, in order across all rulesets.
func networkRules(_ text: String, options: DNRCompiler.Options = .init()) -> [NSDictionary] {
    DNRCompiler(options: options).compile(FilterParser.parse(text)).networkLists.flatMap { $0 }.map(decode)
}

func cosmetic(_ text: String) -> DNRCompiler.Cosmetic {
    DNRCompiler().compile(FilterParser.parse(text)).cosmetic
}

func decode(_ json: String) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? NSDictionary ?? [:]
}

/// What Chromium's `declarativeNetRequest` accepts in a static ruleset, as its documentation states it: a rule that
/// breaks one of these is dropped when the extension loads. Returns what is wrong with each rule of a list's JSON.
func dnrProblems(_ json: String) -> [String] {
    guard let rules = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return ["not a JSON array of rules"] }
    let actions: Set<String> = ["block", "allow", "allowAllRequests", "upgradeScheme", "redirect", "modifyHeaders"]
    let keys: Set<String> = ["urlFilter", "regexFilter", "isUrlFilterCaseSensitive", "initiatorDomains", "excludedInitiatorDomains",
                             "requestDomains", "excludedRequestDomains", "resourceTypes", "excludedResourceTypes", "domainType",
                             "requestMethods", "excludedRequestMethods", "tabIds", "excludedTabIds"]
    let types: Set<String> = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest", "ping",
                              "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]
    var problems: [String] = []
    for (i, rule) in rules.enumerated() {
        func bad(_ what: String) { problems.append("rule \(i): \(what)") }
        guard let priority = rule["priority"] as? Int, priority >= 1 else { bad("priority"); continue }
        guard let action = (rule["action"] as? [String: Any])?["type"] as? String, actions.contains(action) else { bad("action"); continue }
        guard let condition = rule["condition"] as? [String: Any] else { bad("no condition"); continue }
        if let unknown = condition.keys.first(where: { !keys.contains($0) }) { bad("unknown key \(unknown)") }
        let url = condition["urlFilter"] as? String, regex = condition["regexFilter"] as? String
        if url != nil && regex != nil { bad("both urlFilter and regexFilter") }
        if let url {
            if url.isEmpty || !url.unicodeScalars.allSatisfy(\.isASCII) { bad("urlFilter \(url)") }
            if url.hasPrefix("||*") { bad("urlFilter starts with ||*") }
        }
        if let regex, regex.isEmpty || !regex.unicodeScalars.allSatisfy(\.isASCII) || (try? NSRegularExpression(pattern: regex)) == nil {
            bad("regexFilter \(regex)")
        }
        let ruleTypes = condition["resourceTypes"] as? [String]
        if let ruleTypes, ruleTypes.isEmpty || !ruleTypes.allSatisfy(types.contains) { bad("resourceTypes \(ruleTypes)") }
        if action == "allowAllRequests", !(ruleTypes.map { !$0.isEmpty && Set($0).isSubset(of: ["main_frame", "sub_frame"]) } ?? false) {
            bad("allowAllRequests needs main_frame/sub_frame resourceTypes")
        }
        if let domainType = condition["domainType"] as? String, !["firstParty", "thirdParty"].contains(domainType) { bad("domainType") }
        for key in ["initiatorDomains", "excludedInitiatorDomains", "requestDomains", "excludedRequestDomains"] {
            guard let domains = condition[key] else { continue }
            guard let list = domains as? [String], !list.isEmpty,
                  list.allSatisfy({ !$0.isEmpty && $0 == $0.lowercased() && $0.unicodeScalars.allSatisfy(\.isASCII) }) else { bad(key); continue }
        }
    }
    return problems
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
