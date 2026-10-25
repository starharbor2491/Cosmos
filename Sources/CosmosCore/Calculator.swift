import Foundation

/// The Command Bar's inline calculator: `12*(3+4)`, `2^10`, `15% of 80`, `sqrt(2)`. A small recursive-descent parser;
/// returns `nil` for anything that isn't clearly arithmetic so ordinary searches are never hijacked.
public enum Calculator {
    public static func evaluate(_ input: String) -> Double? {
        var text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // "15% of 80" -> (15/100)*80
        if let r = text.range(of: #"^([0-9.]+)\s*%\s*of\s*([0-9.]+)$"#, options: .regularExpression) {
            let parts = text[r].components(separatedBy: CharacterSet(charactersIn: "% ")).filter { !$0.isEmpty && $0 != "of" }
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]) { return a / 100 * b }
        }
        text = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: ",", with: "")
        // Must contain at least one digit and one operator/function, and only calculator characters.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^%() abcdefghijklmnopqrstuvwxyz")
        guard text.unicodeScalars.allSatisfy(allowed.contains), text.contains(where: \.isNumber) else { return nil }
        let hasOperator = text.dropFirst().contains(where: { "+-*/^%".contains($0) }) || text.contains("sqrt") || text.contains("(")
        guard hasOperator else { return nil }
        var p = Parser(Array(text.filter { $0 != " " }))
        guard let v = p.parseExpression(), p.atEnd, v.isFinite else { return nil }
        return v
    }

    public static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.usesGroupingSeparator = false
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }
        var atEnd: Bool { i >= chars.count }

        mutating func parseExpression() -> Double? {
            guard var v = parseTerm() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = parseTerm() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func parseTerm() -> Double? {
            guard var v = parsePower() else { return nil }
            while i < chars.count, chars[i] == "*" || chars[i] == "/" || chars[i] == "%" {
                let op = chars[i]; i += 1
                guard let r = parsePower() else { return nil }
                switch op {
                case "*": v *= r
                case "/": guard r != 0 else { return nil }; v /= r
                default: guard r != 0 else { return nil }; v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let e = parsePower() else { return nil }
                return pow(base, e)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return parseUnary().map { -$0 } }
            if i < chars.count, chars[i] == "+" { i += 1; return parseUnary() }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                i += 1
                guard let v = parseExpression(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            if chars[i].isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                if name == "pi" { return .pi }
                if name == "e" { return M_E }
                guard i < chars.count, chars[i] == "(" else { return nil }
                i += 1
                guard let v = parseExpression(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                switch name {
                case "sqrt": return v >= 0 ? v.squareRoot() : nil
                case "sin": return sin(v)
                case "cos": return cos(v)
                case "tan": return tan(v)
                case "ln": return v > 0 ? log(v) : nil
                case "log": return v > 0 ? log10(v) : nil
                case "abs": return abs(v)
                case "round": return v.rounded()
                default: return nil
                }
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard start != i else { return nil }
            return Double(String(chars[start..<i]))
        }
    }
}
