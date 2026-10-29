import Foundation
import CosmosCore
import CosmosEngine

/// The filter lists' request rules (the `declarativeNetRequest` rules `DNRCompiler` writes), matched by Cosmos itself
/// where Chromium's own matching (the blocker extension's) does not reach: profiles other than the default one. Built
/// once for a set of lists, and asked about each request on CEF's network thread, so it never changes after it is made.
final class RequestRules: @unchecked Sendable {
    enum Action { case block, allow, allowAllRequests }

    struct Rule {
        var action: Action
        var priority: Int
        var filter: URLFilter?
        var regex: NSRegularExpression?
        var types: Set<String>?
        var thirdParty: Bool?
        var initiators: [String] = []
        var excludedInitiators: [String] = []
        var requestDomains: [String] = []
    }

    /// Rules by a piece of text every address they match contains (so a request is compared only with the few rules it
    /// could match), and the rules without one.
    private var byToken: [String: [Rule]] = [:]
    private var untokened: [Rule] = []
    private(set) var count = 0

    init(lists: [CompiledBlockingList], allowlist: [String]) {
        for list in lists where list.kind == .network {
            guard let rules = try? JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]] else { continue }
            for object in rules { if let rule = Self.rule(object) { add(rule) } }
        }
        // The user's per-site switch: everything on those sites goes through, as the blocker extension's allow rule does.
        let hosts = allowlist.map { $0.lowercased() }.filter { !$0.isEmpty }
        if !hosts.isEmpty { add(Rule(action: .allowAllRequests, priority: 100, types: ["main_frame", "sub_frame"], requestDomains: hosts)) }
    }

    private func add(_ rule: Rule) {
        count += 1
        if let token = rule.filter?.token { byToken[token, default: []].append(rule) } else { untokened.append(rule) }
    }

    static func rule(_ object: [String: Any]) -> Rule? {
        guard let type = (object["action"] as? [String: Any])?["type"] as? String else { return nil }
        let action: Action
        switch type {
        case "block": action = .block
        case "allow": action = .allow
        case "allowAllRequests": action = .allowAllRequests
        default: return nil
        }
        let c = object["condition"] as? [String: Any] ?? [:]
        let caseSensitive = c["isUrlFilterCaseSensitive"] as? Bool ?? false
        var rule = Rule(action: action, priority: object["priority"] as? Int ?? 1)
        if let f = c["urlFilter"] as? String { rule.filter = URLFilter(f, caseSensitive: caseSensitive) }
        if let r = c["regexFilter"] as? String {
            guard let regex = try? NSRegularExpression(pattern: r, options: caseSensitive ? [] : [.caseInsensitive]) else { return nil }
            rule.regex = regex
        }
        if let types = c["resourceTypes"] as? [String] { rule.types = Set(types) }
        if let d = c["domainType"] as? String { rule.thirdParty = d == "thirdParty" }
        rule.initiators = c["initiatorDomains"] as? [String] ?? []
        rule.excludedInitiators = c["excludedInitiatorDomains"] as? [String] ?? []
        rule.requestDomains = c["requestDomains"] as? [String] ?? []
        return rule
    }

    /// One request: its address, its kind (`main_frame`, `script`, …, as declarativeNetRequest names them), the origin
    /// that made it, and the address of the document it is for and of each document that one is in, nearest first.
    struct Request {
        var url: String
        var type: String
        var initiator: String?
        var documents: [String] = []
    }

    /// Whether to stop the request: the rule of highest priority that matches it is a block rule. A page or frame an
    /// `allowAllRequests` rule matched lets everything it asks for through, at that rule's priority.
    func blocks(_ request: Request) -> Bool {
        var best: (priority: Int, blocks: Bool)?
        func consider(_ rule: Rule) {
            let blocks = rule.action == .block
            // At the same priority an allow wins, as in Chromium.
            if best == nil || rule.priority > best!.priority || (rule.priority == best!.priority && !blocks) { best = (rule.priority, blocks) }
        }
        let initiator = request.initiator.flatMap { URL(string: $0)?.host?.lowercased() }
        let host = URL(string: request.url)?.host?.lowercased() ?? ""
        for rule in candidates(request.url) where rule.action != .allowAllRequests
            && matches(rule, url: request.url, host: host, type: request.type, initiator: initiator) {
            consider(rule)
        }
        // The documents above: a main frame or frame request each, from the one above it.
        let frames = request.type == "main_frame" || request.type == "sub_frame" ? [request.url] + request.documents : request.documents
        for (i, document) in frames.enumerated() {
            let type = i == frames.count - 1 ? "main_frame" : "sub_frame"
            let above = i + 1 < frames.count ? URL(string: frames[i + 1])?.host?.lowercased() : nil
            let host = URL(string: document)?.host?.lowercased() ?? ""
            for rule in candidates(document) where rule.action == .allowAllRequests
                && matches(rule, url: document, host: host, type: type, initiator: above) {
                consider(rule)
            }
        }
        return best?.blocks ?? false
    }

    private func candidates(_ url: String) -> [Rule] {
        var out = untokened
        for token in URLFilter.tokens(of: url.lowercased()) { if let rules = byToken[token] { out += rules } }
        return out
    }

    private func matches(_ rule: Rule, url: String, host: String, type: String, initiator: String?) -> Bool {
        if let types = rule.types { guard types.contains(type) else { return false } }
        // Without resource types, a rule matches every request but a page's own.
        else if type == "main_frame" { return false }
        if !rule.requestDomains.isEmpty, !rule.requestDomains.contains(where: { Self.isUnder(host, $0) }) { return false }
        if !rule.initiators.isEmpty { guard let initiator, rule.initiators.contains(where: { Self.isUnder(initiator, $0) }) else { return false } }
        if let initiator, rule.excludedInitiators.contains(where: { Self.isUnder(initiator, $0) }) { return false }
        if let third = rule.thirdParty {
            let isThird = initiator.map { PublicSuffixList.shared.registrableDomain(of: $0) != PublicSuffixList.shared.registrableDomain(of: host) } ?? false
            if isThird != third { return false }
        }
        if let filter = rule.filter, !filter.matches(url) { return false }
        if let regex = rule.regex, regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) == nil { return false }
        return true
    }

    static func isUnder(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
}

