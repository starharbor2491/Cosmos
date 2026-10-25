import Foundation

/// Translates Adblock Plus URL patterns into the regular-expression subset WebKit accepts in `url-filter`.
///
/// What WebKit supports (verified against `WKContentRuleListStore`): literals, `.`, `[...]`/`[^...]`, `(...)`,
/// the quantifiers `*` `+` `?`, `^` as the very first term and `$` as the very last. It rejects alternation `|`,
/// counted repeats `{n,m}`, `\d \w \s \b`, lookaround and non-ASCII characters.
enum PatternTranslator {
    /// ABP's `^` separator: anything except letters, digits and `_ - . %`.
    static let separatorClass = "[^a-zA-Z0-9_.%-]"
    /// `||` anchor: scheme, then the host or any parent-domain boundary inside it.
    static let hostPrefix = "^[^:]+://+([^:/]+\\.)?"

    enum Failure: Error { case nonASCII, regex, empty, malformed }

    static func urlFilter(for f: NetworkFilter) -> Result<String, Failure> {
        switch f.pattern {
        case .glob(let g):
            return glob(g, hostAnchor: f.hostAnchor, startAnchor: f.startAnchor, endAnchor: f.endAnchor, matchCase: f.matchCase)
        case .regex(let r):
            if let t = regex(r, matchCase: f.matchCase) { return .success(t) }
            return .failure(r.utf8.contains(where: { $0 >= 0x80 }) ? .nonASCII : .regex)
        }
    }

    // MARK: Globs

    static func glob(_ pattern: String, hostAnchor: Bool, startAnchor: Bool, endAnchor: Bool, matchCase: Bool) -> Result<String, Failure> {
        var body = Array(pattern.utf8)
        // Collapse "**" and drop wildcards that change nothing.
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(body.count)
        for c in body where !(c == UInt8(ascii: "*") && collapsed.last == UInt8(ascii: "*")) { collapsed.append(c) }
        body = collapsed
        if !hostAnchor, !startAnchor { while body.first == UInt8(ascii: "*") { body.removeFirst() } }
        if !endAnchor { while body.last == UInt8(ascii: "*") { body.removeLast() } }
        if body.isEmpty { return .failure(.empty) }

        var trailingSeparator = false
        if body.last == UInt8(ascii: "^"), !endAnchor { body.removeLast(); trailingSeparator = true }

        var out: [UInt8] = []
        out.reserveCapacity(body.count + 40)
        if hostAnchor { out.append(contentsOf: Array(hostPrefix.utf8)) } else if startAnchor { out.append(UInt8(ascii: "^")) }

        var hostOnly = hostAnchor
        for var c in body {
            if c >= 0x80 { return .failure(.nonASCII) }
            if c < 0x21 || c == 0x7F { return .failure(.malformed) }
            switch c {
            case UInt8(ascii: "*"):
                out.append(contentsOf: [UInt8(ascii: "."), UInt8(ascii: "*")])
            case UInt8(ascii: "^"):
                out.append(contentsOf: Array(separatorClass.utf8))
            case UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "?"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["),
                 UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "|"), UInt8(ascii: "$"), UInt8(ascii: "\\"):
                out.append(UInt8(ascii: "\\"))
                out.append(c)
            default:
                if !matchCase, c >= 0x41, c <= 0x5A { c |= 0x20 }
                out.append(c)
            }
            if c == UInt8(ascii: "/") || c == UInt8(ascii: "?") || c == UInt8(ascii: "#") { hostOnly = false }
        }

        if trailingSeparator {
            if hostOnly || endAnchor {
                // A host is always followed by "/" (or ":" / "?") in the URLs WebKit matches against.
                out.append(contentsOf: Array(separatorClass.utf8))
            } else {
                // "end of URL or a separator": `(sep.*)?$` since WebKit has no alternation.
                out.append(UInt8(ascii: "("))
                out.append(contentsOf: Array(separatorClass.utf8))
                out.append(contentsOf: [UInt8(ascii: "."), UInt8(ascii: "*"), UInt8(ascii: ")"), UInt8(ascii: "?"), UInt8(ascii: "$")])
                return .success(String(decoding: out, as: UTF8.self))
            }
        }
        if endAnchor { out.append(UInt8(ascii: "$")) }
        return .success(String(decoding: out, as: UTF8.self))
    }

    // MARK: Regular expressions

