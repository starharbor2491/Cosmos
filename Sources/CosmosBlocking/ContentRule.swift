import Foundation

/// One entry of a WebKit content-rule list, with a deterministic JSON form.
struct ContentRule: Hashable {
    enum Condition: Hashable {
        case ifDomain([String])
        case unlessDomain([String])
    }

    enum Action: Hashable {
        case block
        case ignorePreviousRules
        case cssDisplayNone(selector: String)
    }

    var urlFilter: String
    var caseSensitive = false
    var resourceTypes: [String] = []
    var loadType: String?
    var loadContext: String?
    var condition: Condition?
    var action: Action

    /// Compact JSON with a fixed key order, so output is stable and cacheable.
    var json: String {
        var s = "{\"trigger\":{\"url-filter\":"
        JSONText.appendString(urlFilter, to: &s)
        if caseSensitive { s += ",\"url-filter-is-case-sensitive\":true" }
        if !resourceTypes.isEmpty { s += ",\"resource-type\":"; JSONText.appendArray(resourceTypes, to: &s) }
        if let loadType { s += ",\"load-type\":[\"\(loadType)\"]" }
        if let loadContext { s += ",\"load-context\":[\"\(loadContext)\"]" }
        switch condition {
        case .ifDomain(let d)?: s += ",\"if-domain\":"; JSONText.appendArray(d, to: &s)
        case .unlessDomain(let d)?: s += ",\"unless-domain\":"; JSONText.appendArray(d, to: &s)
        case nil: break
        }
        s += "},\"action\":{\"type\":"
        switch action {
        case .block: s += "\"block\""
        case .ignorePreviousRules: s += "\"ignore-previous-rules\""
        case .cssDisplayNone(let selector):
            s += "\"css-display-none\",\"selector\":"
            JSONText.appendString(selector, to: &s)
        }
        s += "}}"
        return s
    }
}

enum JSONText {
    static func appendString(_ value: String, to out: inout String) {
        out.append("\"")
        var needsEscape = false
        for u in value.utf8 where u < 0x20 || u == 0x22 || u == 0x5C { needsEscape = true; break }
        if !needsEscape {
            out.append(value)
        } else {
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out.append("\\\"")
                case "\\": out.append("\\\\")
                case "\n": out.append("\\n")
                case "\r": out.append("\\r")
                case "\t": out.append("\\t")
                default:
                    if scalar.value < 0x20 { out.append(String(format: "\\u%04x", scalar.value)) }
                    else { out.unicodeScalars.append(scalar) }
                }
            }
        }
        out.append("\"")
    }

    static func appendArray(_ values: [String], to out: inout String) {
        out.append("[")
        for (i, v) in values.enumerated() {
            if i > 0 { out.append(",") }
            appendString(v, to: &out)
        }
        out.append("]")
    }
}
