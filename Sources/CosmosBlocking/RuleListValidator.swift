import Foundation

/// Checks a content-rule-list JSON document against the constraints WebKit enforces, so bad output is caught in
/// tests and before a list is handed to `WKContentRuleListStore` (whose errors are terse, or, for selectors, silent).
public enum RuleListValidator {
    public static let maxRules = 150_000
    /// Sanity bound; Apple documents 250 but `WKContentRuleListStore` accepts far more.
    public static let maxDomainEntries = 5_000

    static let actionTypes: Set<String> = ["block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https", "notify"]
    static let resourceTypes: Set<String> = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"]
    static let loadTypes: Set<String> = ["first-party", "third-party"]
    static let loadContexts: Set<String> = ["top-frame", "child-frame"]
    static let triggerKeys: Set<String> = [
        "url-filter", "url-filter-is-case-sensitive", "resource-type", "load-type", "load-context", "if-domain", "unless-domain",
        "if-top-url", "unless-top-url", "if-frame-url",
    ]

    /// Returns human-readable problems; an empty array means the list is acceptable.
    public static func validate(json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return ["not valid UTF-8"] }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { return ["invalid JSON: \(error.localizedDescription)"] }
        guard let rules = root as? [Any] else { return ["top level must be an array of rules"] }
        var problems: [String] = []
        if rules.isEmpty { problems.append("rule list is empty (WebKit rejects it)") }
        if rules.count > maxRules { problems.append("\(rules.count) rules exceed WebKit's limit of \(maxRules)") }

        func add(_ i: Int, _ message: String) { if problems.count < 200 { problems.append("rule \(i): \(message)") } }

