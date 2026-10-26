import AppKit
import CosmosCore

/// Site logos, cached per host in memory and on disk. A page reports its icon links when it loads; for tabs that are
/// asleep (pinned, restored, imported) the store asks the site itself. Icons are always fetched straight from the site,
/// never through a favicon service, and the request names only the site's origin, never the page you were on.
/// With no directory the store keeps icons in memory only (incognito): nothing about the sites visited reaches the disk.
@MainActor
@Observable
public final class FaviconStore {
    public struct Candidate: Sendable {
        public var href: URL
        public var sizes: String
        public var rel: String
        public init(href: URL, sizes: String = "", rel: String = "icon") { self.href = href; self.sizes = sizes; self.rel = rel }
    }

    /// What a logo needs behind it: black-on-transparent logos vanish on a dark sidebar and white ones on a light tile.
    public enum Backing: Sendable { case plain, light, dark }

    /// Bumped whenever an icon arrives so SwiftUI rows re-read `image(forHost:)`.
    public private(set) var revision = 0

    @ObservationIgnored private var memory: [String: NSImage] = [:]
    @ObservationIgnored private var backings: [String: Backing] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var waiting: [(key: String, origin: URL)] = []
    @ObservationIgnored private var failed: [String: Date] = [:]
    /// Hosts whose logo was confirmed recently (this session), so navigating around a site doesn't re-download it.
    @ObservationIgnored private var checked: [String: Date] = [:]
    /// Bumped by `removeAll`, so a download that was already running when the logos were cleared can be told apart.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let session: URLSession
    /// Set by the app for `--offline` runs; nothing is downloaded while it is true.
    @ObservationIgnored var offline: Bool

    private static let maxParallel = 4
    private static let maxAge: TimeInterval = 14 * 24 * 3600
    /// A logo that has not been downloaded again for this long belongs to a site that is no longer visited.
    nonisolated private static let pruneAge: TimeInterval = 90 * 24 * 3600
    nonisolated private static let maxSide = 128