/// A declarativeNetRequest `urlFilter`: `*` is anything, `^` a separator (a character that is not a letter, digit or one
/// of `_-.%`, or the end), `|` at either end anchors there, and `||` at the start anchors at the host or one of its
/// subdomains.
struct URLFilter {
    private let parts: [[UInt8]]
    private let hostAnchor: Bool
    private let startAnchor: Bool
    private let endAnchor: Bool
    private let caseSensitive: Bool
    /// The longest run of letters and digits (at least three) every matching address has, if the filter has one.
    let token: String?

    init(_ text: String, caseSensitive: Bool) {
        var f = caseSensitive ? text : text.lowercased()
        hostAnchor = f.hasPrefix("||")
        if hostAnchor { f.removeFirst(2) }
        startAnchor = !hostAnchor && f.hasPrefix("|")
        if startAnchor { f.removeFirst() }
        endAnchor = f.hasSuffix("|")
        if endAnchor { f.removeLast() }
        parts = f.split(separator: "*", omittingEmptySubsequences: false).map { Array($0.utf8) }
        self.caseSensitive = caseSensitive
        // A run next to a wildcard (or an open end) may be part of a longer word in the address, so it cannot be a token.
        var best: String?
        for (i, part) in parts.enumerated() {
            let runs = String(decoding: part, as: UTF8.self).lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
            for (j, run) in runs.enumerated() where run.count >= 3 {
                let text = String(decoding: part, as: UTF8.self).lowercased()
                let openLeft = j == 0 && text.hasPrefix(run) && (i > 0 || (!hostAnchor && !startAnchor))
                let openRight = j == runs.count - 1 && text.hasSuffix(run) && (i < parts.count - 1 || !endAnchor)
                if openLeft || openRight { continue }
                if run.count > (best?.count ?? 0) { best = String(run) }
            }
        }
        token = best
    }

