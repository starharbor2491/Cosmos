import Foundation
import CosmosEngine

/// Content blocking as a Chromium extension Cosmos writes itself: the compiled filter lists become
/// `declarativeNetRequest` rulesets (Chromium matches every request against them, in its own process) and content
/// scripts that hide page elements. The user's per-site switch is part of it, so a change rewrites and reloads it.
enum BlockerExtension {
    struct Cosmetic: Codable {
        var generic: [String] = []
        var specific: [String: [String]] = [:]
        var exceptions: [String: [String]] = [:]
        var genericHide: [String] = []
        var hideNothing: [String] = []
    }

    /// Writes the extension into `folder`. False when there is nothing to block.
    @discardableResult
    static func write(_ lists: [CompiledBlockingList], allowlist: [String], to folder: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }

        var resources: [[String: Any]] = []
        for (i, list) in lists.enumerated() where list.kind == .network {
            let file = "rules-\(i + 1).json"
            guard (try? Data(numbered(list.json).utf8).write(to: folder.appendingPathComponent(file))) != nil else { continue }
            resources.append(["id": "r\(i + 1)", "enabled": true, "path": file])
        }
        let hosts = allowlist.map { $0.lowercased() }.filter { !$0.isEmpty }
        if !hosts.isEmpty {
            let allow: [[String: Any]] = [["id": 1, "priority": 100, "action": ["type": "allowAllRequests"],
                                           "condition": ["requestDomains": hosts, "resourceTypes": ["main_frame", "sub_frame"]]]]
            if let data = try? JSONSerialization.data(withJSONObject: allow), (try? data.write(to: folder.appendingPathComponent("allow.json"))) != nil {
                resources.append(["id": "allow", "enabled": true, "path": "allow.json"])
            }
        }

