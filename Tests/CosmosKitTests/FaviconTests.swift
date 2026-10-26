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