    /// The runs of letters and digits in an address, as tokens are made.
    static func tokens(of url: String) -> Set<String> {
        Set(url.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.filter { $0.count >= 3 }.map(String.init))
    }

    private static func isSeparator(_ c: UInt8) -> Bool {
        !((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D || c == 0x2E || c == 0x25)
    }

    /// `part` at `i` in `u`: its length there, or nil. A `^` at the very end of the address matches nothing there.
    private static func match(_ part: [UInt8], _ u: [UInt8], at i: Int) -> Int? {
        var k = 0, j = i
        while k < part.count {
            let p = part[k]
            if j >= u.count { return p == 0x5E && k == part.count - 1 ? j - i : nil }
            if p == 0x5E { guard isSeparator(u[j]) else { return nil } } else if p != u[j] { return nil }
            k += 1; j += 1
        }
        return j - i
    }

    private static func find(_ part: [UInt8], _ u: [UInt8], from i: Int) -> (start: Int, end: Int)? {
        if part.isEmpty { return (i, i) }
        var s = i
        while s <= u.count {
            if let n = match(part, u, at: s) { return (s, s + n) }
            s += 1
        }
        return nil
    }

    func matches(_ url: String) -> Bool {
        let u = Array((caseSensitive ? url : url.lowercased()).utf8)
        var starts: [Int]
        if hostAnchor {
            // The host, or a part of it after a dot.
            guard let sep = url.range(of: "://") else { return false }
            let hostStart = url.utf8.distance(from: url.utf8.startIndex, to: sep.upperBound)
            var hostEnd = hostStart
            while hostEnd < u.count, ![0x2F, 0x3A, 0x3F, 0x23].contains(u[hostEnd]) { hostEnd += 1 }
            starts = [hostStart] + (hostStart..<hostEnd).filter { u[$0] == 0x2E }.map { $0 + 1 }
        } else if startAnchor {
            starts = [0]
        } else {
            starts = []
        }
        func rest(from position: Int, part index: Int) -> Bool {
            var position = position
            for k in index..<parts.count {
                let last = k == parts.count - 1
                if last && endAnchor {
                    let part = parts[k]
                    // At the very end (a `^` at the end may stand for the end itself, one character shorter).
                    for s in [u.count - part.count, u.count - part.count + 1] where s >= position {
                        if let n = Self.match(part, u, at: s), s + n == u.count { return true }
                    }
                    return false
                }
                guard let found = Self.find(parts[k], u, from: position) else { return false }
                position = found.end
            }
            return true
        }
        if starts.isEmpty {
            guard let first = Self.find(parts[0], u, from: 0) else { return false }
            if parts.count == 1 { return endAnchor ? rest(from: 0, part: 0) : true }
            // The first piece anywhere: the earliest place leaves the most room for the rest.
            return rest(from: first.end, part: 1)
        }
        for s in starts {
            guard let n = Self.match(parts[0], u, at: s) else { continue }
            if parts.count == 1 {
                if !endAnchor || s + n == u.count { return true }
                continue
            }
            if rest(from: s + n, part: 1) { return true }
        }
        return false
    }
}

/// The rules a profile matches its requests with, swapped whole when the lists change, and read on CEF's network thread.
final class OwnRequestRules: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: RequestRules?
    /// The change each set of rules was made for, in order: one made for an older change is not put in after a newer one.
    private var issued = 0
    private var applied = 0

    /// The number of a change whose rules are being made.
    func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        issued += 1
        return issued
    }

    func set(_ new: RequestRules?, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation > applied else { return }
        applied = generation
        rules = new
    }

    func blocks(_ request: RequestRules.Request) -> Bool {
        lock.lock(); let current = rules; lock.unlock()
        return current?.blocks(request) ?? false
    }

    /// The check CEF runs for each request (`CosmosCEFContext.blocksRequest`), on its network thread.
    static func check(_ holder: OwnRequestRules) -> @Sendable (String, String, String?, [String]) -> Bool {
        { url, type, initiator, documents in holder.blocks(.init(url: url, type: type, initiator: initiator, documents: documents)) }
    }
}
