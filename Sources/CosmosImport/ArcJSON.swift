import CryptoKit
import Foundation

/// Reading helpers for Arc's JSON, which is Swift `Codable` output with a few irregular conventions:
/// `[ID: Value]` dictionaries as flat key/value arrays, enums with payloads as one-key objects, and dates in
/// seconds since 2001-01-01. Everything here is lenient: wrong types give `nil`, never a crash.
enum ArcJSON {
    typealias Record = (key: String?, value: [String: Any])

    // MARK: Loading

    static func load(_ url: URL) throws -> Any {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)   // read fully: Arc may rewrite the file while we hold it
        } catch {
            throw ArcImportError.unreadable(file: name, reason: error.localizedDescription)
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ArcImportError.malformed(file: name, reason: "not valid JSON")
        }
    }

    // MARK: Scalars

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func list(_ v: Any?) -> [Any]? { v as? [Any] }

    static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A JSON number as `Double`. Booleans are not numbers here (`NSNumber` would otherwise happily convert them).
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func flag(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Arc's dates are seconds since 2001-01-01, the same reference date as Foundation. Dropped to whole seconds
    /// because Cosmos files store whole seconds (so an imported workspace equals its saved-and-reloaded self).
    /// Zero, negative and absurdly large values mean "unset".
    static func date(_ v: Any?) -> Date? {
        guard let s = number(v), s > 0, s < 4_000_000_000 else { return nil }
        return Date(timeIntervalSinceReferenceDate: s.rounded(.down))
    }

    static func url(_ raw: String?) -> URL? {
        guard let s = string(raw), let url = URL(string: s), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    /// Addresses that only mean something inside Arc or Chromium (settings pages, extension pages, new-tab pages).
    static let internalSchemes: Set<String> = ["arc", "chrome", "chrome-extension", "chrome-untrusted", "chrome-error", "devtools"]

    static func isInternal(_ url: URL) -> Bool { internalSchemes.contains(url.scheme?.lowercased() ?? "") }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    // MARK: Enums

    /// A Swift enum with an associated value: one key (the case), whose value is the payload.
    static func enumCase(_ v: Any?) -> (name: String, payload: Any)? {
        guard let d = v as? [String: Any], d.count == 1, let first = d.first else { return nil }
        return (first.key, first.value)
    }

    /// The payload of a one-value case (`{"_0": x}`), or the payload itself.
    static func unwrap(_ payload: Any?) -> Any? {
        if let d = payload as? [String: Any], let inner = d["_0"] { return inner }
        return payload
    }

    /// An enum case name that is safe to put in a report: letters, digits and `_.-` only, at most 40 characters.
    static func safeCaseName(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }.prefix(40))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    // MARK: Collections

    /// A `[ID: Value]` dictionary as Swift writes it: `[id, {...}, id, {...}]`. Also accepts a plain array of
    /// objects (the key is then `nil`) and a keyed object, so a future format change degrades instead of breaking.
    static func records(_ value: Any?) -> [Record] {
        if let d = value as? [String: Any] {
            return d.sorted { $0.key < $1.key }.compactMap { k, v in (v as? [String: Any]).map { (key: k, value: $0) } }
        }
        guard let a = value as? [Any] else { return [] }
        var out: [Record] = []
        var i = 0
        while i < a.count {
            if let k = a[i] as? String, i + 1 < a.count, let v = a[i + 1] as? [String: Any] {
                out.append((key: k, value: v)); i += 2
            } else if let v = a[i] as? [String: Any] {
                out.append((key: nil, value: v)); i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// A flat `[key, value, key, value]` array of any value types.
    static func pairs(_ value: Any?) -> [(key: Any, value: Any)] {
        guard let a = value as? [Any] else { return [] }
        var out: [(key: Any, value: Any)] = []
        var i = 0
        while i + 1 < a.count { out.append((a[i], a[i + 1])); i += 2 }
        return out
    }

    /// Depth-first search for the first value stored under any of `keys`, trying the keys in the given order at
    /// each level.
    static func find(_ keys: [String], in value: Any?, depth: Int = 0) -> Any? {
        guard depth < 12 else { return nil }
        if let d = value as? [String: Any] {
            for k in keys { if let v = d[k] { return v } }
            for (_, child) in d.sorted(by: { $0.key < $1.key }) {
                if let r = find(keys, in: child, depth: depth + 1) { return r }
            }
        } else if let a = value as? [Any] {
            for child in a { if let r = find(keys, in: child, depth: depth + 1) { return r } }
        }
        return nil
    }

    /// The first string found anywhere inside `value`.
    static func firstString(in value: Any?, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let s = string(value) { return s }
        if let d = value as? [String: Any] {
            for (_, child) in d.sorted(by: { $0.key < $1.key }) { if let s = firstString(in: child, depth: depth + 1) { return s } }
        } else if let a = value as? [Any] {
            for child in a { if let s = firstString(in: child, depth: depth + 1) { return s } }
        }
        return nil
    }

    /// Every string found anywhere inside `value`.
    static func allStrings(in value: Any?, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let s = value as? String { return [s] }
        if let d = value as? [String: Any] { return d.sorted { $0.key < $1.key }.flatMap { allStrings(in: $0.value, depth: depth + 1) } }
        if let a = value as? [Any] { return a.flatMap { allStrings(in: $0, depth: depth + 1) } }
        return []
    }
}

/// Arc item, space and profile ids are usually UUIDs, but not always: the first space and its containers use
/// fixed strings such as `thebrowser.company.defaultPersonalSpaceID`. Cosmos ids are UUIDs, so UUID-shaped ids are
/// kept as they are and anything else is mapped to a stable UUID derived from the string. Importing the same
/// profile twice therefore yields the same ids.
enum ArcID {
    static func uuid(_ raw: String) -> UUID {
        if let u = UUID(uuidString: raw) { return u }
        var b = Array(SHA256.hash(data: Data(("cosmos.arc-import|" + raw).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func optional(_ raw: Any?) -> UUID? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return uuid(s)
    }
}
