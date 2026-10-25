import Foundation

/// A strict CSS selector checker mirroring what WebKit accepts in a `css-display-none` action.
///
/// WebKit silently drops a whole rule when any selector in its comma-separated list fails to parse, so a rule
/// built from many selectors must contain only ones that are valid. This accepts the CSS used by real filter lists
/// (type/class/id/attribute selectors, combinators, `:not`/`:is`/`:where`/`:has`, structural pseudo-classes) and
/// rejects everything else, including the procedural extensions of uBlock Origin / AdGuard / ABP.
public enum CSSSelectorValidator {
    /// `true` if `selector` is a valid selector list using only standard CSS.
    public static func isValid(_ selector: String) -> Bool {
        var p = Parser(Array(selector.utf8))
        return p.parseTopLevel()
    }

    /// `nil` when `selector` is fine; otherwise why not: `.cssInjection` for `sel {prop: value}` style rules,
    /// `.extendedSelector` for procedural syntax, else `.invalidSelector`.
    public static func rejection(for selector: String) -> SkipReason? {
        if isValid(selector) { return nil }
        if selector.utf8.contains(UInt8(ascii: "{")) { return .cssInjection }
        return containsProcedural(selector) ? .extendedSelector : .invalidSelector
    }

    private static let proceduralNames: Set<String> = [
        "has-text", "contains", "xpath", "min-text-length", "upward", "nth-ancestor", "watch-attr", "others", "remove",
        "style", "if", "if-not", "properties", "subject", "matches-css", "matches-css-before", "matches-css-after",
        "matches-media", "matches-path", "matches-attr", "matches-property", "matches-prop", "not-has", "is-visible",
        "has-text-content", "contains-text", "-abp-contains", "-abp-has", "-abp-properties", "-ext-has", "-ext-contains",
        "-ext-matches-css", "-ext-matches-css-before", "-ext-matches-css-after", "-ext-if-not", "-ext-xpath",
    ]

    static func containsProcedural(_ selector: String) -> Bool {
        let b = Array(selector.utf8)
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: ":") {
                var j = i + 1
                if j < b.count, b[j] == UInt8(ascii: ":") { j += 1 }
                let start = j
                while j < b.count, b[j] == UInt8(ascii: "-") || b[j] == UInt8(ascii: "_") || isAlnum(b[j]) { j += 1 }
                if j > start {
                    let name = String(decoding: b[start..<j], as: UTF8.self).lowercased()
                    if proceduralNames.contains(name) || name.hasPrefix("-abp-") || name.hasPrefix("-ext-") { return true }
                }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        return false
    }

