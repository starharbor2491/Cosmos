import CryptoKit
import Foundation

/// One compiled piece of a filter list: a ruleset of Chromium `declarativeNetRequest` rules (network), or the
/// element-hiding data of the list (cosmetic).
public struct CompiledRuleList: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case network, cosmetic }

    /// Stable name of this list (`<list id>.network.1`).
    public let name: String
    /// Network: a JSON array of rules, each without its `id` (the ruleset gives them). Cosmetic: a JSON object (see
    /// `DNRCompiler.Cosmetic`).
    public let json: String
    public let ruleCount: Int
    public let kind: Kind
    /// First 12 hex digits of the SHA-256 of `json`: changes whenever the rules do.
    public let digest: String
    public var id: String { name }

    public init(name: String, json: String, ruleCount: Int, kind: Kind = .network) {
        self.name = name
        self.json = json
        self.ruleCount = ruleCount
        self.kind = kind
        self.digest = String(SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

/// What happened to the lines of one or more lists.
public struct CompileReport: Sendable, Equatable, Codable {
    public var lines = 0
    public var networkParsed = 0
    public var networkCompiled = 0
    public var cosmeticParsed = 0
    public var cosmeticCompiled = 0
    /// Recognised filter lines that produced no rule, by reason.
    public var skipped: [SkipReason: Int] = [:]
    /// Number of rules in the emitted lists.
    public var ruleCount = 0
    public var listCount = 0

    public init() {}

    /// Filter lines recognised (comments excluded).
    public var parsed: Int { networkParsed + cosmeticParsed }
    /// Filter lines that ended up as (part of) a rule.
    public var compiled: Int { networkCompiled + cosmeticCompiled }
    public var skippedTotal: Int { skipped.values.reduce(0, +) }
    public var networkCompileRatio: Double { networkParsed == 0 ? 1 : Double(networkCompiled) / Double(networkParsed) }

    mutating func skip(_ reason: SkipReason, count: Int = 1) { skipped[reason, default: 0] += count }

    public mutating func merge(_ other: CompileReport) {
        lines += other.lines
        networkParsed += other.networkParsed
        networkCompiled += other.networkCompiled
        cosmeticParsed += other.cosmeticParsed
        cosmeticCompiled += other.cosmeticCompiled
        ruleCount += other.ruleCount
        listCount += other.listCount
        for (k, v) in other.skipped { skipped[k, default: 0] += v }
    }
}

/// Turns parsed filters into Chromium's own blocking format: `declarativeNetRequest` rules for requests, and the
/// element-hiding selectors per site. Chromium matches the rules itself, so blocking costs Cosmos nothing per request.
///
/// Adblock Plus patterns are already `declarativeNetRequest` URL filters (`||`, `|`, `^`, `*`), and the `domain=`,
/// `third-party` and type options have direct counterparts, so most filters carry over unchanged.
public struct DNRCompiler: Sendable {
    public struct Options: Sendable {
        /// Chromium turns a whole ruleset off when it would go over the extension's rule budget, so lists are cut into
        /// small rulesets that fail one by one.
        public var maxRulesPerList = 10_000
        /// Chromium allows 1,000 regular-expression rules per extension; several lists share them.
        public var maxRegexRules = 300
        public var includeCosmetic = true
        public init() {}
    }

    /// The element-hiding data of a list.
    public struct Cosmetic: Codable, Equatable, Sendable {
        /// Hidden on every site, except those in `genericHide` and `hideNothing`.
        public var generic: [String] = []
        /// Hidden on a site and its subdomains.
        public var specific: [String: [String]] = [:]
        /// Not hidden on a site and its subdomains (they cancel `generic` and `specific` selectors there).
        public var exceptions: [String: [String]] = [:]
        /// Sites with `$generichide`: no generic hiding.
        public var genericHide: [String] = []
        /// Sites with `$elemhide`: no hiding at all.
        public var hideNothing: [String] = []
        public init() {}
        public var isEmpty: Bool { generic.isEmpty && specific.isEmpty }
    }

    public struct Output: Sendable {
        /// Rule JSON per ruleset, in order (each rule without its id).
        public var networkLists: [[String]] = []
        public var cosmetic = Cosmetic()
        public var report = CompileReport()
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    enum Priority: Int { case block = 1, allow = 2, important = 3, allowPage = 4 }

    public func compile(_ parsed: ParseResult) -> Output {
        var out = Output()
        out.report.lines = parsed.lineCount
        for (reason, n) in parsed.skipped { out.report.skip(reason, count: n) }

        var network: [NetworkFilter] = []
        var cosmetic: [CosmeticFilter] = []
        for f in parsed.filters {
            switch f {
            case .network(let n): network.append(n)
            case .cosmetic(let c): cosmetic.append(c)
            }
        }
        out.report.networkParsed = network.count + parsed.skippedNetwork
        out.report.cosmeticParsed = cosmetic.count + parsed.skippedCosmetic

        var badfiltered = Set<NetworkFilter>()
        for n in network where n.badfilter { badfiltered.insert(n.withoutBadfilter) }

        var rules: [String] = []
        var seen = Set<String>()
        var regexCount = 0
        var genericHide = Set<String>(), hideNothing = Set<String>()
        for f in network {
            // A `$badfilter` line does its work by switching the other filter off.
            if f.badfilter { out.report.networkCompiled += 1; continue }
            if badfiltered.contains(f) { out.report.skip(.badfiltered); continue }
            // A filter is counted once: as compiled when any part of it took effect.
            var switchedHiding = false
            if f.isException, !f.hideScope.isEmpty {
                let hosts = hideExemptionHosts(f)
                if f.hideScope.contains(.specific) { hideNothing.formUnion(hosts) } else { genericHide.formUnion(hosts) }
                switchedHiding = !hosts.isEmpty
                // Only page-hiding switches: nothing to do with requests.
                if f.types.isEmpty {
                    if switchedHiding { out.report.networkCompiled += 1 } else { out.report.skip(.unsupportedOption("generichide")) }
                    continue
                }
            }
            if case .regex = f.pattern, regexCount >= options.maxRegexRules {
                if switchedHiding { out.report.networkCompiled += 1 } else { out.report.skip(.overLimit) }
                continue
            }
            switch rule(f) {
            case .failure(let reason):
                if switchedHiding { out.report.networkCompiled += 1 } else { out.report.skip(reason) }
            case .success(let json):
                if case .regex = f.pattern { regexCount += 1 }
                out.report.networkCompiled += 1
                if seen.insert(json).inserted { rules.append(json) }
            }
        }
        out.networkLists = stride(from: 0, to: rules.count, by: options.maxRulesPerList).map {
            Array(rules[$0..<min(rules.count, $0 + options.maxRulesPerList)])
        }

        if options.includeCosmetic {
            out.cosmetic = compileCosmetic(cosmetic, report: &out.report)
            out.cosmetic.genericHide = genericHide.sorted()
            out.cosmetic.hideNothing = hideNothing.sorted()
        } else if !cosmetic.isEmpty {
            out.report.skip(SkipReason("cosmetic-disabled"), count: cosmetic.count)
        }
        out.report.ruleCount = rules.count
        out.report.listCount = out.networkLists.count + (out.cosmetic.isEmpty ? 0 : 1)
        return out
    }

    // MARK: Network

    static let resourceTypes: [ResourceType: String] = [
        .script: "script", .image: "image", .stylesheet: "stylesheet", .font: "font", .media: "media",
        .xmlhttprequest: "xmlhttprequest", .subdocument: "sub_frame", .document: "main_frame", .ping: "ping",
        .websocket: "websocket", .other: "other",
    ]

    func rule(_ f: NetworkFilter) -> Result<String, SkipReason> {
        var condition: [String: Any] = [:]
        switch f.pattern {
        case .glob(let glob):
            if !f.hasEmptyPattern {
                guard glob.unicodeScalars.allSatisfy({ $0.isASCII }) else { return .failure(.nonASCII) }
                var filter = glob
                // `||*x` is not a valid filter; a host anchor in front of a wildcard anchors nothing anyway.
                if f.hostAnchor && !filter.hasPrefix("*") { filter = "||" + filter } else if f.startAnchor { filter = "|" + filter }
                if f.endAnchor { filter += "|" }
                condition["urlFilter"] = filter
            }
        case .regex(let regex):
            guard Self.isRE2Compatible(regex) else { return .failure(.regexNotRepresentable) }
            condition["regexFilter"] = regex
        }
        if f.matchCase { condition["isUrlFilterCaseSensitive"] = true }

        var types = f.types
        types.remove(.popup)
        if !f.types.isEmpty && types.isEmpty { return .failure(.unsupportedOption("popup")) }
        let pageException = f.isException && types.contains(.document)
        if pageException {
            condition["resourceTypes"] = ["main_frame", "sub_frame"]
        } else if !types.isEmpty {
            condition["resourceTypes"] = types.compactMap { Self.resourceTypes[$0] }.sorted()
        }
        if let third = f.thirdParty { condition["domainType"] = third ? "thirdParty" : "firstParty" }

        let include = f.domains.include.map { $0.lowercased() }
        let exclude = f.domains.exclude.map { $0.lowercased() }
        guard (include + exclude).allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) && !$0.isEmpty }) else { return .failure(.nonASCII) }
        if !include.isEmpty { condition["initiatorDomains"] = include.sorted() }
        if !exclude.isEmpty { condition["excludedInitiatorDomains"] = exclude.sorted() }

        // A rule that would act on every request of every site is a mistake in the list, not a filter.
        if f.hasEmptyPattern && include.isEmpty && f.types.isEmpty && !pageException { return .failure(.tooBroad) }

        let action: String
        let priority: Priority
        if pageException { action = "allowAllRequests"; priority = .allowPage }
        else if f.isException { action = "allow"; priority = .allow }
        else { action = "block"; priority = f.important ? .important : .block }
        let object: [String: Any] = ["priority": priority.rawValue, "action": ["type": action], "condition": condition]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return .failure(.malformed) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// RE2 (what Chromium matches with) has no look-around, back-references, atomic groups or possessive repeats, and
    /// Chromium drops a rule whose expression does not compile. ICU stands in for RE2 to find the ones that do not.
    static func isRE2Compatible(_ regex: String) -> Bool {
        let unsupported = ["(?=", "(?!", "(?<=", "(?<!", "(?>", "(?#", "*+", "++", "?+", "}+", "\\G", "\\Z",
                           "\\1", "\\2", "\\3", "\\4", "\\5", "\\6", "\\7", "\\8", "\\9"]
        guard !regex.isEmpty, regex.unicodeScalars.allSatisfy(\.isASCII), !unsupported.contains(where: regex.contains) else { return false }
        return (try? NSRegularExpression(pattern: regex)) != nil
    }

    static func hostOnly(_ f: NetworkFilter) -> String? {
        guard case .glob(var g) = f.pattern, !f.endAnchor else { return nil }
        g = g.lowercased()
        if f.startAnchor && !f.hostAnchor {
            for scheme in ["https://", "http://"] where g.hasPrefix(scheme) { g.removeFirst(scheme.count); break }
        } else if !f.hostAnchor { return nil }
        if g.hasSuffix("/*") { g.removeLast(2) }
        while let last = g.last, last == "^" || last == "/" { g.removeLast() }
        guard !g.isEmpty, !g.hasPrefix("."), !g.hasSuffix("."),
              g.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D }) else { return nil }
        return g
    }

    /// Sites named by `@@||site^$generichide` or `@@$generichide,domain=a.com|b.com`.
    private func hideExemptionHosts(_ f: NetworkFilter) -> [String] {
        var hosts: [String] = []
        if let h = Self.hostOnly(f) { hosts.append(h) }
        if f.hasEmptyPattern { hosts.append(contentsOf: f.domains.include.map { $0.lowercased() }) }
        return hosts
    }

    // MARK: Cosmetic

    func compileCosmetic(_ filters: [CosmeticFilter], report: inout CompileReport) -> Cosmetic {
        var generic: [String] = [], genericSet = Set<String>()
        var specific: [String: [String]] = [:], exceptions: [String: [String]] = [:]
        var everywhereExceptions = Set<String>()
        for f in filters {
            if let reason = CSSSelectorValidator.rejection(for: f.selector) { report.skip(reason); continue }
            let include = f.domains.include.map { $0.lowercased() }
            let exclude = f.domains.exclude.map { $0.lowercased() }
            if f.isException {
                if include.isEmpty { everywhereExceptions.insert(f.selector) }
                for d in include { exceptions[d, default: []].append(f.selector) }
            } else if include.isEmpty {
                if genericSet.insert(f.selector).inserted { generic.append(f.selector) }
                // `~a.com##.ad`: everywhere but a.com.
                for d in exclude { exceptions[d, default: []].append(f.selector) }
            } else {
                for d in include { specific[d, default: []].append(f.selector) }
                for d in exclude { exceptions[d, default: []].append(f.selector) }
            }
            report.cosmeticCompiled += 1
        }
        var c = Cosmetic()
        c.generic = generic.filter { !everywhereExceptions.contains($0) }
        c.specific = specific.mapValues { Array(Set($0.filter { !everywhereExceptions.contains($0) })).sorted() }.filter { !$0.value.isEmpty }
        c.exceptions = exceptions.mapValues { Array(Set($0)).sorted() }
        return c
    }
}
