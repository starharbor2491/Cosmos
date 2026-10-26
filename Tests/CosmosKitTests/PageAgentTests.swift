import AppKit
import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

/// The script Cosmos puts in every page, run in a real web view.
@MainActor
@Suite struct PageAgentTests {
    private func html(_ body: String) -> SiteServer.Route { .init(type: "text/html", body: Data(body.utf8)) }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// A panel page on `page`: its runtime comes from the real profile environment, so it carries the real agent.
    private func panel(_ server: SiteServer, path: String = "/") async throws -> (MenuBarSession, TabRuntime, Rig) {
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "http://127.0.0.1:\(server.port)\(path)"
        rig.store.settings.menuBar.rememberPage = false
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        try await waitFor { runtime.url?.host == "127.0.0.1" && !runtime.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        return (session, runtime, rig)
    }

    private func rightClick(_ selector: String, in runtime: TabRuntime) async throws {
        _ = try await runtime.webView.evaluateJavaScript("document.querySelector('\(selector)').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true, clientX: 20, clientY: 20}))")
    }

    @Test func aLinkInsideAnSVGIsALinkToo() async throws {
        let server = try await SiteServer(routes: ["/": html("<body><a href='/html'><span id='h'>html link</span></a><svg width='100' height='100'><a href='/svg'><rect id='r' width='100' height='100'/></a></svg></body>")])
        let (session, runtime, _) = try await panel(server)

        try await rightClick("#h", in: runtime)
        try await waitFor { runtime.context.link != nil }
        #expect(runtime.context.link?.path == "/html")

        try await rightClick("#r", in: runtime)
        try await waitFor { runtime.context.link?.path == "/svg" }
        #expect(runtime.context.link?.path == "/svg", "an SVG <a> is a link, so the ring offers link actions")
        session.teardown()
    }

    @Test func whatWasUnderThePointerIsForgottenWhenThePageChanges() async throws {
        let server = try await SiteServer(routes: ["/": html("<body><a id='a' href='/x'>link</a></body>"), "/two": html("<p>two</p>")])
        let (session, runtime, _) = try await panel(server)
        try await rightClick("#a", in: runtime)
        try await waitFor { runtime.context.link != nil }
        #expect(runtime.context.link != nil)

        runtime.load(URL(string: "http://127.0.0.1:\(server.port)/two")!)
        try await waitFor { runtime.url?.path == "/two" && runtime.context.link == nil }
        #expect(runtime.url?.path == "/two")
        #expect(runtime.context.link == nil)
        session.teardown()
    }

    @Test func aSiteThatUsesEscapeForItsOwnModalKeepsIt() async throws {
        let server = try await SiteServer(routes: [
            "/mine": html("<body><script>document.addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });</script></body>"),
            "/plain": html("<body>nothing listens here</body>"),
        ])
        let escape = "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true}))"

        let (handled, handledRuntime, _) = try await panel(server, path: "/mine")
        var hidden = 0
        handled.onHide = { hidden += 1 }
        _ = try await handledRuntime.webView.evaluateJavaScript(escape)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hidden == 0, "the page handled Escape itself")
        handled.teardown()

        let (plain, plainRuntime, _) = try await panel(server, path: "/plain")
        var plainHidden = 0
        plain.onHide = { plainHidden += 1 }
        _ = try await plainRuntime.webView.evaluateJavaScript(escape)
        try await waitFor { plainHidden > 0 }
        #expect(plainHidden == 1, "nobody claimed it, so it is the browser's")
        plain.teardown()
    }
}
