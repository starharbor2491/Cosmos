import Foundation
import CosmosCore

/// `StorableLinkRouting.json`: where links from other apps open. Observed shape:
///
///     { "defaultDestination": {"littleArc": {"_0": {"mostRecent": {}}}},
///       "rules": [{ "id": ..., "sourceComponents": [{"id": ..., "componentType":
///                      {"urlMatch": {"_0": {"contains": {}}, "_1": "text"}}}],
///                   "destination": {"space": {"_0": {"mostRecent": {}}}} }] }
///
/// A rule applies when all its components match. A rule with a condition Cosmos cannot express is skipped (and
/// counted) rather than imported with a broader meaning.
enum ArcLinkRouting {
    static func parse(_ root: Any?, spaceIDs: Set<UUID>, firstSpaceByProfile: [ArcProfileKey: UUID], notes: ImportNotes) -> LinkRouting? {
        guard let file = ArcJSON.dict(root) else { return nil }
        let context = Context(spaceIDs: spaceIDs, firstSpaceByProfile: firstSpaceByProfile, notes: notes)

        var routing = LinkRouting()
        if file["defaultDestination"] != nil {
            if let d = context.destination(file["defaultDestination"]) {
                routing.defaultDestination = d
            } else {
                notes.warn("The default link destination was not recognised; Probe was used")
            }
        }

        for (index, value) in (ArcJSON.list(file["rules"]) ?? []).enumerated() {
            guard let rule = ArcJSON.dict(value) else { notes.skip("linkRule"); continue }
            let components = (ArcJSON.list(rule["sourceComponents"]) ?? []).compactMap { ArcJSON.dict($0) }
            let matches = components.map { context.match($0["componentType"]) }
            guard !components.isEmpty, !matches.contains(where: { $0 == nil }), let destination = context.destination(rule["destination"]) else {
                notes.skip("linkRule")
                continue
            }
            routing.rules.append(LinkRule(id: ArcID.optional(rule["id"]) ?? ArcID.uuid("cosmos.arc-import.link-rule.\(index)"),
                                          matches: matches.compactMap { $0 }, destination: destination))
        }
        return routing
    }

    private struct Context {
        var spaceIDs: Set<UUID>
        var firstSpaceByProfile: [ArcProfileKey: UUID]
        var notes: ImportNotes

        func match(_ componentType: Any?) -> LinkRule.Match? {
            guard let (name, payload) = ArcJSON.enumCase(componentType), name == "urlMatch", let p = ArcJSON.dict(payload),
                  let text = ArcJSON.string(p["_1"]) else { return nil }
            let kind = (ArcJSON.enumCase(p["_0"])?.name ?? (p["_0"] as? String) ?? "").lowercased()
            switch kind {
            case "contains": return .urlContains(text)
            case "startswith", "beginswith", "prefix", "hasprefix": return .urlPrefix(text)
            case "endswith", "suffix", "hassuffix": return .urlSuffix(text)
            case "host", "hostname", "domain": return .host(text.lowercased())
            case "matches", "equals", "equal", "is", "exactly":
                // "matches" is not documented: a bare domain becomes a host rule, a full URL a prefix rule, and
                // anything that looks like a pattern is left out rather than guessed at.
                guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "[](){}*+?\\^$| ")) == nil else { return nil }
                if text.contains("://") { return .urlPrefix(text) }
                if text.contains("."), !text.contains("/") { return .host(text.lowercased()) }
                return nil
            default: return nil
            }
        }

        /// `littleArc(...)` is Probe; `space(mostRecent)` the most recently used space; a space or profile target
        /// carrying an id points at that space (or the first space of that profile).
        func destination(_ value: Any?) -> LinkDestination? {
            guard let (name, payload) = ArcJSON.enumCase(value) else { return nil }
            switch name {
            case "littleArc":
                return .probe
            case "space", "profile":
                let target = ArcJSON.unwrap(payload)
                if let (targetName, targetPayload) = ArcJSON.enumCase(target) {
                    if targetName == "mostRecent" { return .mostRecentSpace }
                    if let raw = ArcJSON.firstString(in: targetPayload) {
                        let id = ArcID.uuid(raw)
                        if spaceIDs.contains(id) { return .space(id) }
                        if let space = firstSpaceByProfile[.custom(id)] { return .space(space) }
                    }
                    if targetName == "default", let space = firstSpaceByProfile[.default] { return .space(space) }
                } else if let raw = target as? String {
                    let id = ArcID.uuid(raw)
                    if spaceIDs.contains(id) { return .space(id) }
                }
                notes.warn("A link destination pointed at a space that is not in the profile; the most recent space was used")
                return .mostRecentSpace
            default:
                return nil
            }
        }
    }
}