    /// - Parameter directory: where icons are cached; `nil` keeps them in memory only.
    /// - Parameter offline: never touch the network (demos and automated runs); only icons already on disk are shown.
    public init(directory: URL? = CosmosPaths.dataDirectory.appendingPathComponent("Favicons", isDirectory: true), offline: Bool = false) {
        self.directory = directory
        self.offline = offline
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        // The request timeout restarts whenever a byte arrives, so a server dripping data would hold a slot forever.
        cfg.timeoutIntervalForResource = 15
        cfg.httpCookieStorage = nil
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 Cosmos"]
        session = URLSession(configuration: cfg)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Task.detached(priority: .utility) { Self.prune(directory: directory) }
        }
    }

    /// Deletes cached logos older than `age`, so the folder doesn't keep every site ever visited. A logo that is still
    /// in use is downloaded again well within that time, which renews its date. Returns how many were deleted.
    @discardableResult
    nonisolated static func prune(directory: URL, age: TimeInterval = pruneAge, now: Date = Date()) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for file in files where file.pathExtension == "png" {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    private func key(_ host: String) -> String { host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }

    private func file(for key: String) -> URL? {
        directory?.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    // MARK: Reading

    /// The cached icon for a host, loading it from disk on first use.
    public func image(forHost host: String?) -> NSImage? {
        _ = revision
        guard let host, !host.isEmpty else { return nil }
        let k = key(host)
        if let img = memory[k] { return img }
        if let file = file(for: k), let img = NSImage(contentsOf: file) { remember(img, key: k); return img }
        return nil
    }

    public func has(host: String) -> Bool { image(forHost: host) != nil }

    public func backing(forHost host: String?) -> Backing {
        _ = revision
        guard let host, !host.isEmpty else { return .plain }
        return backings[key(host)] ?? .plain
    }

    private func remember(_ image: NSImage, key: String) {
        memory[key] = image
        backings[key] = Self.backing(of: image)
    }

    // MARK: Fetching

    /// Makes sure a logo is on its way for the site of `url` (a sleeping or restored tab has not loaded its page, so
    /// nothing has reported one). Cheap when the logo is cached; at most a few downloads run at once.
    func ensure(url: URL?) {
        guard !offline, let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }
        let k = key(host)
        if inFlight.contains(k) || waiting.contains(where: { $0.key == k }) { return }
        if let when = failed[k], Date().timeIntervalSince(when) < 600 { return }
        if let when = checked[k], Date().timeIntervalSince(when) < 3600 { return }
        if hasFreshFile(k) { checked[k] = Date(); return }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        guard let origin = parts.url else { return }
        waiting.append((k, origin))
        pump()
    }

    private func hasFreshFile(_ k: String) -> Bool {
        guard let file = file(for: k),
              let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < Self.maxAge
    }

    private func pump() {
        while inFlight.count < Self.maxParallel, !waiting.isEmpty {
            let next = waiting.removeFirst()
            inFlight.insert(next.key)
            let started = generation
            Task { [session] in
                let data = await Self.discover(origin: next.origin, session: session)
                self.finish(key: next.key, data: data, generation: started)
                self.pump()
            }
        }
    }

    /// The page you are looking at reported its icon links: use the best one and keep it.
    func update(host: String, candidates: [Candidate], pageURL: URL) {
        guard !offline else { return }
        let k = key(host)
        if let when = failed[k], Date().timeIntervalSince(when) < 600 { return }
        if let when = checked[k], Date().timeIntervalSince(when) < 3600, memory[k] != nil { return }
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)
        let started = generation
        let list = candidates + Self.defaults(for: pageURL)
        Task { [session] in
            let data = await Self.bestIcon(from: list, session: session)
            self.finish(key: k, data: data, generation: started)
            self.pump()
        }
    }

    func finish(key k: String, data: Data?, generation started: Int) {
        // Cleared while this download ran: what it found belongs to a history that no longer exists.
        guard started == generation else { return }
        inFlight.remove(k)
        if let data, let image = NSImage(data: data) {
            remember(image, key: k)
            if let file = file(for: k) { try? data.write(to: file, options: .atomic) }
            checked[k] = Date()
            failed[k] = nil
            revision += 1
        } else {
            failed[k] = Date()
        }
    }

    /// Reads the site's home page for icon links, then falls back to the well-known paths.
    nonisolated private static func discover(origin: URL, session: URLSession) async -> Data? {
        var base = origin
        var candidates: [Candidate] = []
        if let page = await fetchHead(origin, session: session) {
            base = page.url
            candidates = iconLinks(inHTML: page.html, base: page.url)
        }
        return await bestIcon(from: candidates + defaults(for: base), session: session)
    }

    nonisolated private static func defaults(for page: URL) -> [Candidate] {
        ["/apple-touch-icon.png", "/favicon.ico"].compactMap { path in
            URL(string: path, relativeTo: page)?.absoluteURL
        }.map { Candidate(href: $0, sizes: "", rel: $0.lastPathComponent.hasPrefix("apple") ? "apple-touch-icon" : "icon") }
    }

    /// The start of the page, up to the end of its head (or 256 KB).
    nonisolated private static func fetchHead(_ url: URL, session: URLSession) async -> (html: String, url: URL)? {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 262_144 { break }
                if data.count % 16_384 == 0,
                   String(decoding: data.suffix(16_400), as: UTF8.self).range(of: "</head", options: .caseInsensitive) != nil { break }
            }
        } catch {}
        return (String(decoding: data, as: UTF8.self), response.url ?? url)
    }

    nonisolated private static func bestIcon(from candidates: [Candidate], session: URLSession) async -> Data? {
        var seen = Set<URL>()
        let ranked = candidates.filter { seen.insert($0.href).inserted }.sorted { score($0) > score($1) }
        for c in ranked.prefix(3) {
            guard let data = await download(c.href, limit: maxIconBytes, session: session) else { continue }
            if let png = normalizedPNG(from: data) { return png }
        }
        return nil
    }

    nonisolated static let maxIconBytes = 2_000_000

    /// The body of `url`, or nil when the request fails or the body is bigger than `limit`. Stops reading at the limit
    /// instead of buffering a response nobody can use.
    nonisolated static func download(_ url: URL, limit: Int, session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        if response.expectedContentLength > Int64(limit) { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return data
    }

    /// Prefers ~64 px icons: crisp in the sidebar on retina screens without being huge.
    nonisolated private static func score(_ c: Candidate) -> Double {
        var s = 0.0
        let side = c.sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Double($0) } }.max()
        if let side { s += 100 - abs(side - 64) * 0.6 } else if c.href.pathExtension.lowercased() == "svg" { s += 70 } else { s += 40 }
        if c.rel.contains("apple-touch") { s += 5 }
        if c.rel.contains("mask-icon") { s -= 60 }
        if c.href.lastPathComponent == "favicon.ico" { s -= 10 }
        return s
    }

    // MARK: Parsing and decoding

    /// Icon links (`rel` containing "icon") in the head of `html`, in page order, resolved against `base`.
    nonisolated static func iconLinks(inHTML html: String, base: URL) -> [Candidate] {
        var head = html
        if let end = html.range(of: "</head", options: .caseInsensitive) { head = String(html[..<end.lowerBound]) }
        var out: [Candidate] = []
        for attrs in linkTags(in: head) {
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attrs["href"]?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { continue }
            out.append(Candidate(href: url, sizes: attrs["sizes"] ?? "", rel: rel))
        }
        return out
    }

    /// The attributes of every `<link>` tag, names lowercased, in page order. One pass over the bytes: a page is
    /// untrusted, and a pattern that retries from every letter of one very long tag takes seconds on the main actor.
    nonisolated private static func linkTags(in html: String) -> [[String: String]] {
        let b = Array(html.utf8)
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), equals = UInt8(ascii: "=")
        let quotes = [UInt8(ascii: "\""), UInt8(ascii: "'")]
        let word = Array("link".utf8)
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (0x09...0x0D).contains(c) }
        func text(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<to], as: UTF8.self) }

        var tags: [[String: String]] = []
        var i = 0
        scan: while i < b.count {
            guard b[i] == lt else { i += 1; continue }
            i += 1
            // "link" in either case, then something that ends the tag name.
            guard i + 4 < b.count, (0..<4).allSatisfy({ b[i + $0] | 0x20 == word[$0] }),
                  isSpace(b[i + 4]) || b[i + 4] == slash || b[i + 4] == gt else { continue }
            i += 4
            var attrs: [String: String] = [:]
            while true {
                while i < b.count, isSpace(b[i]) || b[i] == slash { i += 1 }
                guard i < b.count else { break scan }
                if b[i] == gt { i += 1; break }
                let nameStart = i
                while i < b.count, !isSpace(b[i]), b[i] != equals, b[i] != gt, b[i] != slash { i += 1 }
                let name = text(nameStart, i).lowercased()
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count else { break scan }
                var value = ""
                if b[i] == equals {
                    i += 1
                    while i < b.count, isSpace(b[i]) { i += 1 }
                    guard i < b.count else { break scan }
                    if quotes.contains(b[i]) {
                        let quote = b[i]
                        let from = i + 1
                        guard let close = b[from...].firstIndex(of: quote) else { break scan }
                        value = text(from, close)
                        i = close + 1
                    } else {
                        let from = i
                        while i < b.count, !isSpace(b[i]), b[i] != gt { i += 1 }
                        value = text(from, i)
                    }
                }
                if !name.isEmpty, attrs[name] == nil { attrs[name] = value }
            }
            tags.append(attrs)
        }
        return tags
    }

    /// Decodes any image the browser can (PNG, ICO, SVG…) into one PNG, at most 128 px on its long side. Anything
    /// under 8 px, or not an image, is rejected.
    nonisolated static func normalizedPNG(from data: Data) -> Data? {
        guard data.count > 40, data.count <= maxIconBytes, let image = NSImage(data: data) else { return nil }
        // An .ico holds several sizes; the largest one decides how sharp the result can be. Vector art has no pixel size.
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        var width = bitmaps.map(\.pixelsWide).max() ?? 0
        var height = bitmaps.map(\.pixelsHigh).max() ?? 0
        if bitmaps.isEmpty {
            let s = image.size
            guard s.width > 0, s.height > 0 else { return nil }
            let k = CGFloat(maxSide) / max(s.width, s.height)
            width = Int((s.width * k).rounded()); height = Int((s.height * k).rounded())
        }
        guard width >= 8, height >= 8 else { return nil }
        // A few hundred KB of PNG can claim a gigapixel canvas; no logo needs more than 16 megapixels.
        guard width * height <= 16_000_000 else { return nil }
        let k = min(1, Double(maxSide) / Double(max(width, height)))
        let outW = max(1, Int((Double(width) * k).rounded())), outH = max(1, Int((Double(height) * k).rounded()))
        guard let rep = bitmap(width: outW, height: outH), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH), from: .zero, operation: .sourceOver, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }

    nonisolated private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    /// Looks at a 16 px copy: a logo that has transparency and is almost all dark (or all white) needs a backing.
    nonisolated static func backing(of image: NSImage) -> Backing {
        let side = 16
        guard let rep = bitmap(width: side, height: side), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return .plain }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var weight = 0.0, luminance = 0.0, clear = 0
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let a = Double(c.alphaComponent)
                if a < 0.2 { clear += 1; continue }
                weight += a
                luminance += a * (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
            }
        }
        guard weight > 0, Double(clear) / Double(side * side) > 0.15 else { return .plain }
        let mean = luminance / weight
        if mean < 0.3 { return .light }
        if mean > 0.85 { return .dark }
        return .plain
    }

    public func removeAll() {
        generation += 1
        inFlight.removeAll()
        waiting.removeAll()
        memory.removeAll()
        backings.removeAll()
        failed.removeAll()
        checked.removeAll()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        revision += 1
    }

    /// A stable accent for a host when it has no icon yet.
    public static func tileColor(for host: String?) -> NSColor {
        let h = host ?? "?"
        var hash: UInt32 = 5381
        for u in h.unicodeScalars { hash = (hash &* 33) &+ u.value }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.55, brightness: 0.85, alpha: 1)
    }
}