    // MARK: Character classes

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
    private static func isNameStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
    }
    private static func isNameChar(_ c: UInt8) -> Bool { isNameStart(c) || isDigit(c) || c == 0x2D }

    private static let simplePseudoClasses: Set<String> = [
        "hover", "active", "focus", "focus-within", "focus-visible", "visited", "link", "any-link", "target", "checked",
        "disabled", "enabled", "empty", "root", "first-child", "last-child", "only-child", "first-of-type",
        "last-of-type", "only-of-type", "required", "optional", "read-only", "read-write", "placeholder-shown",
        "indeterminate", "default", "valid", "invalid", "in-range", "out-of-range", "fullscreen", "-webkit-full-screen",
        "scope", "defined",
    ]
    private static let selectorListPseudoClasses: Set<String> = ["not", "is", "where", "matches", "-webkit-any"]

    // MARK: Parser

    private struct Parser {
        let s: [UInt8]
        var i = 0
        var hasDepth = 0
        init(_ bytes: [UInt8], hasDepth: Int = 0) { s = bytes; self.hasDepth = hasDepth }

        var atEnd: Bool { i >= s.count }
        func peek(_ offset: Int = 0) -> UInt8? { i + offset < s.count ? s[i + offset] : nil }

        mutating func skipSpace() { while i < s.count, CSSSelectorValidator.isSpace(s[i]) { i += 1 } }

        mutating func parseTopLevel() -> Bool {
            guard !s.isEmpty else { return false }
            guard parseList(relative: false) else { return false }
            skipSpace()
            return atEnd
        }

        /// Comma separated complex selectors; stops before `)` or at the end.
        mutating func parseList(relative: Bool) -> Bool {
            while true {
                skipSpace()
                guard parseComplex(relative: relative) else { return false }
                skipSpace()
                if peek() == UInt8(ascii: ",") { i += 1; continue }
                return true
            }
        }

        mutating func parseComplex(relative: Bool) -> Bool {
            skipSpace()
            if relative, let c = peek(), c == UInt8(ascii: ">") || c == UInt8(ascii: "+") || c == UInt8(ascii: "~") {
                i += 1
                skipSpace()
            }
            guard parseCompound() else { return false }
            while true {
                let before = i
                skipSpace()
                let hadSpace = i > before
                guard let c = peek() else { return true }
                if c == UInt8(ascii: ",") || c == UInt8(ascii: ")") { i = before; return true }
                if c == UInt8(ascii: ">") || c == UInt8(ascii: "+") || c == UInt8(ascii: "~") {
                    if c == UInt8(ascii: ">"), peek(1) == UInt8(ascii: ">") { return false }
                    i += 1
                    skipSpace()
                    guard parseCompound() else { return false }
                } else if hadSpace {
                    guard parseCompound() else { return false }
                } else {
                    return false
                }
            }
        }

        mutating func parseCompound() -> Bool {
            var parts = 0
            if let c = peek() {
                if c == UInt8(ascii: "*") {
                    i += 1; parts += 1
                    if peek() == UInt8(ascii: "|") { return false }
                } else if parseIdent() {
                    parts += 1
                    if peek() == UInt8(ascii: "|") { return false }
                }
            }
            while let c = peek() {
                switch c {
                case UInt8(ascii: "#"), UInt8(ascii: "."):
                    i += 1
                    guard parseIdent() else { return false }
                case UInt8(ascii: "["):
                    guard parseAttribute() else { return false }
                case UInt8(ascii: ":"):
                    guard parsePseudo() else { return false }
                default:
                    return parts > 0
                }
                parts += 1
            }
            return parts > 0
        }

        /// CSS identifier: optional leading `-`, then a name start, then name characters; escapes allowed.
        mutating func parseIdent() -> Bool {
            let start = i
            if peek() == UInt8(ascii: "-") {
                i += 1
                if peek() == UInt8(ascii: "-") { i += 1 } else if !parseNameStart() { i = start; return false }
            } else if !parseNameStart() { return false }
            while let c = peek() {
                if CSSSelectorValidator.isNameChar(c) { i += 1 }
                else if c == UInt8(ascii: "\\") { guard parseEscape() else { return false } }
                else { break }
            }
            return true
        }

        mutating func parseNameStart() -> Bool {
            guard let c = peek() else { return false }
            if CSSSelectorValidator.isNameStart(c) { i += 1; return true }
            if c == UInt8(ascii: "\\") { return parseEscape() }
            return false
        }

        mutating func parseEscape() -> Bool {
            guard peek() == UInt8(ascii: "\\"), let n = peek(1) else { return false }
            if n == 0x0A || n == 0x0D || n == 0x0C { return false }
            i += 2
            if CSSSelectorValidator.isHex(n) {
                var count = 1
                while count < 6, let c = peek(), CSSSelectorValidator.isHex(c) { i += 1; count += 1 }
                if let c = peek(), CSSSelectorValidator.isSpace(c) { i += 1 }
            }
            return true
        }

        mutating func parseString() -> Bool {
            guard let q = peek(), q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") else { return false }
            i += 1
            while let c = peek() {
                if c == q { i += 1; return true }
                if c == 0x0A || c == 0x0D || c == 0x0C { return false }
                if c == UInt8(ascii: "\\") {
                    guard peek(1) != nil else { return false }
                    i += 2
                } else { i += 1 }
            }
            return false
        }

        mutating func parseAttribute() -> Bool {
            guard peek() == UInt8(ascii: "[") else { return false }
            i += 1
            skipSpace()
            guard parseIdent() else { return false }
            skipSpace()
            if peek() == UInt8(ascii: "]") { i += 1; return true }
            // operator
            var opLen = 0
            if let c = peek() {
                if c == UInt8(ascii: "=") { opLen = 1 }
                else if peek(1) == UInt8(ascii: "="), [UInt8(ascii: "~"), UInt8(ascii: "|"), UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "*")].contains(c) { opLen = 2 }
            }
            guard opLen > 0 else { return false }
            i += opLen
            skipSpace()
            if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") {
                guard parseString() else { return false }
            } else {
                guard parseIdent() else { return false }
            }
            let afterValue = i
            skipSpace()
            if let f = peek(), f == UInt8(ascii: "i") || f == UInt8(ascii: "I") || f == UInt8(ascii: "s") || f == UInt8(ascii: "S"), i > afterValue || s[afterValue - 1] == UInt8(ascii: "\"") || s[afterValue - 1] == UInt8(ascii: "'") {
                i += 1
                skipSpace()
            }
            guard peek() == UInt8(ascii: "]") else { return false }
            i += 1
            return true
        }

        mutating func parsePseudo() -> Bool {
            guard peek() == UInt8(ascii: ":") else { return false }
            i += 1
            if peek() == UInt8(ascii: ":") {
                i += 1
                let name = readName()
                return name == "before" || name == "after"
            }
            let name = readName()
            guard !name.isEmpty else { return false }
            if peek() == UInt8(ascii: "(") {
                i += 1
                return parseFunctionalArguments(name)
            }
            if name == "before" || name == "after" { return true }
            return CSSSelectorValidator.simplePseudoClasses.contains(name)
        }

        mutating func readName() -> String {
            let start = i
            while let c = peek(), CSSSelectorValidator.isNameChar(c) { i += 1 }
            return String(decoding: s[start..<i], as: UTF8.self).lowercased()
        }

        /// Consumes arguments and the closing parenthesis.
        mutating func parseFunctionalArguments(_ name: String) -> Bool {
            if CSSSelectorValidator.selectorListPseudoClasses.contains(name) {
                guard parseList(relative: false) else { return false }
                return closeParen()
            }
            switch name {
            case "has":
                guard hasDepth == 0 else { return false }
                hasDepth += 1
                defer { hasDepth -= 1 }
                guard parseList(relative: true) else { return false }
                return closeParen()
            case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
                return parseNth(allowOf: name == "nth-child" || name == "nth-last-child")
            case "lang":
                skipSpace()
                var count = 0
                while true {
                    skipSpace()
                    if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") { guard parseString() else { return false } }
                    else { guard parseIdent() else { return false } }
                    count += 1
                    skipSpace()
                    if peek() == UInt8(ascii: ",") { i += 1; continue }
                    break
                }
                return count > 0 && closeParen()
            case "dir":
                skipSpace()
                let v = readName()
                skipSpace()
                return (v == "ltr" || v == "rtl") && closeParen()
            default:
                return false
            }
        }

        mutating func closeParen() -> Bool {
            skipSpace()
            guard peek() == UInt8(ascii: ")") else { return false }
            i += 1
            return true
        }

        mutating func parseNth(allowOf: Bool) -> Bool {
            // Find the end of the An+B expression: up to ")" or the keyword "of".
            var j = i
            var expr: [UInt8] = []
            while j < s.count, s[j] != UInt8(ascii: ")") {
                if allowOf, isOfKeyword(at: j) { break }
                expr.append(s[j])
                j += 1
            }
            guard Parser.isValidNth(expr) else { return false }
            i = j
            if allowOf, isOfKeyword(at: i) {
                i += 2
                guard let c = peek(), CSSSelectorValidator.isSpace(c) else { return false }
                var sub = Parser(Array(s[i...]), hasDepth: hasDepth)
                guard sub.parseList(relative: false) else { return false }
                i += sub.i
            }
            return closeParen()
        }

        func isOfKeyword(at j: Int) -> Bool {
            guard j > 0, j + 2 < s.count, CSSSelectorValidator.isSpace(s[j - 1]) else { return false }
            return (s[j] == UInt8(ascii: "o") || s[j] == UInt8(ascii: "O")) && (s[j + 1] == UInt8(ascii: "f") || s[j + 1] == UInt8(ascii: "F")) && CSSSelectorValidator.isSpace(s[j + 2])
        }

        /// `odd`, `even`, `An+B`, `B` (whitespace around the sign tolerated).
        static func isValidNth(_ raw: [UInt8]) -> Bool {
            let t = raw.filter { !CSSSelectorValidator.isSpace($0) }.map { $0 | 0x20 }  // lowercase ASCII letters
            guard !t.isEmpty else { return false }
            let word = String(decoding: t, as: UTF8.self)
            if word == "odd" || word == "even" { return true }
            var k = 0
            func sign() { if k < t.count, t[k] == 0x2B || t[k] == 0x2D { k += 1 } }
            func digits() -> Int { let st = k; while k < t.count, CSSSelectorValidator.isDigit(t[k]) { k += 1 }; return k - st }
            sign()
            let leading = digits()
            if k < t.count, t[k] == UInt8(ascii: "n") {
                k += 1
                if k < t.count {
                    guard t[k] == 0x2B || t[k] == 0x2D else { return false }
                    k += 1
                    guard digits() > 0 else { return false }
                }
                return k == t.count
            }
            return leading > 0 && k == t.count
        }
    }
}
