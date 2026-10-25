import CosmosCore
import CryptoKit
import Foundation

// MARK: Fetching

public enum FilterListFetchResult: Sendable {
    case notModified
    case downloaded(Data, etag: String?, lastModified: String?)
}

/// Downloads a list, honouring `ETag` / `Last-Modified` validators. Injectable so tests never touch the network.
public protocol FilterListFetching: Sendable {
    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FilterListFetchResult
}

public enum FilterListError: Error, Equatable {
    case httpStatus(Int)
    case notAFilterList
    case tooLarge
}

/// `URLSession`-based fetcher. `file://` URLs are read directly (custom lists, tests).
public struct URLSessionFilterListFetcher: FilterListFetching {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FilterListFetchResult {
        if url.isFileURL { return .downloaded(try Data(contentsOf: url), etag: nil, lastModified: nil) }
        var request = URLRequest(url: url)
        request.setValue("text/plain, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Cosmos (content blocker list updater)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .downloaded(data, etag: nil, lastModified: nil) }
        switch http.statusCode {
        case 304: return .notModified
        case 200..<300:
            return .downloaded(data, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        default: throw FilterListError.httpStatus(http.statusCode)
        }
    }
}

// MARK: Persistent state

struct BlockingSettings: Codable, Equatable {
    var enabledListIDs: [String]
    var customLists: [FilterListInfo] = []
}

struct ListMeta: Codable, Equatable {
    var url: String
    var etag: String?
    var lastModified: String?
    var lastChecked: Date?
    var bytes: Int?
}

struct CompiledManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var name: String
        var file: String
        var ruleCount: Int
        var kind: CompiledRuleList.Kind
    }
    var key: String
    var lists: [Entry]
    var report: CompileReport
    var compiledAt: Date
}

public struct FilterListStatus: Sendable, Identifiable, Equatable {
    public var info: FilterListInfo
    public var isEnabled: Bool
    /// Last successful download or "not modified" answer.
    public var lastChecked: Date?
    /// Rules in the compiled lists for this source, if compiled.
    public var ruleCount: Int?
    public var report: CompileReport?
    public var id: String { info.id }
}

// MARK: Manager

