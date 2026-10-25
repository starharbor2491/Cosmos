import Foundation

/// Outcome of parsing a whole list.
public struct ParseResult: Sendable {
    public var filters: [Filter] = []
    /// Lines that were recognised as filters but cannot be expressed (by reason).
    public var skipped: [SkipReason: Int] = [:]
    public var lineCount = 0
    /// Blank lines, `!` comments and `[Adblock Plus]` headers.
    public var commentCount = 0
    /// Lines inside `!#if` blocks that do not apply to this engine.
    public var conditionalCount = 0

    /// How many of the `skipped` lines were network filters / element-hiding filters.
    public var skippedNetwork = 0
    public var skippedCosmetic = 0

    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

/// Parser for the Adblock Plus / uBlock Origin / AdGuard static filter syntax.
///
/// It understands network filters (`||host^`, `|http://`, wildcards, `/regex/`, `$options`, `@@` exceptions) and
/// standard element-hiding filters (`##`, `domain##`, `#@#`). Syntax that needs a script engine (`#?#`, `:has-text()`,
/// `:xpath()`, scriptlets, `$redirect`, `$removeparam`, ...) is recognised and reported as skipped, never mis-compiled.
public enum FilterParser {
    public enum Line: Equatable, Sendable {
        case filter(Filter)
        case comment
        case skipped(SkipReason)
    }

    /// Names that are `true` in `!#if` conditions. Cosmos is a desktop WebKit browser.
    public static let preprocessorEnvironment: Set<String> = ["env_safari", "true"]

    // MARK: Whole lists

    public static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        var text = text
        text.withUTF8 { all in
            result.filters.reserveCapacity(all.count / 40)
            var conditions: [Bool] = []   // stack of "this branch is active"
            var active = true
            var lineStart = 0
            let n = all.count
            while lineStart <= n {
                var lineEnd = lineStart
                while lineEnd < n, all[lineEnd] != 0x0A { lineEnd += 1 }
                let line = UnsafeBufferPointer(rebasing: all[lineStart..<lineEnd])
                lineStart = lineEnd + 1
                if lineEnd == n && line.isEmpty { break }
                result.lineCount += 1

                if line.count >= 2, line[0] == UInt8(ascii: "!"), line[1] == UInt8(ascii: "#"), let directive = parseDirective(line) {
                    switch directive {
                    case .ifStart(let cond):
                        conditions.append(active)
                        active = active && cond
                    case .else:
                        if let outer = conditions.last { active = outer && !active }
                    case .end:
                        if let outer = conditions.popLast() { active = outer }
                    }
                    result.commentCount += 1
                    continue
                }
                if !active { result.conditionalCount += 1; continue }

                let (parsed, isCosmetic) = classify(bytes: line)
                switch parsed {
                case .filter(let f): result.filters.append(f)
                case .comment: result.commentCount += 1
                case .skipped(let reason):
                    result.skipped[reason, default: 0] += 1
                    if isCosmetic { result.skippedCosmetic += 1 } else { result.skippedNetwork += 1 }
                }
            }
        }
        return result
    }

    // MARK: Preprocessor

    private enum Directive { case ifStart(Bool), `else`, end }

    private static func parseDirective(_ line: UnsafeBufferPointer<UInt8>) -> Directive? {
        let s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("!#if ") || s.hasPrefix("!#if\t") {
            return .ifStart(evaluateCondition(String(s.dropFirst(5))))
        }
        if s == "!#else" { return .else }
        if s == "!#endif" { return .end }
        return nil
    }

