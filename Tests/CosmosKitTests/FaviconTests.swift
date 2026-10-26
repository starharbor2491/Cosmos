import AppKit
import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// Solid-colour PNGs standing in for site logos.
enum TestIcon {
    /// `padded` leaves a transparent border around the coloured square, like a logo on a transparent background.
    static func png(side: Int, color: NSColor, padded: Bool = false) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
        color.setFill()
        let inset = padded ? CGFloat(side) * 0.25 : 0
        NSRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

@MainActor
@Suite struct FaviconTests {
    private func makeStore(offline: Bool = false, directory: URL? = nil) -> (FaviconStore, URL) {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-favicons-\(UUID().uuidString)", isDirectory: true)
        return (FaviconStore(directory: dir, offline: offline), dir)
    }

    private func waitForIcon(_ store: FaviconStore, host: String = "127.0.0.1", seconds: Double = 4) async -> NSImage? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let image = store.image(forHost: host) { return image }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    private func html(_ body: String) -> SiteServer.Route { .init(type: "text/html", body: Data(body.utf8)) }
    private func image(_ data: Data) -> SiteServer.Route { .init(type: "image/png", body: data) }

    @Test func iconLinksAreReadFromTheHeadAndResolvedAgainstThePage() {
        let page = """
        <html><head>
        <link rel="stylesheet" href="/a.css">
        <link rel="shortcut icon" href="/favicon-32.png" sizes="32x32">
        <LINK REL='apple-touch-icon' HREF='https://cdn.example.com/touch.png' sizes="180x180">
        <link href="logo.svg" type="image/svg+xml" rel="icon">
        <link rel="mask-icon" href="/mask.svg">
        </head><body><link rel="icon" href="/after-the-head.png"></body></html>
        """
        let found = FaviconStore.iconLinks(inHTML: page, base: URL(string: "https://example.com/app/index.html")!)
        #expect(found.map(\.href.absoluteString) == [
            "https://example.com/favicon-32.png", "https://cdn.example.com/touch.png",
            "https://example.com/app/logo.svg", "https://example.com/mask.svg",
        ])
        #expect(found.first?.sizes == "32x32")
        #expect(found[1].rel == "apple-touch-icon")
    }

    @Test func theLogoIsFetchedFromTheSiteItselfAndOnlyTheOriginIsAsked() async throws {
        let server = try await SiteServer(routes: [
            "/": html("<html><head><link rel=\"icon\" href=\"/brand/logo.png\"></head></html>"),
            "/brand/logo.png": image(TestIcon.png(side: 64, color: .systemRed)),
        ])
        let (store, _) = makeStore()
        store.ensure(url: URL(string: "http://127.0.0.1:\(server.port)/account/settings?token=secret#frag"))
        let icon = await waitForIcon(store)
        #expect(icon != nil)
        #expect(server.requests.contains("/brand/logo.png"))
        #expect(server.requests.allSatisfy { !$0.contains("secret") && !$0.contains("account") }, "asked for: \(server.requests)")
    }

    @Test func aSiteWithoutIconLinksFallsBackToFaviconIco() async throws {
        let server = try await SiteServer(routes: [
            "/": html("<html><head><title>No icons here</title></head></html>"),
            "/favicon.ico": image(TestIcon.png(side: 32, color: .systemBlue)),
        ])
        let (store, _) = makeStore()
        store.ensure(url: URL(string: "http://127.0.0.1:\(server.port)/"))
        #expect(await waitForIcon(store) != nil)
    }

    @Test func offlineStoresNeverTouchTheNetwork() async throws {
        let server = try await SiteServer(routes: ["/": html("<link rel=icon href=/l.png>"), "/l.png": image(TestIcon.png(side: 64, color: .green))])
        let (store, _) = makeStore(offline: true)
        store.ensure(url: URL(string: "http://127.0.0.1:\(server.port)/"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.requests.isEmpty)
        #expect(store.image(forHost: "127.0.0.1") == nil)
    }

    @Test func aCachedLogoIsNotFetchedAgainAndSurvivesARestart() async throws {
        let server = try await SiteServer(routes: ["/": html("<link rel=icon href=/l.png>"), "/l.png": image(TestIcon.png(side: 64, color: .orange))])
        let (store, dir) = makeStore()
        let url = URL(string: "http://127.0.0.1:\(server.port)/")
        store.ensure(url: url)
        #expect(await waitForIcon(store) != nil)
        let first = server.requests.count
        store.ensure(url: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == first)

        let (reopened, _) = makeStore(directory: dir)
        #expect(reopened.image(forHost: "127.0.0.1") != nil)
        reopened.ensure(url: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == first, "a fresh file on disk should not trigger a download")
    }

    @Test func aSiteWithNoLogoIsNotHammered() async throws {
        let server = try await SiteServer(routes: ["/": html("<html></html>")])
        let (store, _) = makeStore()
        let url = URL(string: "http://127.0.0.1:\(server.port)/")
        store.ensure(url: url)
        try await Task.sleep(for: .milliseconds(700))
        let first = server.requests.count
        #expect(first > 0)
        #expect(store.image(forHost: "127.0.0.1") == nil)
        store.ensure(url: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == first)
    }

    @Test func hugeLogosAreShrunkAndTinyOnesRejected() throws {
        let big = try #require(FaviconStore.normalizedPNG(from: TestIcon.png(side: 512, color: .purple)))
        let bigRep = try #require(NSBitmapImageRep(data: big))
        #expect(bigRep.pixelsWide == 128)
        let ok = try #require(FaviconStore.normalizedPNG(from: TestIcon.png(side: 48, color: .purple)))
        #expect(NSBitmapImageRep(data: ok)?.pixelsWide == 48)
        #expect(FaviconStore.normalizedPNG(from: TestIcon.png(side: 4, color: .purple)) == nil)
        #expect(FaviconStore.normalizedPNG(from: Data("not an image, just a long enough string of text to pass the size check".utf8)) == nil)
    }

    /// A 1-bit grey PNG of `side` x `side` pixels: a few hundred KB on the wire, a gigabyte once decoded.
    static func decompressionBomb(side: Int) -> Data {
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 } }
            return ~c
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8) + body
            return withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init) + t + withUnsafeBytes(of: crc(t).bigEndian, Array.init)
        }
        let raw = Data(count: side * (1 + (side + 7) / 8))
        let deflated = try! (raw as NSData).compressed(using: .zlib) as Data
        // zlib wrapper: header, the raw deflate stream, then Adler-32 (of all-zero bytes: A = 1, B = length mod 65521).
        let adler = (UInt32(raw.count % 65521) << 16) | 1
        let idat: [UInt8] = [0x78, 0xDA] + Array(deflated) + withUnsafeBytes(of: adler.bigEndian, Array.init)
        let header = withUnsafeBytes(of: UInt32(side).bigEndian, Array.init) + withUnsafeBytes(of: UInt32(side).bigEndian, Array.init) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    /// Every page we visit is parsed, so a hostile one must not be able to pin a core with a wall of unclosed tags.
    @Test func aPageOfUnclosedLinkTagsIsParsedQuickly() {
        let base = URL(string: "https://example.com/")!
        let start = Date()
        #expect(FaviconStore.iconLinks(inHTML: String(repeating: "<link ", count: 40_000), base: base).isEmpty)
        #expect(FaviconStore.iconLinks(inHTML: "<link rel=icon href=/a.png>" + String(repeating: "<link ", count: 40_000), base: base).count == 1)
        #expect(Date().timeIntervalSince(start) < 2, "took \(Date().timeIntervalSince(start)) s")
    }

    /// The tag's own attributes were matched by a pattern that retried from every letter of a long word.
    @Test func oneHugeLinkTagIsParsedQuickly() {
        let base = URL(string: "https://example.com/")!
        let html = "<link rel=icon href=/a.png><link " + String(repeating: "a", count: 16_000) + ">"
        let start = Date()
        #expect(FaviconStore.iconLinks(inHTML: html, base: base).count == 1)
        #expect(Date().timeIntervalSince(start) < 1, "took \(Date().timeIntervalSince(start)) s")
    }

    @Test func aLongDataAddressIconIsStillFound() {
        let base = URL(string: "https://example.com/")!
        let data = "data:image/png;base64," + String(repeating: "QUJD", count: 25_000)
        let found = FaviconStore.iconLinks(inHTML: "<link rel='shortcut icon' type=image/png href=\"\(data)\">", base: base)
        #expect(found.count == 1)
        #expect(found.first?.href.absoluteString.count == data.count)
    }

    @Test func attributesAreReadWhateverTheirQuoting() {
        let base = URL(string: "https://example.com/")!
        let html = "<LINK REL = \"icon\" sizes=48x48 href = '/a.png' title=\"x=y\" data-a=\"\" /><link rel=apple-touch-icon href=/b.png>"
        let found = FaviconStore.iconLinks(inHTML: html, base: base)
        #expect(found.map(\.href.path) == ["/a.png", "/b.png"])
        #expect(found.first?.sizes == "48x48")
    }

    /// Incognito must not write the sites it visits anywhere, not even to a folder in the temp directory.
    @Test func anIncognitoWindowLeavesNoFaviconFolderBehind() {
        func incognitoFolders() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("cosmos-incognito") })
        }
        let before = incognitoFolders()
        let store = BrowserStore(directory: nil, incognito: true)
        #expect(incognitoFolders().subtracting(before).isEmpty)
        withExtendedLifetime(store) {}
    }

    @Test func aMemoryOnlyStoreKeepsTheLogoForTheSessionOnly() async throws {
        let server = try await SiteServer(routes: ["/": html("<link rel=icon href=/l.png>"), "/l.png": image(TestIcon.png(side: 64, color: .systemTeal))])
        let store = FaviconStore(directory: nil, offline: false)
        store.ensure(url: URL(string: "http://127.0.0.1:\(server.port)/"))
        #expect(await waitForIcon(store) != nil)
        #expect(FaviconStore(directory: nil, offline: true).image(forHost: "127.0.0.1") == nil)
    }

    @Test func clearingHistoryForgetsTheLogosTheCommandBarLearnedAndTheVisits() throws {
        let rig = Rig()
        let png = TestIcon.png(side: 32, color: .systemOrange)
        let folder = rig.dir.appendingPathComponent("Favicons", isDirectory: true)
        try png.write(to: folder.appendingPathComponent("example.com.png"))
        rig.store.history.record(url: URL(string: "https://example.com/")!, title: "Example")
        rig.store.learned.record(query: "exa", candidateID: "tab:1")
        #expect(rig.store.favicons.image(forHost: "example.com") != nil)

        rig.store.clearHistory()

        #expect(rig.store.history.count() == 0)
        #expect(rig.store.learned.picks.isEmpty)
        #expect(rig.store.favicons.image(forHost: "example.com") == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    }

    @Test func aLogoEmbeddedInThePageIsDecoded() async throws {
        let embedded = "data:image/png;base64," + TestIcon.png(side: 48, color: .systemPink).base64EncodedString()
        let server = try await SiteServer(routes: ["/": html("<html><head><link rel=\"icon\" href=\"\(embedded)\"></head></html>")])
        let (store, _) = makeStore()
        store.ensure(url: URL(string: "http://127.0.0.1:\(server.port)/"))
        #expect(await waitForIcon(store) != nil)
    }

    @Test func aDownloadStopsAtItsLimit() async throws {
        let server = try await SiteServer(routes: ["/small": image(Data(repeating: 7, count: 500)), "/big": image(Data(repeating: 7, count: 5_000))])
        let session = URLSession(configuration: .ephemeral)
        let base = "http://127.0.0.1:\(server.port)"
        let small = await FaviconStore.download(URL(string: base + "/small")!, limit: 1_000, session: session)
        let big = await FaviconStore.download(URL(string: base + "/big")!, limit: 1_000, session: session)
        let missing = await FaviconStore.download(URL(string: base + "/nothing")!, limit: 1_000, session: session)
        #expect(small?.count == 500)
        #expect(big == nil)
        #expect(missing == nil)
    }

    @Test func aSmallFileThatUnpacksToAHugeImageIsRefused() {
        let bomb = Self.decompressionBomb(side: 30_000)
        #expect(bomb.count < 2_000_000)
        let start = Date()
        #expect(FaviconStore.normalizedPNG(from: bomb) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func vectorLogosAreRasterized() throws {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><circle cx="12" cy="12" r="10" fill="#e00"/></svg>
        """.utf8)
        let png = try #require(FaviconStore.normalizedPNG(from: svg))
        #expect((NSBitmapImageRep(data: png)?.pixelsWide ?? 0) >= 24)
    }

    @Test func darkOrWhiteLogosOnTransparencyGetABackingTheyCanBeSeenOn() throws {
        func backing(_ data: Data) throws -> FaviconStore.Backing { FaviconStore.backing(of: try #require(NSImage(data: data))) }
        #expect(try backing(TestIcon.png(side: 64, color: .black, padded: true)) == .light)
        #expect(try backing(TestIcon.png(side: 64, color: .white, padded: true)) == .dark)
        #expect(try backing(TestIcon.png(side: 64, color: .systemRed, padded: true)) == .plain)
        #expect(try backing(TestIcon.png(side: 64, color: .black, padded: false)) == .plain, "an opaque square carries its own background")
    }
}