/// Keeps filter lists downloaded, compiled and cached.
///
/// Files live in `CosmosPaths.dataDirectory/FilterLists/`: `<id>.txt` (downloaded text), `<id>.meta.json`
/// (validators and check time) and `compiled/` (the JSON handed to WebKit, keyed by the SHA-256 of the list text plus
/// `ContentBlocker.compilerVersion`, so an unchanged list is never recompiled). Which lists are enabled is stored in
/// `blocking.json`. Offline, the cached copy is used; with no copy at all, the bundled fallback list stands in.
public actor FilterListManager {
    /// Identifier of the bundled fallback list inside the results.
    public static let fallbackListID = "cosmos-fallback"
    static let maxDownloadBytes = 64 * 1024 * 1024

    private let directory: URL
    private let compiledDirectory: URL
    private let settingsStore: JSONFileStore<BlockingSettings>
    private let catalog: [FilterListInfo]
    private let fetcher: any FilterListFetching
    private let freshness: TimeInterval
    private let now: @Sendable () -> Date
    private let fm = FileManager.default
    private var settings: BlockingSettings

    public init(
        directory: URL = CosmosPaths.dataDirectory.appendingPathComponent("FilterLists", isDirectory: true),
        settingsURL: URL = CosmosPaths.file("blocking.json"),
        catalog: [FilterListInfo] = FilterListCatalog.all,
        fetcher: any FilterListFetching = URLSessionFilterListFetcher(),
        freshness: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.compiledDirectory = directory.appendingPathComponent("compiled", isDirectory: true)
        self.settingsStore = JSONFileStore<BlockingSettings>(url: settingsURL)
        self.catalog = catalog
        self.fetcher = fetcher
        self.freshness = freshness
        self.now = now
        let loaded = (try? settingsStore.load()) ?? nil
        self.settings = loaded ?? BlockingSettings(enabledListIDs: catalog.filter(\.defaultEnabled).map(\.id))
    }

    // MARK: Settings

    /// Catalog lists followed by the user's custom lists.
    public func availableLists() -> [FilterListInfo] { catalog + settings.customLists }

    public func enabledListIDs() -> [String] { availableLists().map(\.id).filter(settings.enabledListIDs.contains) }

    public func isEnabled(_ id: String) -> Bool { settings.enabledListIDs.contains(id) }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard availableLists().contains(where: { $0.id == id }) else { return }
        var ids = settings.enabledListIDs.filter { $0 != id }
        if enabled { ids.append(id) }
        settings.enabledListIDs = ids
        try settingsStore.save(settings)
    }

    /// Adds (and enables) a list from any `http(s)://` or `file://` URL in Adblock Plus / uBlock syntax or hosts format.
    @discardableResult
    public func addCustomList(name: String, url: URL) throws -> FilterListInfo {
        let id = "custom-" + Self.hex(SHA256.hash(data: Data(url.absoluteString.utf8))).prefix(10)
        let info = FilterListInfo(id: String(id), name: name, url: url, category: .custom, defaultEnabled: false, summary: url.absoluteString, license: "", isCustom: true)
        settings.customLists.removeAll { $0.id == info.id }
        settings.customLists.append(info)
        settings.enabledListIDs.removeAll { $0 == info.id }
        settings.enabledListIDs.append(info.id)
        try settingsStore.save(settings)
        return info
    }

    public func removeCustomList(id: String) throws {
        settings.customLists.removeAll { $0.id == id }
        settings.enabledListIDs.removeAll { $0 == id }
        try settingsStore.save(settings)
        for url in [textURL(id), metaURL(id), manifestURL(id)] { try? fm.removeItem(at: url) }
    }

    public func status() -> [FilterListStatus] {
        availableLists().map { info in
            let manifest = readManifest(info.id)
            return FilterListStatus(
                info: info,
                isEnabled: isEnabled(info.id),
                lastChecked: readMeta(info.id)?.lastChecked,
                ruleCount: manifest.map { $0.lists.reduce(0) { $0 + $1.ruleCount } },
                report: manifest?.report)
        }
    }

    // MARK: Refresh

    /// Brings every enabled list up to date and returns the compiled rule lists to install, in catalog order.
    /// Lists younger than 24 h are not re-checked unless `force`. Never throws: network trouble falls back to the
    /// cached copy and, failing that, to the bundled fallback list.
    public func refresh(force: Bool = false) async -> [CompiledRuleList] {
        let infos = enabledInfos()
        guard !infos.isEmpty else { return [] }

        var texts: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for info in infos {
                group.addTask { (info.id, await self.updateSource(info, force: force)) }
            }
            for await (id, text) in group { if let text { texts[id] = text } }
        }

        var sources: [(id: String, text: String)] = infos.compactMap { info in texts[info.id].map { (info.id, $0) } }
        if sources.count < infos.count { sources.append((Self.fallbackListID, ContentBlocker.fallbackListText)) }
        return await compiledLists(for: sources)
    }

    /// What is on disk right now, without touching the network. Compiles from the cached text when the compiled
    /// cache is missing or outdated; uses the bundled fallback when nothing has been downloaded yet.
    public func cachedRuleLists() -> [CompiledRuleList] {
        let infos = enabledInfos()
        guard !infos.isEmpty else { return [] }
        var result: [CompiledRuleList] = []
        var missing = false
        for info in infos {
            guard let text = readText(info.id) else { missing = true; continue }
            result.append(contentsOf: cachedOrCompile(id: info.id, text: text))
        }
        if missing { result.append(contentsOf: cachedOrCompile(id: Self.fallbackListID, text: ContentBlocker.fallbackListText)) }
        return result
    }

    // MARK: Downloading

    private func enabledInfos() -> [FilterListInfo] {
        let enabled = Set(settings.enabledListIDs)
        return availableLists().filter { enabled.contains($0.id) }
    }

    /// Returns the list text to use (fresh, revalidated or stale-but-cached), or nil when there is none.
    private func updateSource(_ info: FilterListInfo, force: Bool) async -> String? {
        let cached = readText(info.id)
        var meta = readMeta(info.id) ?? ListMeta(url: info.url.absoluteString)
        if meta.url != info.url.absoluteString { meta = ListMeta(url: info.url.absoluteString) }

        if let cached, !force, let checked = meta.lastChecked, now().timeIntervalSince(checked) < freshness { return cached }

        do {
            let result = try await fetcher.fetch(info.url, etag: cached == nil ? nil : meta.etag, lastModified: cached == nil ? nil : meta.lastModified)
            switch result {
            case .notModified:
                guard let cached else { return nil }
                meta.lastChecked = now()
                writeMeta(meta, id: info.id)
                return cached
            case .downloaded(let data, let etag, let lastModified):
                let text = try Self.validatedText(data)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: textURL(info.id), options: .atomic)
                meta.etag = etag
                meta.lastModified = lastModified
                meta.lastChecked = now()
                meta.bytes = data.count
                writeMeta(meta, id: info.id)
                return text
            }
        } catch {
            return cached
        }
    }

    static func validatedText(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw FilterListError.notAFilterList }
        guard data.count <= maxDownloadBytes else { throw FilterListError.tooLarge }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let head = text.prefix(1024).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") { throw FilterListError.notAFilterList }
        return text
    }

    // MARK: Compiling and the compiled cache

    static func cacheKey(for text: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("cosmos-blocking-v\(ContentBlocker.compilerVersion)\n".utf8))
        hasher.update(data: Data(text.utf8))
        return hex(hasher.finalize())
    }

    private func compiledLists(for sources: [(id: String, text: String)]) async -> [CompiledRuleList] {
        var results: [[CompiledRuleList]?] = Array(repeating: nil, count: sources.count)
        var keys: [String] = []
        var pending: [(index: Int, id: String, text: String)] = []
        for (i, source) in sources.enumerated() {
            let key = Self.cacheKey(for: source.text)
            keys.append(key)
            if let cached = loadCompiled(id: source.id, key: key) { results[i] = cached }
            else { pending.append((i, source.id, source.text)) }
        }
        if !pending.isEmpty {
            let compiled = await withTaskGroup(of: (Int, [CompiledRuleList], CompileReport).self) { group -> [(Int, [CompiledRuleList], CompileReport)] in
                for p in pending {
                    group.addTask(priority: .utility) {
                        let r = ContentBlocker.compile(name: p.id, text: p.text)
                        return (p.index, r.lists, r.report)
                    }
                }
                var out: [(Int, [CompiledRuleList], CompileReport)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (index, lists, report) in compiled {
                results[index] = lists
                storeCompiled(id: sources[index].id, key: keys[index], lists: lists, report: report)
            }
        }
        return results.compactMap { $0 }.flatMap { $0 }
    }

    private func cachedOrCompile(id: String, text: String) -> [CompiledRuleList] {
        let key = Self.cacheKey(for: text)
        if let cached = loadCompiled(id: id, key: key) { return cached }
        let r = ContentBlocker.compile(name: id, text: text)
        storeCompiled(id: id, key: key, lists: r.lists, report: r.report)
        return r.lists
    }

    private func loadCompiled(id: String, key: String) -> [CompiledRuleList]? {
        guard let manifest = readManifest(id), manifest.key == key else { return nil }
        var lists: [CompiledRuleList] = []
        for entry in manifest.lists {
            guard let data = try? Data(contentsOf: compiledDirectory.appendingPathComponent(entry.file)) else { return nil }
            lists.append(CompiledRuleList(name: entry.name, json: String(decoding: data, as: UTF8.self), ruleCount: entry.ruleCount, kind: entry.kind))
        }
        return lists
    }

    private func storeCompiled(id: String, key: String, lists: [CompiledRuleList], report: CompileReport) {
        do {
            try fm.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)
            let stem = String(key.prefix(12))
            var entries: [CompiledManifest.Entry] = []
            for list in lists {
                let file = "\(list.name).\(stem).json"
                try Data(list.json.utf8).write(to: compiledDirectory.appendingPathComponent(file), options: .atomic)
                entries.append(.init(name: list.name, file: file, ruleCount: list.ruleCount, kind: list.kind))
            }
            let manifest = CompiledManifest(key: key, lists: entries, report: report, compiledAt: now())
            try JSONEncoder.cosmos.encode(manifest).write(to: manifestURL(id), options: .atomic)
            // Drop compiled files of earlier versions of this list.
            let keep = Set(entries.map(\.file))
            for url in (try? fm.contentsOfDirectory(at: compiledDirectory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(id + ".") && url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".manifest.json") && !keep.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        } catch {
            // The cache is an optimisation; failing to write it only costs a recompile next time.
        }
    }

    // MARK: Files

    private func textURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).txt") }
    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).meta.json") }
    private func manifestURL(_ id: String) -> URL { compiledDirectory.appendingPathComponent("\(id).manifest.json") }

    private func readText(_ id: String) -> String? {
        guard let data = try? Data(contentsOf: textURL(id)), let text = try? Self.validatedText(data) else { return nil }
        return text
    }

    private func readMeta(_ id: String) -> ListMeta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? JSONDecoder.cosmos.decode(ListMeta.self, from: data)
    }

    private func writeMeta(_ meta: ListMeta, id: String) {
        guard let data = try? JSONEncoder.cosmos.encode(meta) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: metaURL(id), options: .atomic)
    }

    private func readManifest(_ id: String) -> CompiledManifest? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? JSONDecoder.cosmos.decode(CompiledManifest.self, from: data)
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
