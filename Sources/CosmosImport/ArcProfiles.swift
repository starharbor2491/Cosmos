import Foundation
import CosmosCore

/// Arc's browser profiles. A profile exists in Arc as a separate Chromium user-data directory with its own
/// cookies and logins; spaces point at one. The default profile is implicit (`{"default": true}`), custom ones are
/// listed in `StorableProfiles.json` / `StorableProfileContainers.json`.
///
/// Those two files are not present in the profiles this importer was developed against, so their layout is
/// inferred: any object that has an id and a name (`name`, `title`, `displayName`, ...) is taken to be a profile,
/// wherever it sits in the file and whether or not the surrounding dictionary uses Arc's flat-array encoding.
struct ArcProfileTable {
    private(set) var profiles: [Profile]
    private var idByKey: [ArcProfileKey: UUID]

    private static let defaultID = ArcID.uuid("cosmos.arc-import.default-profile")

    /// `files` are the decoded profile files that exist (usually zero).
    init(files: [Any]) {
        var found: [ArcProfileRecord] = []
        for file in files { ArcProfileRecord.collect(file, key: nil, depth: 0, into: &found) }

        var defaultName: String?
        var custom: [ArcProfileRecord] = []
        var seen = Set<String>()
        for record in found {
            if record.isDefault {
                if defaultName == nil { defaultName = record.name }
            } else if let id = record.id, seen.insert(id.lowercased()).inserted {
                custom.append(record)
            }
        }

        var profiles = [Profile(id: Self.defaultID, name: defaultName ?? "Personal", isDefault: true)]
        var idByKey: [ArcProfileKey: UUID] = [.default: Self.defaultID]
        for record in custom {
            guard let raw = record.id else { continue }
            let id = ArcID.uuid(raw)
            guard idByKey[.custom(id)] == nil, id != Self.defaultID else { continue }
            profiles.append(Profile(id: id, name: record.name ?? "Profile \(profiles.count + 1)"))
            idByKey[.custom(id)] = id
        }
        self.profiles = profiles
        self.idByKey = idByKey
    }

    /// The Cosmos profile for an Arc profile key; a custom profile that no file described gets a placeholder name.
    mutating func profileID(for key: ArcProfileKey, notes: ImportNotes) -> UUID {
        if let id = idByKey[key] { return id }
        guard case .custom(let id) = key else { return Self.defaultID }
        profiles.append(Profile(id: id, name: "Profile \(profiles.count + 1)"))
        idByKey[key] = id
        notes.warn("A space used a profile that Arc's profile files do not describe; it was named generically")
        return id
    }
}

struct ArcProfileRecord {
    var id: String?
    var name: String?
    var isDefault: Bool

    private static let nameKeys = ["name", "title", "displayName", "profileName", "customName"]

    static func collect(_ value: Any?, key: String?, depth: Int, into out: inout [ArcProfileRecord]) {
        guard depth < 8 else { return }
        if let d = value as? [String: Any] {
            let name = nameKeys.lazy.compactMap { ArcJSON.string(d[$0]) }.first
            let id = ["id", "profileID", "uuid"].lazy.compactMap { ArcJSON.string(d[$0]) }.first ?? key
            let flagged = ArcJSON.flag(d["isDefault"]) == true || ArcJSON.flag(d["default"]) == true
            let named = id?.lowercased() == "default" || (id?.lowercased().contains("default") == true && name != nil)
            if name != nil || flagged {
                out.append(ArcProfileRecord(id: id, name: name, isDefault: flagged || named))
            }
            for (k, child) in d.sorted(by: { $0.key < $1.key }) where child is [String: Any] || child is [Any] {
                collect(child, key: k, depth: depth + 1, into: &out)
            }
        } else if let a = value as? [Any] {
            var i = 0
            while i < a.count {
                if let k = a[i] as? String, i + 1 < a.count, a[i + 1] is [String: Any] {
                    collect(a[i + 1], key: k, depth: depth + 1, into: &out); i += 2
                } else {
                    collect(a[i], key: nil, depth: depth + 1, into: &out); i += 1
                }
            }
        }
    }
}