        let cosmetic = merged(lists)
        var scripts: [[String: Any]] = []
        let quiet = Array(Set(hosts + cosmetic.hideNothing)).sorted()
        let noGeneric = Array(Set(quiet + cosmetic.genericHide)).sorted()
        if !cosmetic.generic.isEmpty {
            let css = styleSheet(Array(Set(cosmetic.generic)).sorted())
            if (try? Data(css.utf8).write(to: folder.appendingPathComponent("generic.css"))) != nil {
                var entry: [String: Any] = ["matches": ["<all_urls>"], "css": ["generic.css"], "all_frames": true,
                                            "match_about_blank": true, "run_at": "document_start"]
                if !noGeneric.isEmpty { entry["exclude_matches"] = noGeneric.flatMap(patterns(for:)) }
                scripts.append(entry)
            }
        }
        let generic = Set(cosmetic.generic)
        // Exceptions for generic selectors have to undo a hiding rule; the others only keep a site rule from applying.
        let undo = cosmetic.exceptions.mapValues { $0.filter(generic.contains) }.filter { !$0.value.isEmpty }
        if !cosmetic.specific.isEmpty || !undo.isEmpty {
            let data: [String: Any] = ["specific": cosmetic.specific, "exceptions": cosmetic.exceptions, "undo": undo]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
                let script = "const COSMOS_HIDING = \(String(decoding: json, as: UTF8.self));\n" + siteScript
                if (try? Data(script.utf8).write(to: folder.appendingPathComponent("sites.js"))) != nil {
                    var entry: [String: Any] = ["matches": ["<all_urls>"], "js": ["sites.js"], "run_at": "document_start"]
                    if !quiet.isEmpty { entry["exclude_matches"] = quiet.flatMap(patterns(for:)) }
                    scripts.append(entry)
                }
            }
        }
        guard !resources.isEmpty || !scripts.isEmpty else { return false }

        var manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Cosmos Blocker",
            "description": "Cosmos's content blocking. Written by Cosmos from your filter lists.",
            "version": "1.0",
            "permissions": ["declarativeNetRequest"],
        ]
        if !resources.isEmpty { manifest["declarative_net_request"] = ["rule_resources": resources] }
        if !scripts.isEmpty { manifest["content_scripts"] = scripts }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: folder.appendingPathComponent("manifest.json"))) != nil
    }

    /// The lists' hiding rules, together.
    static func merged(_ lists: [CompiledBlockingList]) -> Cosmetic {
        var cosmetic = Cosmetic()
        for list in lists where list.kind == .cosmetic {
            guard let one = try? JSONDecoder().decode(Cosmetic.self, from: Data(list.json.utf8)) else { continue }
            cosmetic.generic += one.generic
            cosmetic.specific.merge(one.specific) { $0 + $1 }
            cosmetic.exceptions.merge(one.exceptions) { $0 + $1 }
            cosmetic.genericHide += one.genericHide
            cosmetic.hideNothing += one.hideNothing
        }
        return cosmetic
    }

    /// The hiding as one page script, for a profile the extension does not run in: the style sheets its content scripts
    /// put in, on the same sites. Nil when there is nothing to hide.
    static func hidingScript(_ lists: [CompiledBlockingList], allowlist: [String]) -> String? {
        let cosmetic = merged(lists)
        let hosts = allowlist.map { $0.lowercased() }.filter { !$0.isEmpty }
        let quiet = Array(Set(hosts + cosmetic.hideNothing)).sorted()
        let noGeneric = Array(Set(quiet + cosmetic.genericHide)).sorted()
        let generic = Set(cosmetic.generic)
        let undo = cosmetic.exceptions.mapValues { $0.filter(generic.contains) }.filter { !$0.value.isEmpty }
        guard !generic.isEmpty || !cosmetic.specific.isEmpty || !undo.isEmpty else { return nil }
        let data: [String: Any] = ["specific": cosmetic.specific, "exceptions": cosmetic.exceptions, "undo": undo]
        guard let hiding = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let quietJSON = try? JSONSerialization.data(withJSONObject: quiet), let noGenericJSON = try? JSONSerialization.data(withJSONObject: noGeneric)
        else { return nil }
        let css = generic.isEmpty ? "" : styleSheet(generic.sorted())
        return """
        (function () {
          const host = location.hostname.toLowerCase();
          const under = (list) => list.some(d => host === d || host.endsWith('.' + d));
          if (under(\(String(decoding: quietJSON, as: UTF8.self)))) return;
          // A script that runs as the document starts can come before its root element.
          const whenRoot = (f) => {
            if (document.documentElement) { f(); return; }
            new MutationObserver((m, o) => { if (document.documentElement) { o.disconnect(); f(); } }).observe(document, { childList: true });
          };
          const generic = \(ChromiumResources.jsString(css));
          if (generic && !under(\(String(decoding: noGenericJSON, as: UTF8.self)))) whenRoot(() => {
            const style = document.createElement('style');
            style.textContent = generic;
            (document.head || document.documentElement).appendChild(style);
          });
          const COSMOS_HIDING = \(String(decoding: hiding, as: UTF8.self));
          whenRoot(() => { \(siteScript) });
        })();
        """
    }

    /// A ruleset file: the list's rules with ids.
    static func numbered(_ json: String) -> String {
        guard let rules = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return "[]" }
        let withIDs = rules.enumerated().map { i, rule -> [String: Any] in var r = rule; r["id"] = i + 1; return r }
        guard let data = try? JSONSerialization.data(withJSONObject: withIDs) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Match patterns for a site and its subdomains.
    static func patterns(for host: String) -> [String] { ["*://\(host)/*", "*://*.\(host)/*"] }

    /// Selectors in groups, so the rare one Chromium rejects only costs its own group.
    static func styleSheet(_ selectors: [String], groupSize: Int = 50) -> String {
        stride(from: 0, to: selectors.count, by: groupSize).map { start in
            selectors[start..<min(selectors.count, start + groupSize)].joined(separator: ",\n") + " { display: none !important; }"
        }.joined(separator: "\n")
    }

    /// Hides the selectors for this site (and its parent domains), minus its exceptions, and undoes generic hiding it is
    /// excepted from.
    static let siteScript = """
    (function () {
      const parts = location.hostname.toLowerCase().split('.');
      const hosts = [];
      for (let i = 0; i < parts.length - 1; i++) hosts.push(parts.slice(i).join('.'));
      const except = new Set();
      hosts.forEach(h => (COSMOS_HIDING.exceptions[h] || []).forEach(s => except.add(s)));
      const hide = [], undo = [];
      hosts.forEach(h => (COSMOS_HIDING.specific[h] || []).forEach(s => { if (!except.has(s)) hide.push(s); }));
      hosts.forEach(h => (COSMOS_HIDING.undo[h] || []).forEach(s => undo.push(s)));
      if (!hide.length && !undo.length) return;
      const css = hide.map(s => s + ' { display: none !important; }').concat(undo.map(s => s + ' { display: revert !important; }')).join('\\n');
      const style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
    })();
    """
}
