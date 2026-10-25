import AppKit
import CosmosCore

/// Site icons, cached per host in memory and on disk. Pages report their icon links through the agent; we pick the
/// best one, fetch it directly from the site (never through a third-party favicon service) and keep a PNG copy.
@MainActor
@Observable
public final class FaviconStore {
    /// Bumped whenever an icon arrives so SwiftUI rows re-read `image(forHost:)`.
    public private(set) var revision = 0

    @ObservationIgnored private var memory: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession

    public init(directory: URL = CosmosPaths.dataDirectory.appendingPathComponent("Favicons", isDirectory: true)) {
        self.directory = directory
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpCookieStorage = nil
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(_ host: String) -> String { host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// The cached icon for a host, loading it from disk on first use.
    public func image(forHost host: String?) -> NSImage? {
        _ = revision
        guard let host, !host.isEmpty else { return nil }
        let k = key(host)
        if let img = memory[k] { return img }
        if let img = NSImage(contentsOf: file(for: k)) { memory[k] = img; return img }
        return nil
    }

    public func has(host: String) -> Bool { image(forHost: host) != nil }

    /// Picks the best icon among `candidates` (href + sizes) and stores it for `host`.
    func update(host: String, candidates: [(href: URL, sizes: String, rel: String)], pageURL: URL) {
        let k = key(host)
        if let when = failed[k], Date().timeIntervalSince(when) < 600 { return }
        guard !inFlight.contains(k) else { return }
        var list = candidates
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { list.append((fallback, "", "icon")) }
        let ranked = list.sorted { score($0) > score($1) }
        inFlight.insert(k)
        Task { [session] in
            var stored: NSImage?
            for c in ranked.prefix(3) {
                guard let (data, resp) = try? await session.data(from: c.href),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      data.count > 40, let img = NSImage(data: data), img.size.width >= 8 else { continue }
                stored = img
                break
            }
            await MainActor.run {
                self.inFlight.remove(k)
                if let img = stored {
                    self.memory[k] = img
                    self.persist(img, key: k)
                    self.revision += 1
                } else {
                    self.failed[k] = Date()
                }
            }
        }
    }

    /// Prefers ~64 px icons: crisp in the sidebar on retina screens without being huge.
    private func score(_ c: (href: URL, sizes: String, rel: String)) -> Double {
        var s = 0.0
        let side = c.sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Double($0) } }.max()
        if let side { s += 100 - abs(side - 64) * 0.6 } else if c.href.pathExtension.lowercased() == "svg" { s += 70 } else { s += 40 }
        if c.rel.contains("apple-touch") { s += 5 }
        if c.rel.contains("mask-icon") { s -= 60 }
        if c.href.lastPathComponent == "favicon.ico" { s -= 10 }
        return s
    }

    private func persist(_ image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file(for: key), options: .atomic)
    }

    public func removeAll() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revision += 1
    }

    /// A stable accent for a host when it has no icon: the letter tile colour.
    public static func tileColor(for host: String?) -> NSColor {
        let h = host ?? "?"
        var hash: UInt32 = 5381
        for u in h.unicodeScalars { hash = (hash &* 33) &+ u.value }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.55, brightness: 0.85, alpha: 1)
    }
}