    /// Evaluates `env_safari && !ext_ublock`-style conditions with `!`, `&&`, `||` and parentheses.
    static func evaluateCondition(_ expr: String) -> Bool {
        var tokens: [String] = []
        var current = ""
        let chars = Array(expr)
        var i = 0
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == ")" || c == "!" { flush(); tokens.append(String(c)) }
            else if (c == "&" || c == "|"), i + 1 < chars.count, chars[i + 1] == c { flush(); tokens.append(String([c, c])); i += 1 }
            else if c == " " || c == "\t" { flush() }
            else { current.append(c) }
            i += 1
        }
        flush()
        var pos = 0
        func parseOr() -> Bool {
            var v = parseAnd()
            while pos < tokens.count, tokens[pos] == "||" { pos += 1; let r = parseAnd(); v = v || r }
            return v
        }
        func parseAnd() -> Bool {
            var v = parseNot()
            while pos < tokens.count, tokens[pos] == "&&" { pos += 1; let r = parseNot(); v = v && r }
            return v
        }
        func parseNot() -> Bool {
            guard pos < tokens.count else { return false }
            if tokens[pos] == "!" { pos += 1; return !parseNot() }
            if tokens[pos] == "(" {
                pos += 1
                let v = parseOr()
                if pos < tokens.count, tokens[pos] == ")" { pos += 1 }
                return v
            }
            let name = tokens[pos]; pos += 1
            return preprocessorEnvironment.contains(name)
        }
        return parseOr()
    }

    // MARK: Single lines

    public static func parseLine(_ line: String) -> Line {
        var line = line
        return line.withUTF8 { parse(bytes: $0) }
    }

    static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Line { classify(bytes: b).line }

    /// Parses one line and says whether it was an element-hiding style filter (for the report).
    static func classify(bytes b: UnsafeBufferPointer<UInt8>) -> (line: Line, isCosmetic: Bool) {
        var lo = 0, hi = b.count
        while lo < hi, isSpace(b[lo]) { lo += 1 }
        while hi > lo, isSpace(b[hi - 1]) { hi -= 1 }
        if lo == hi { return (.comment, false) }
        let first = b[lo]
        if first == UInt8(ascii: "!") { return (.comment, false) }
        if first == UInt8(ascii: "["), b[hi - 1] == UInt8(ascii: "]") { return (.comment, false) }
        if first == UInt8(ascii: "#"), hi - lo > 1, b[lo + 1] == UInt8(ascii: " ") { return (.comment, false) }

        if let sep = findCosmeticSeparator(b, lo, hi) {
            return (parseCosmetic(b, lo: lo, hi: hi, sep: sep), true)
        }
        let line = parseNetwork(b, lo: lo, hi: hi)
        return (line, line == .skipped(.htmlFilter))
    }

    // MARK: Cosmetic

    private enum CosmeticKind { case hide, hideException, extended, cssInjection, script }

    private struct Separator {
        var start: Int
        var end: Int
        var kind: CosmeticKind
    }

    private static func isDomainByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
            || c == UInt8(ascii: ".") || c == UInt8(ascii: "-") || c == UInt8(ascii: "_") || c == UInt8(ascii: ",")
            || c == UInt8(ascii: "~") || c == UInt8(ascii: "*") || c == UInt8(ascii: ":") || c >= 0x80
    }

    private static func findCosmeticSeparator(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Separator? {
        var i = lo
        while i < hi {
            let c = b[i]
            if c == UInt8(ascii: "#") {
                func at(_ k: Int) -> UInt8 { i + k < hi ? b[i + k] : 0 }
                let h = UInt8(ascii: "#"), atSign = UInt8(ascii: "@"), q = UInt8(ascii: "?"), d = UInt8(ascii: "$"), p = UInt8(ascii: "%")
                if at(1) == h { return Separator(start: i, end: i + 2, kind: .hide) }
                if at(1) == q, at(2) == h { return Separator(start: i, end: i + 3, kind: .extended) }
                if at(1) == d, at(2) == h { return Separator(start: i, end: i + 3, kind: .cssInjection) }
                if at(1) == d, at(2) == q, at(3) == h { return Separator(start: i, end: i + 4, kind: .cssInjection) }
                if at(1) == p, at(2) == h { return Separator(start: i, end: i + 3, kind: .script) }
                if at(1) == atSign {
                    if at(2) == h { return Separator(start: i, end: i + 3, kind: .hideException) }
                    if at(2) == q, at(3) == h { return Separator(start: i, end: i + 4, kind: .extended) }
                    if at(2) == d, at(3) == h { return Separator(start: i, end: i + 4, kind: .cssInjection) }
                    if at(2) == d, at(3) == q, at(4) == h { return Separator(start: i, end: i + 5, kind: .cssInjection) }
                    if at(2) == p, at(3) == h { return Separator(start: i, end: i + 4, kind: .script) }
                }
                return nil
            }
            if !isDomainByte(c) { return nil }
            i += 1
        }
        return nil
    }

    private static func parseCosmetic(_ b: UnsafeBufferPointer<UInt8>, lo: Int, hi: Int, sep: Separator) -> Line {
        switch sep.kind {
        case .extended: return .skipped(.extendedSelector)
        case .cssInjection: return .skipped(.cssInjection)
        case .script: return .skipped(.scriptRule)
        case .hide, .hideException: break
        }
        var bodyLo = sep.end
        while bodyLo < hi, isSpace(b[bodyLo]) { bodyLo += 1 }
        guard bodyLo < hi else { return .skipped(.malformed) }
        if b[bodyLo] == UInt8(ascii: "+"), hasPrefix(b, bodyLo, hi, "+js(") { return .skipped(.scriptlet) }
        if b[bodyLo] == UInt8(ascii: "^") { return .skipped(.htmlFilter) }

        let selector = String(decoding: UnsafeBufferPointer(rebasing: b[bodyLo..<hi]), as: UTF8.self)
        if let reason = CSSSelectorValidator.rejection(for: selector) { return .skipped(reason) }

        var domains = DomainList()
        if sep.start > lo {
            let parsed = parseDomainList(UnsafeBufferPointer(rebasing: b[lo..<sep.start]), separator: UInt8(ascii: ","))
            if let reason = parsed.failure { return .skipped(reason) }
            domains = parsed.list
        }
        return .filter(.cosmetic(CosmeticFilter(selector: selector, domains: domains, isException: sep.kind == .hideException)))
    }

    // MARK: Domains

    /// Splits `a.com|~b.com` (or `a.com,~b.com`). Entries WebKit cannot match (`site.*`, `/regex/`, non-ASCII) are
    /// dropped from the include list; an unusable exclusion, or an include list that ends up empty, fails the filter.
    static func parseDomainList(_ b: UnsafeBufferPointer<UInt8>, separator: UInt8) -> (list: DomainList, failure: SkipReason?) {
        var list = DomainList()
        var droppedInclude: SkipReason?
        var includeCount = 0
        var start = 0
        let n = b.count
        while start <= n {
            var end = start
            while end < n, b[end] != separator { end += 1 }
            var lo = start, hi = end
            start = end + 1
            while lo < hi, isSpace(b[lo]) { lo += 1 }
            while hi > lo, isSpace(b[hi - 1]) { hi -= 1 }
            if lo == hi { continue }
            var negated = false
            if b[lo] == UInt8(ascii: "~") { negated = true; lo += 1 }
            if lo == hi { continue }
            var reason: SkipReason?
            var ok = true
            var lowered = [UInt8]()
            lowered.reserveCapacity(hi - lo)
            for k in lo..<hi {
                var c = b[k]
                if c >= 0x80 { reason = .nonASCII; ok = false; break }
                if c >= 0x41 && c <= 0x5A { c |= 0x20 }
                let valid = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ".") || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
                if !valid { reason = .entityDomain; ok = false; break }
                lowered.append(c)
            }
            if ok {
                // WebKit wants hostnames: a letter or digit at both ends.
                func alnum(_ c: UInt8?) -> Bool { c.map { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) } ?? false }
                if !alnum(lowered.first) || !alnum(lowered.last) { ok = false; reason = .malformed }
            }
            if !negated { includeCount += 1 }
            if !ok {
                if negated { return (list, reason ?? .entityDomain) }
                droppedInclude = droppedInclude ?? reason
                continue
            }
            let name = String(decoding: lowered, as: UTF8.self)
            if negated { list.exclude.append(name) } else { list.include.append(name) }
        }
        if includeCount > 0, list.include.isEmpty { return (list, droppedInclude ?? .entityDomain) }
        return (list, nil)
    }

    // MARK: Network

    private static let hostsPrefixes: [[UInt8]] = [Array("0.0.0.0".utf8), Array("127.0.0.1".utf8)]
    private static let hostsIgnored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback", "0.0.0.0"]

    private static func parseNetwork(_ b: UnsafeBufferPointer<UInt8>, lo: Int, hi: Int) -> Line {
        var p = lo
        var isException = false
        if hi - p >= 2, b[p] == UInt8(ascii: "@"), b[p + 1] == UInt8(ascii: "@") { isException = true; p += 2 }
        guard p < hi else { return .skipped(.malformed) }

        if !isException, b[p] == UInt8(ascii: "0") || b[p] == UInt8(ascii: "1"), let host = hostsFileEntry(b, p, hi) {
            guard let host else { return .comment }
            var f = NetworkFilter(pattern: .glob(host + "^"))
            f.hostAnchor = true
            return .filter(.network(f))
        }

        // Options start after the last "$" whose tail looks like an option list; "$$" marks an HTML filter.
        var patternEnd = hi
        var optionsStart = hi
        let isRegexShape = hi - p >= 2 && b[p] == UInt8(ascii: "/") && b[hi - 1] == UInt8(ascii: "/")
        var dollars: [Int] = []
        var k = p
        while k < hi {
            if b[k] == UInt8(ascii: "$") {
                dollars.append(k)
                if k + 1 < hi, b[k + 1] == UInt8(ascii: "$") || (b[k + 1] == UInt8(ascii: "@") && k + 2 < hi && b[k + 2] == UInt8(ascii: "$")) {
                    return .skipped(.htmlFilter)
                }
            }
            k += 1
        }
        if !isRegexShape {
            // Usually the last "$"; an option value may itself contain one (`urlskip=/x$/`), so look further back.
            for d in dollars.reversed() where looksLikeOptions(b, from: d + 1, to: hi) {
                patternEnd = d
                optionsStart = d + 1
                break
            }
        }

        var f: NetworkFilter
        var q = p, r = patternEnd
        if r - q >= 3, b[q] == UInt8(ascii: "/"), b[r - 1] == UInt8(ascii: "/") {
            let body = String(decoding: UnsafeBufferPointer(rebasing: b[(q + 1)..<(r - 1)]), as: UTF8.self)
            f = NetworkFilter(pattern: .regex(body))
        } else {
            var host = false, start = false, end = false
            if r - q >= 2, b[q] == UInt8(ascii: "|"), b[q + 1] == UInt8(ascii: "|") { host = true; q += 2 }
            else if r - q >= 1, b[q] == UInt8(ascii: "|") { start = true; q += 1 }
            if r - q >= 1, b[r - 1] == UInt8(ascii: "|") { end = true; r -= 1 }
            r = max(q, r)
            for k in q..<r where isSpace(b[k]) { return .skipped(.malformed) }
            f = NetworkFilter(pattern: .glob(String(decoding: UnsafeBufferPointer(rebasing: b[q..<r]), as: UTF8.self)))
            f.hostAnchor = host
            f.startAnchor = start
            f.endAnchor = end
        }
        f.isException = isException

        if optionsStart < hi {
            let opts = String(decoding: UnsafeBufferPointer(rebasing: b[optionsStart..<hi]), as: UTF8.self)
            if let reason = applyOptions(opts, to: &f) { return .skipped(reason) }
        }
        return .filter(.network(f))
    }

    /// `0.0.0.0 ads.example.com`: `nil` if the line is not a hosts entry, `.some(nil)` for entries to ignore.
    private static func hostsFileEntry(_ b: UnsafeBufferPointer<UInt8>, _ p: Int, _ hi: Int) -> String?? {
        for prefix in hostsPrefixes {
            let n = prefix.count
            guard hi - p > n + 1, isSpace(b[p + n]) else { continue }
            var match = true
            for k in 0..<n where b[p + k] != prefix[k] { match = false; break }
            guard match else { continue }
            var s = p + n
            while s < hi, isSpace(b[s]) { s += 1 }
            var e = s
            while e < hi, !isSpace(b[e]), b[e] != UInt8(ascii: "#") { e += 1 }
            guard e > s else { return .some(nil) }
            let host = String(decoding: UnsafeBufferPointer(rebasing: b[s..<e]), as: UTF8.self).lowercased()
            if hostsIgnored.contains(host) || !host.contains(".") { return .some(nil) }
            return .some(host)
        }
        return nil
    }

    /// `third-party,script`, `~image`, `domain=a.com|b.com`: the first token must look like an option name.
    private static func looksLikeOptions(_ b: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
        guard from < to else { return false }
        var k = from
        if b[k] == UInt8(ascii: "~") { k += 1 }
        let nameStart = k
        while k < to, (b[k] >= 0x61 && b[k] <= 0x7A) || (b[k] >= 0x41 && b[k] <= 0x5A) || (b[k] >= 0x30 && b[k] <= 0x39) || b[k] == UInt8(ascii: "-") || b[k] == UInt8(ascii: "_") { k += 1 }
        guard k > nameStart else { return false }
        return k == to || b[k] == UInt8(ascii: ",") || b[k] == UInt8(ascii: "=")
    }

    private enum OptionAction {
        case type(ResourceType)
        case thirdParty, firstParty, domain, matchCase, important, badfilter, all, ignore
        case hide(HideScope)
    }

    private static let optionTable: [String: OptionAction] = [
        "third-party": .thirdParty, "3p": .thirdParty, "first-party": .firstParty, "1p": .firstParty,
        "script": .type(.script), "image": .type(.image), "stylesheet": .type(.stylesheet), "css": .type(.stylesheet),
        "font": .type(.font), "media": .type(.media), "xmlhttprequest": .type(.xmlhttprequest), "xhr": .type(.xmlhttprequest),
        "subdocument": .type(.subdocument), "frame": .type(.subdocument), "document": .type(.document), "doc": .type(.document),
        "ping": .type(.ping), "beacon": .type(.ping), "websocket": .type(.websocket), "other": .type(.other),
        "popup": .type(.popup), "popunder": .type(.popup), "background": .type(.image),
        "domain": .domain, "from": .domain, "match-case": .matchCase, "important": .important, "badfilter": .badfilter,
        "all": .all, "collapse": .ignore, "donottrack": .ignore,
        "generichide": .hide(.generic), "ghide": .hide(.generic), "specifichide": .hide(.specific), "shide": .hide(.specific),
        "elemhide": .hide(.all), "ehide": .hide(.all),
    ]

    /// Request types WebKit has no equivalent for: excluding them (`$~object`) changes nothing.
    private static let ignorableNegatedTypes: Set<String> = ["object", "object-subrequest", "xbl", "dtd", "webrtc", "inline-script", "inline-font"]

    private static func applyOptions(_ options: String, to f: inout NetworkFilter) -> SkipReason? {
        var positives = Set<ResourceType>()
        var negatives = Set<ResourceType>()
        var all = false
        var optionStart = options.startIndex
        // "$csp=a,b" style values may contain commas; only split where the next token looks like an option.
        var tokens: [Substring] = []
        var idx = options.startIndex
        while idx < options.endIndex {
            if options[idx] == "," {
                tokens.append(options[optionStart..<idx])
                optionStart = options.index(after: idx)
            }
            idx = options.index(after: idx)
        }
        tokens.append(options[optionStart..<options.endIndex])

        for token in tokens {
            var t = token.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            var negated = false
            if t.hasPrefix("~") { negated = true; t.removeFirst() }
            var name = t
            var value: String?
            if let eq = t.firstIndex(of: "=") {
                name = String(t[..<eq])
                value = String(t[t.index(after: eq)...])
            }
            name = name.lowercased()
            if negated, ignorableNegatedTypes.contains(name) { continue }
            guard let action = optionTable[name] else { return .unsupportedOption(name) }
            switch action {
            case .type(let type):
                if negated { negatives.insert(type) } else { positives.insert(type) }
            case .thirdParty: f.thirdParty = !negated
            case .firstParty: f.thirdParty = negated
            case .domain:
                guard let value, !value.isEmpty else { return .malformed }
                var v = value
                let parsed = v.withUTF8 { parseDomainList($0, separator: UInt8(ascii: "|")) }
                if let reason = parsed.failure { return reason }
                f.domains = parsed.list
            case .matchCase: f.matchCase = !negated
            case .important: f.important = !negated
            case .badfilter: f.badfilter = true
            case .all: all = true
            case .ignore: break
            case .hide(let scope):
                guard f.isException else { return .unsupportedOption(name) }
                f.hideScope.formUnion(scope)
            }
        }

        if all {
            f.types = Set(ResourceType.allCases)
        } else if !positives.isEmpty {
            f.types = positives.subtracting(negatives)
            if f.types.isEmpty { return .malformed }
        } else if !negatives.isEmpty {
            f.types = ResourceType.defaultSet.subtracting(negatives)
            if f.types.isEmpty { return .malformed }
        }
        if f.types == ResourceType.defaultSet { f.types = [] }
        return nil
    }

    // MARK: Helpers

    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

    private static func hasPrefix(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ hi: Int, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard hi - at >= n else { return false }
        let p = prefix.utf8Start
        for k in 0..<n where b[at + k] != p[k] { return false }
        return true
    }
}
