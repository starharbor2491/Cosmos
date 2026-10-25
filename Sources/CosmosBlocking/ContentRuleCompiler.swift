import Foundation

/// One WebKit rule list ready for `WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)`.
public struct CompiledRuleList: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case network, cosmetic }

    /// Unique, stable identifier (`<list id>.network.1`): use it as the store identifier.
    public let name: String
    /// JSON array of rules.
    public let json: String
    public let ruleCount: Int
    public let kind: Kind
    public var id: String { name }

    public init(name: String, json: String, ruleCount: Int, kind: Kind = .network) {
        self.name = name
        self.json = json
        self.ruleCount = ruleCount
        self.kind = kind
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

/// Turns parsed filters into ordered, de-duplicated WebKit rules and splits them into lists.
public struct ContentRuleCompiler: Sendable {
    public struct Options: Sendable {
        /// WebKit allows 150,000 rules per list; smaller lists compile faster and fail independently.
        public var maxRulesPerList = 40_000
        /// Selectors joined into one `css-display-none` rule.
        public var selectorsPerRule = 250
        /// Domains per `if-domain` array (Apple documents 250).
        public var maxDomainsPerRule = 250
        public var includeCosmetic = true
        public init() {}
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// Rules in evaluation order, grouped by role. WebKit's `ignore-previous-rules` only cancels *earlier* rules of
    /// the same list, so exceptions follow the blocks they cancel and `$important` blocks follow the exceptions.
    struct NetworkRules {
        var blocks: [String] = []
        var documentBlocks: [String] = []
        var exceptions: [String] = []
        var importantBlocks: [String] = []
        var importantExceptions: [String] = []
        private var seen = Set<String>()

        enum Stage { case block, documentBlock, exception, importantBlock, importantException }

        @discardableResult mutating func add(_ rule: ContentRule, stage: Stage) -> Bool {
            let json = rule.json
            guard seen.insert(json).inserted else { return false }
            switch stage {
            case .block: blocks.append(json)
            case .documentBlock: documentBlocks.append(json)
            case .exception: exceptions.append(json)
            case .importantBlock: importantBlocks.append(json)
            case .importantException: importantExceptions.append(json)
            }
            return true
        }
        var isEmpty: Bool { blocks.isEmpty && documentBlocks.isEmpty && importantBlocks.isEmpty }
    }

    public struct Output: Sendable {
        /// Rule JSON per output list, in order.
        public var networkLists: [[String]] = []
        public var cosmeticLists: [[String]] = []
        public var report = CompileReport()
    }

    // MARK: Entry point

    public func compile(_ parsed: ParseResult) -> Output {
        var report = CompileReport()
        report.lines = parsed.lineCount
        for (reason, n) in parsed.skipped { report.skip(reason, count: n) }

        var network: [NetworkFilter] = []
        var cosmetic: [CosmeticFilter] = []
        for f in parsed.filters {
            switch f {
            case .network(let n): network.append(n)
            case .cosmetic(let c): cosmetic.append(c)
            }
        }
        report.networkParsed = network.count + parsed.skippedNetwork
        report.cosmeticParsed = cosmetic.count + parsed.skippedCosmetic

        var badfiltered = Set<NetworkFilter>()
        for n in network where n.badfilter { badfiltered.insert(n.withoutBadfilter) }

        var rules = NetworkRules()
        var genericExempt = Set<String>()
        var specificExempt = Set<String>()
        for n in network {
            if n.badfilter { report.networkCompiled += 1; continue }
            if badfiltered.contains(n) { report.skip(.badfiltered); continue }
            if n.isException, !n.hideScope.isEmpty {
                let hosts = hideExemptionHosts(n)
                if hosts.isEmpty { report.skip(.unsupportedOption("generichide")); continue }
                if n.hideScope.contains(.generic) { genericExempt.formUnion(hosts) }
                if n.hideScope.contains(.specific) { specificExempt.formUnion(hosts) }
                report.networkCompiled += 1
                continue
            }
            switch compileNetwork(n) {
            case .success(let staged):
                var any = false
                for (stage, rule) in staged { rules.add(rule, stage: stage); any = true }
                if any { report.networkCompiled += 1 } else { report.skip(.malformed) }
            case .failure(let reason):
                report.skip(reason)
            }
        }

        limitExceptions(&rules, report: &report)
        var output = Output()
        output.networkLists = networkChunks(rules)

        if options.includeCosmetic {
            var cosmeticReport = CompileReport()
            let rulesJSON = compileCosmetic(cosmetic, genericExempt: genericExempt, specificExempt: specificExempt, report: &cosmeticReport)
            report.cosmeticCompiled = cosmeticReport.cosmeticCompiled
            for (k, v) in cosmeticReport.skipped { report.skip(k, count: v) }
            output.cosmeticLists = stride(from: 0, to: rulesJSON.count, by: options.maxRulesPerList).map {
                Array(rulesJSON[$0..<min($0 + options.maxRulesPerList, rulesJSON.count)])
            }
        } else if !cosmetic.isEmpty {
            report.skip(.unsupportedOption("cosmetic-disabled"), count: cosmetic.count)
        }
        report.ruleCount = output.networkLists.reduce(0) { $0 + $1.count } + output.cosmeticLists.reduce(0) { $0 + $1.count }
        report.listCount = output.networkLists.count + output.cosmeticLists.count
        output.report = report
        return output
    }

    // MARK: Network filters

    /// WebKit names for ABP request types that map to a plain `resource-type` entry.
    private static let plainTypes: [(ResourceType, [String])] = [
        (.script, ["script"]), (.image, ["image"]), (.stylesheet, ["style-sheet"]), (.font, ["font"]), (.media, ["media"]),
        (.xmlhttprequest, ["raw", "fetch"]), (.ping, ["ping"]), (.websocket, ["websocket"]), (.other, ["other"]),
    ]

    private static let topLevelProtection: [String] = [
        ContentRule(urlFilter: ".*", resourceTypes: ["popup"], action: .ignorePreviousRules).json,
        ContentRule(urlFilter: ".*", resourceTypes: ["document"], loadContext: "top-frame", action: .ignorePreviousRules).json,
    ]

    func compileNetwork(_ f: NetworkFilter) -> Result<[(NetworkRules.Stage, ContentRule)], SkipReason> {
        var staged: [(NetworkRules.Stage, ContentRule)] = []

        // `@@||site^$document`: switch the site's own pages off entirely.
        var types = f.types
        let isAll = types.count == ResourceType.allCases.count
        if f.isException, types.contains(.document) {
            if let host = Self.hostOnly(f) {
                staged.append((.importantException, ContentRule(urlFilter: ".*", condition: .ifDomain(["*" + host]), action: .ignorePreviousRules)))
            } else if f.hasEmptyPattern, !f.domains.include.isEmpty {
                for chunk in Self.chunks(f.domains.include.map { "*" + $0 }, size: options.maxDomainsPerRule) {
                    staged.append((.importantException, ContentRule(urlFilter: ".*", condition: .ifDomain(chunk), action: .ignorePreviousRules)))
                }
            } else if types.count == 1 {
                return .failure(.documentException)
            }
            if !isAll { types.remove(.document) }
            if types.isEmpty { return .success(staged) }
        }

        // URL pattern
        let urlFilter: String
        if f.hasEmptyPattern {
            guard !f.domains.include.isEmpty else { return .failure(.tooBroad) }
            urlFilter = ".*"
        } else {
            if Self.literalCount(f) < 3, !f.hostAnchor, !f.startAnchor, !f.endAnchor, f.domains.include.isEmpty { return .failure(.tooBroad) }
            switch PatternTranslator.urlFilter(for: f) {
            case .success(let u): urlFilter = u
            case .failure(.nonASCII): return .failure(.nonASCII)
            case .failure(.regex): return .failure(.regexNotRepresentable)
            case .failure(.empty): return .failure(.tooBroad)
            case .failure(.malformed): return .failure(.malformed)
            }
        }

        // Variants by request type.
        struct Variant { var stage: NetworkRules.Stage; var types: [String]; var context: String? }
        var variants: [Variant] = []
        let isException = f.isException
        func stage(_ s: NetworkRules.Stage) -> NetworkRules.Stage {
            switch (isException, f.important, s) {
            case (true, true, _): return .importantException
            case (true, false, _): return .exception
            case (false, true, _): return .importantBlock
            default: return s
            }
        }
        if types.isEmpty {
            variants.append(Variant(stage: stage(.block), types: [], context: nil))
        } else if isAll {
            variants.append(Variant(stage: stage(.documentBlock), types: [], context: nil))
        } else {
            let plain = Self.plainTypes.filter { types.contains($0.0) }.flatMap { $0.1 }
            if !plain.isEmpty { variants.append(Variant(stage: stage(.block), types: plain, context: nil)) }
            if types.contains(.subdocument) { variants.append(Variant(stage: stage(.block), types: ["document"], context: "child-frame")) }
            if types.contains(.document) { variants.append(Variant(stage: stage(.documentBlock), types: ["document"], context: "top-frame")) }
            if types.contains(.popup) { variants.append(Variant(stage: stage(.documentBlock), types: ["popup"], context: nil)) }
        }

        let loadType = f.thirdParty.map { $0 ? "third-party" : "first-party" }
        let action: ContentRule.Action = isException ? .ignorePreviousRules : .block

        // Domain conditions. WebKit cannot combine if-domain and unless-domain in one trigger.
        let include = f.domains.include.map { "*" + $0 }
        let exclude = f.domains.exclude.map { "*" + $0 }
        var conditions: [ContentRule.Condition?] = []
        if !include.isEmpty {
            conditions = Self.chunks(include, size: options.maxDomainsPerRule).map { .ifDomain($0) }
        } else if !exclude.isEmpty {
            conditions = [.unlessDomain(exclude)]
        } else {
            conditions = [nil]
        }

        for v in variants {
            for condition in conditions {
                var rule = ContentRule(urlFilter: urlFilter, caseSensitive: f.matchCase, resourceTypes: v.types, action: action)
                rule.loadType = loadType
                rule.loadContext = v.context
                rule.condition = condition
                staged.append((v.stage, rule))
            }
            // `domain=a.com|~b.a.com`: re-allow the excluded host after the block.
            if !isException, !include.isEmpty, !exclude.isEmpty {
                for chunk in Self.chunks(exclude, size: options.maxDomainsPerRule) {
                    var undo = ContentRule(urlFilter: urlFilter, caseSensitive: f.matchCase, resourceTypes: v.types, action: .ignorePreviousRules)
                    undo.loadType = loadType
                    undo.loadContext = v.context
                    undo.condition = .ifDomain(chunk)
                    staged.append((f.important ? .importantException : .exception, undo))
                }
            }
        }
        return .success(staged)
    }

    private static func chunks(_ array: [String], size: Int) -> [[String]] {
        guard !array.isEmpty else { return [] }
        guard array.count > size else { return [array] }
        return stride(from: 0, to: array.count, by: size).map { Array(array[$0..<min($0 + size, array.count)]) }
    }

    /// Characters that must literally appear in the URL (excludes wildcards and separators).
    private static func literalCount(_ f: NetworkFilter) -> Int {
        switch f.pattern {
        case .glob(let g): return g.utf8.reduce(0) { $0 + (($1 == UInt8(ascii: "*") || $1 == UInt8(ascii: "^")) ? 0 : 1) }
        case .regex(let r): return r.utf8.count
        }
    }

    /// `||example.com^`, `||example.com/`, `|https://example.com/` → "example.com"; anything more specific → nil.
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
        if f.hasEmptyPattern { hosts.append(contentsOf: f.domains.include) }
        return hosts
    }

    // MARK: Chunking

    /// Splits network rules over lists, repeating the exceptions in every list so they sit after the blocks they cancel.
    func networkChunks(_ r: NetworkRules) -> [[String]] {
        let blocks = r.blocks, docs = r.documentBlocks, important = r.importantBlocks
        let total = blocks.count + docs.count + important.count
        guard total > 0 else { return [] }

        let tail = r.exceptions.count + r.importantExceptions.count + Self.topLevelProtection.count
        let capacity = max(1, options.maxRulesPerList - tail)
        let docStart = blocks.count, importantStart = blocks.count + docs.count

        var lists: [[String]] = []
        var index = 0
        while index < total {
            let end = min(index + capacity, total)
            var list: [String] = []
            list.reserveCapacity(end - index + tail)
            if index < docStart { list.append(contentsOf: blocks[index..<min(end, docStart)]) }
            list.append(contentsOf: Self.topLevelProtection)
            if end > docStart, index < importantStart {
                list.append(contentsOf: docs[(max(index, docStart) - docStart)..<(min(end, importantStart) - docStart)])
            }
            list.append(contentsOf: r.exceptions)
            if end > importantStart { list.append(contentsOf: important[(max(index, importantStart) - importantStart)..<(end - importantStart)]) }
            list.append(contentsOf: r.importantExceptions)
            lists.append(list)
            index = end
        }
        return lists
    }

    /// A list can spend at most half its budget on repeated exceptions; the rest are dropped (and reported).
    func limitExceptions(_ rules: inout NetworkRules, report: inout CompileReport) {
        let allowed = max(0, options.maxRulesPerList / 4)
        if rules.exceptions.count > allowed {
            report.skip(.overLimit, count: rules.exceptions.count - allowed)
            rules.exceptions.removeSubrange(allowed...)
        }
        if rules.importantExceptions.count > allowed {
            report.skip(.overLimit, count: rules.importantExceptions.count - allowed)
            rules.importantExceptions.removeSubrange(allowed...)
        }
    }

    // MARK: Cosmetic filters

    func compileCosmetic(_ filters: [CosmeticFilter], genericExempt: Set<String>, specificExempt: Set<String>, report: inout CompileReport) -> [String] {
        var globalExceptions = Set<String>()
        var domainExceptions: [String: Set<String>] = [:]
        for f in filters where f.isException {
            if f.domains.include.isEmpty { globalExceptions.insert(f.selector) }
            else { domainExceptions[f.selector, default: []].formUnion(f.domains.include) }
            report.cosmeticCompiled += 1
        }

        var genericPlain: [String] = []
        var genericPlainSeen = Set<String>()
        var genericBuckets: [[String]: [String]] = [:]       // unless-domain list -> selectors
        var bucketSeen: [[String]: Set<String>] = [:]
        var perDomain: [String: [String]] = [:]
        var perDomainSeen: [String: Set<String>] = [:]
        let genericUnlessBase = genericExempt.sorted()

        for f in filters where !f.isException {
            if globalExceptions.contains(f.selector) { report.skip(.cosmeticConflict); continue }
            let exceptions = domainExceptions[f.selector] ?? []

            if f.domains.include.isEmpty {
                let unless = Array(Set(f.domains.exclude).union(exceptions).union(genericUnlessBase)).sorted()
                if unless.isEmpty {
                    if genericPlainSeen.insert(f.selector).inserted { genericPlain.append(f.selector) }
                } else if bucketSeen[unless, default: []].insert(f.selector).inserted {
                    genericBuckets[unless, default: []].append(f.selector)
                }
                report.cosmeticCompiled += 1
                continue
            }

            var domains: [String] = []
            var conflict: SkipReason?
            // Hosts where this selector must not apply. A blocked host equal to an included one just removes it; a
            // blocked sub-host cannot be expressed next to `if-domain`, so the filter is dropped rather than over-hide.
            let excluded = Set(f.domains.exclude)
            let blockedHosts = exceptions.union(excluded).union(specificExempt)
            for d in f.domains.include {
                var keep = true
                let suffix = "." + d
                for blocked in blockedHosts {
                    if blocked == d { keep = false }
                    else if blocked.hasSuffix(suffix) { conflict = excluded.contains(blocked) ? .mixedDomains : .cosmeticConflict }
                }
                if keep { domains.append(d) }
            }
            if let conflict { report.skip(conflict); continue }
            if domains.isEmpty { report.skip(.cosmeticConflict); continue }
            for d in domains where perDomainSeen[d, default: []].insert(f.selector).inserted { perDomain[d, default: []].append(f.selector) }
            report.cosmeticCompiled += 1
        }

        var rules: [String] = []
        var seen = Set<String>()
        func emit(_ selectors: [String], condition: ContentRule.Condition?) {
            for batch in Self.chunks(selectors, size: options.selectorsPerRule) {
                let rule = ContentRule(urlFilter: ".*", condition: condition, action: .cssDisplayNone(selector: batch.joined(separator: ", ")))
                let json = rule.json
                if seen.insert(json).inserted { rules.append(json) }
            }
        }

        emit(genericPlain, condition: nil)
        for key in genericBuckets.keys.sorted(by: { $0.joined(separator: ",") < $1.joined(separator: ",") }) {
            // A selector that is also hidden everywhere needs no restricted copy.
            emit(genericBuckets[key]!.filter { !genericPlainSeen.contains($0) }, condition: .unlessDomain(key.map { "*" + $0 }))
        }

        // Domains that share exactly the same selectors share one rule.
        var bySelectors: [[String]: [String]] = [:]
        for (domain, selectors) in perDomain { bySelectors[selectors.sorted(), default: []].append(domain) }
        let groups = bySelectors.map { (selectors: $0.key, domains: $0.value.sorted()) }.sorted { $0.domains[0] < $1.domains[0] }
        for g in groups {
            for domainChunk in Self.chunks(g.domains.map { "*" + $0 }, size: options.maxDomainsPerRule) {
                emit(g.selectors, condition: .ifDomain(domainChunk))
            }
        }
        return rules
    }
}