    /// Converts a `/regex/` filter body; `nil` when it needs features WebKit lacks.
    static func regex(_ source: String, matchCase: Bool) -> String? {
        let s = Array(source.utf8)
        if s.isEmpty { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(s.count + 8)
        var i = 0
        var depth = 0
        var canQuantify = false      // previous token is an atom a quantifier may follow
        var justQuantified = false   // previous token was a quantifier (a trailing "?" then means lazy)
        let n = s.count

        func isWordOrDigit(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }

        if s[0] == UInt8(ascii: "^") { out.append(s[0]); i = 1 }
        while i < n {
            var c = s[i]
            if c >= 0x80 { return nil }
            switch c {
            case UInt8(ascii: "\\"):
                guard i + 1 < n else { return nil }
                let e = s[i + 1]
                if e >= 0x80 { return nil }
                switch e {
                case UInt8(ascii: "d"): out.append(contentsOf: Array("[0-9]".utf8))
                case UInt8(ascii: "w"): out.append(contentsOf: Array("[a-zA-Z0-9_]".utf8))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                default:
                    if isWordOrDigit(e) && e != UInt8(ascii: "_") { return nil }
                    if e == UInt8(ascii: "_") { out.append(e) }
                    else if Array(".+?*()[]{}|^$\\".utf8).contains(e) { out.append(UInt8(ascii: "\\")); out.append(e) }
                    else { out.append(e) }
                }
                i += 2; canQuantify = true; justQuantified = false
            case UInt8(ascii: "."):
                out.append(c); i += 1; canQuantify = true; justQuantified = false
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                if justQuantified {
                    guard c == UInt8(ascii: "?") else { return nil }   // lazy marker
                    out.append(c); i += 1; justQuantified = false; canQuantify = false
                    continue
                }
                guard canQuantify else { return nil }
                out.append(c); i += 1; justQuantified = true; canQuantify = false
            case UInt8(ascii: "("):
                if i + 1 < n, s[i + 1] == UInt8(ascii: "?") {
                    guard i + 2 < n, s[i + 2] == UInt8(ascii: ":") else { return nil }
                    i += 3
                } else { i += 1 }
                out.append(UInt8(ascii: "("))
                depth += 1; canQuantify = false; justQuantified = false
            case UInt8(ascii: ")"):
                guard depth > 0 else { return nil }
                depth -= 1
                out.append(c); i += 1; canQuantify = true; justQuantified = false
            case UInt8(ascii: "["):
                guard let end = appendCharacterClass(s, from: i, into: &out) else { return nil }
                i = end; canQuantify = true; justQuantified = false
            case UInt8(ascii: "$"):
                guard i == n - 1 else { return nil }
                out.append(c); i += 1; canQuantify = false
            case UInt8(ascii: "|"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "^"), UInt8(ascii: "]"):
                return nil
            default:
                if c < 0x20 || c == 0x7F { return nil }
                if !matchCase, c >= 0x41, c <= 0x5A { c |= 0x20 }
                out.append(c); i += 1; canQuantify = true; justQuantified = false
            }
        }
        guard depth == 0 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// Copies `[...]` (with `\d`/`\w` expanded); returns the index after the closing bracket.
    private static func appendCharacterClass(_ s: [UInt8], from start: Int, into out: inout [UInt8]) -> Int? {
        var i = start + 1
        var buf: [UInt8] = [UInt8(ascii: "[")]
        if i < s.count, s[i] == UInt8(ascii: "^") { buf.append(s[i]); i += 1 }
        var items = 0
        while i < s.count, s[i] != UInt8(ascii: "]") {
            let c = s[i]
            if c >= 0x80 || c < 0x20 { return nil }
            if c == UInt8(ascii: "\\") {
                guard i + 1 < s.count else { return nil }
                let e = s[i + 1]
                switch e {
                case UInt8(ascii: "d"): buf.append(contentsOf: Array("0-9".utf8))
                case UInt8(ascii: "w"): buf.append(contentsOf: Array("a-zA-Z0-9_".utf8))
                case UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "?"), UInt8(ascii: "="),
                     UInt8(ascii: "&"), UInt8(ascii: "%"), UInt8(ascii: "~"), UInt8(ascii: "+"), UInt8(ascii: "*"), UInt8(ascii: "("), UInt8(ascii: ")"),
                     UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "\\"), UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "|"), UInt8(ascii: "{"),
                     UInt8(ascii: "}"), UInt8(ascii: "#"), UInt8(ascii: "@"), UInt8(ascii: "!"), UInt8(ascii: ","), UInt8(ascii: ";"):
                    if e == UInt8(ascii: "/") { buf.append(e) } else { buf.append(UInt8(ascii: "\\")); buf.append(e) }
                default: return nil
                }
                i += 2
            } else if c == UInt8(ascii: "[") {
                return nil
            } else {
                buf.append(c); i += 1
            }
            items += 1
        }
        guard i < s.count, items > 0 else { return nil }
        buf.append(UInt8(ascii: "]"))
        out.append(contentsOf: buf)
        return i + 1
    }
}