        for (i, item) in rules.enumerated() {
            guard let rule = item as? [String: Any] else { add(i, "not an object"); continue }
            guard let trigger = rule["trigger"] as? [String: Any] else { add(i, "missing trigger object"); continue }
            guard let action = rule["action"] as? [String: Any] else { add(i, "missing action object"); continue }
            validateTrigger(trigger, index: i, add: add)
            validateAction(action, index: i, add: add)
        }
        return problems
    }

    // MARK: Trigger

    private static func validateTrigger(_ t: [String: Any], index i: Int, add: (Int, String) -> Void) {
        for key in t.keys where !triggerKeys.contains(key) { add(i, "unknown trigger key \(key)") }

        if let filter = t["url-filter"] as? String {
            if filter.isEmpty { add(i, "url-filter is empty") }
            else { for p in regexProblems(filter) { add(i, "url-filter \(filter.prefix(80)): \(p)") } }
        } else {
            add(i, "url-filter missing or not a string")
        }
        if let v = t["url-filter-is-case-sensitive"], !(v is Bool) { add(i, "url-filter-is-case-sensitive must be a boolean") }

        if let v = t["resource-type"] {
            if let arr = v as? [String], !arr.isEmpty {
                for s in arr where !resourceTypes.contains(s) { add(i, "illegal resource-type \(s)") }
            } else { add(i, "resource-type must be a non-empty array of strings") }
        }
        if let v = t["load-type"] {
            if let arr = v as? [String], !arr.isEmpty { for s in arr where !loadTypes.contains(s) { add(i, "illegal load-type \(s)") } }
            else { add(i, "load-type must be a non-empty array of strings") }
        }
        if let v = t["load-context"] {
            if let arr = v as? [String], !arr.isEmpty { for s in arr where !loadContexts.contains(s) { add(i, "illegal load-context \(s)") } }
            else { add(i, "load-context must be a non-empty array of strings") }
        }

        let conditionKeys = ["if-domain", "unless-domain", "if-top-url", "unless-top-url"].filter { t[$0] != nil }
        if conditionKeys.count > 1 { add(i, "only one of if-domain/unless-domain/if-top-url/unless-top-url may be used (\(conditionKeys.joined(separator: ", ")))") }
        for key in ["if-domain", "unless-domain"] {
            guard let v = t[key] else { continue }
            guard let arr = v as? [String], !arr.isEmpty else { add(i, "\(key) must be a non-empty array of strings"); continue }
            if arr.count > maxDomainEntries { add(i, "\(key) has \(arr.count) entries") }
            for d in arr where !isValidDomainCondition(d) { add(i, "invalid \(key) entry \(d.prefix(60))") }
        }
    }

    /// Lowercase ASCII host, optionally prefixed with `*` (matches subdomains too).
    static func isValidDomainCondition(_ d: String) -> Bool {
        var bytes = Array(d.utf8)
        if bytes.first == UInt8(ascii: "*") { bytes.removeFirst() }
        guard let first = bytes.first, let last = bytes.last else { return false }
        func alnum(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
        guard alnum(first), alnum(last) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
    }

    // MARK: Action

    private static func validateAction(_ a: [String: Any], index i: Int, add: (Int, String) -> Void) {
        guard let type = a["type"] as? String else { add(i, "action type missing"); return }
        guard actionTypes.contains(type) else { add(i, "illegal action type \(type)"); return }
        if type == "css-display-none" {
            guard let selector = a["selector"] as? String, !selector.trimmingCharacters(in: .whitespaces).isEmpty else {
                add(i, "css-display-none requires a selector")
                return
            }
            if !CSSSelectorValidator.isValid(selector) { add(i, "selector WebKit would drop: \(selector.prefix(120))") }
        } else if a["selector"] != nil {
            add(i, "\(type) must not have a selector")
        }
        if type == "notify", !(a["notification"] is String) { add(i, "notify requires a notification string") }
    }

    // MARK: url-filter regex subset

    /// Problems with `pattern` as a WebKit `url-filter` (empty when it is within the supported subset).
    public static func regexProblems(_ pattern: String) -> [String] {
        let s = Array(pattern.utf8)
        var problems: [String] = []
        func fail(_ m: String) { if !problems.contains(m) { problems.append(m) } }
        var depth = 0
        var canQuantify = false
        var justQuantified = false
        var i = 0
        let n = s.count
        func isAlnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        while i < n {
            let c = s[i]
            if c >= 0x80 { fail("non-ASCII character"); i += 1; continue }
            if c < 0x20 || c == 0x7F { fail("control character"); i += 1; continue }
            switch c {
            case UInt8(ascii: "^"):
                if i != 0 { fail("^ is only allowed as the first character") }
                canQuantify = false; justQuantified = false; i += 1
            case UInt8(ascii: "$"):
                if i != n - 1 { fail("$ is only allowed as the last character") }
                canQuantify = false; justQuantified = false; i += 1
            case UInt8(ascii: "\\"):
                if i + 1 >= n { fail("dangling backslash"); i += 1; continue }
                let e = s[i + 1]
                if isAlnum(e) { fail("escape \\\(Character(UnicodeScalar(e))) (character classes, backreferences and anchors are unsupported)") }
                canQuantify = true; justQuantified = false; i += 2
            case UInt8(ascii: "["):
                var j = i + 1
                if j < n, s[j] == UInt8(ascii: "^") { j += 1 }
                var items = 0
                var closed = false
                while j < n {
                    if s[j] == UInt8(ascii: "\\") {
                        if j + 1 < n, isAlnum(s[j + 1]) { fail("escape inside character class") }
                        j += 2; items += 1; continue
                    }
                    if s[j] == UInt8(ascii: "]") { closed = true; break }
                    if s[j] >= 0x80 { fail("non-ASCII character") }
                    j += 1; items += 1
                }
                if !closed { fail("unterminated character class"); i = n; continue }
                if items == 0 { fail("empty character class") }
                canQuantify = true; justQuantified = false; i = j + 1
            case UInt8(ascii: "("):
                if i + 1 < n, s[i + 1] == UInt8(ascii: "?") { fail("(? groups (lookaround, non-capturing) are unsupported") }
                depth += 1; canQuantify = false; justQuantified = false; i += 1
            case UInt8(ascii: ")"):
                if depth == 0 { fail("unbalanced )") } else { depth -= 1 }
                canQuantify = true; justQuantified = false; i += 1
            case UInt8(ascii: "|"):
                fail("alternation | is unsupported"); i += 1
            case UInt8(ascii: "{"), UInt8(ascii: "}"):
                fail("counted repetition {} is unsupported"); i += 1
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                if justQuantified { if c != UInt8(ascii: "?") { fail("repeated quantifier") }; justQuantified = false }
                else if !canQuantify { fail("quantifier without an atom") }
                else { justQuantified = true }
                canQuantify = false; i += 1
            default:
                canQuantify = true; justQuantified = false; i += 1
            }
        }
        if depth > 0 { fail("unbalanced (") }
        return problems
    }
}
