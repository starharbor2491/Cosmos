import Foundation

/// The copy of an extension that Chromium loads. Cosmos's pages are not Chrome tabs (CEF's Alloy style), so what an
/// extension asks of its tabs and its toolbar button (`chrome.tabs`, `chrome.windows`, `chrome.scripting`,
/// `chrome.action`) is answered by Cosmos, through scripts that run ahead of the extension's own: in its service worker,
/// in its content scripts and in its pages. The copy is the extension's folder (an APFS clone: no time or space) with
/// those scripts in a folder of their own, and the manifest and the pages pointing at them.
enum ExtensionStage {
    /// (Chromium refuses an extension with a file or folder whose name starts with "_".)
    static let folder = "cosmos-extension"
    static let workerShim = "\(folder)/worker.js"
    static let contentShim = "\(folder)/content.js"
    static let pageShim = "\(folder)/page.js"
    /// The worker Chromium starts, which runs Cosmos's script and then the extension's own.
    static let workerName = "cosmos-worker.js"

    struct Scripts {
        let worker: String
        let content: String
        let page: String
    }

    /// Makes `destination` the copy of `source`, replacing what was there. An extension with a link in its folder is
    /// refused, as is one whose worker is outside it: the copy is written to, and a link would take those writes to the
    /// file it points at.
    static func stage(_ source: URL, to destination: URL, scripts: Scripts) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        let items = fm.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = items?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            try? fm.removeItem(at: destination)
            throw CDPError(code: -4, message: "The extension has a link to a file outside its folder (\(item.lastPathComponent)).")
        }
        try fm.createDirectory(at: destination.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        try Data(scripts.worker.utf8).write(to: destination.appendingPathComponent(workerShim))
        try Data(scripts.content.utf8).write(to: destination.appendingPathComponent(contentShim))
        try Data(scripts.page.utf8).write(to: destination.appendingPathComponent(pageShim))
        let manifestFile = destination.appendingPathComponent("manifest.json")
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any] else {
            throw CDPError(code: -4, message: "The extension's manifest.json is not a JSON object")
        }
        let (rewritten, worker) = rewrite(manifest)
        guard !worker.path.split(separator: "/").contains("..") else {
            try? fm.removeItem(at: destination)
            throw CDPError(code: -4, message: "The extension's service worker is outside its folder.")
        }
        try Data(worker.source.utf8).write(to: destination.appendingPathComponent(worker.path))
        try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys]).write(to: manifestFile)
        let files = fm.enumerator(at: destination, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard ["html", "htm"].contains(file.pathExtension.lowercased()), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try Data(withPageShim(text).utf8).write(to: file)
        }
    }

    /// Points a manifest at Cosmos's scripts: a worker that runs Cosmos's first and then the extension's own (made next to
    /// it, so the extension's relative `importScripts` resolve as before), and Cosmos's content script ahead of each set
    /// of the extension's that runs in the extension's world. Returns the worker to write too.
    static func rewrite(_ manifest: [String: Any]) -> (manifest: [String: Any], worker: (path: String, source: String)) {
        var m = manifest
        var background = m["background"] as? [String: Any] ?? [:]
        let own = (background["service_worker"] as? String).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let directory = own.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let path = directory.isEmpty ? workerName : "\(directory)/\(workerName)"
        let shim = ChromiumResources.jsString("/\(workerShim)")
        let source: String
        if let own {
            let script = ChromiumResources.jsString("/\(own)")
            source = background["type"] as? String == "module" ? "import \(shim);\nimport \(script);\n" : "importScripts(\(shim), \(script));\n"
        } else {
            source = "importScripts(\(shim));\n"
        }
        background["service_worker"] = path
        m["background"] = background
        if var sets = m["content_scripts"] as? [[String: Any]] {
            for i in sets.indices where (sets[i]["world"] as? String ?? "ISOLATED") != "MAIN" {
                if let js = sets[i]["js"] as? [String], !js.isEmpty { sets[i]["js"] = [contentShim] + js }
            }
            m["content_scripts"] = sets
        }
        return (m, (path, source))
    }

    /// An extension page with Cosmos's script first: right after `<head>`, or what stands in for it.
    static func withPageShim(_ html: String) -> String {
        let tag = "<script src=\"/\(pageShim)\"></script>"
        for pattern in ["<head\\b[^>]*>", "<html\\b[^>]*>", "<!doctype[^>]*>"] {
            if let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return html.replacingCharacters(in: r.upperBound..<r.upperBound, with: tag)
            }
        }
        return tag + html
    }
}
