import AppKit
import Foundation
import SQLite3
import Testing
import CosmosBlocking
import CosmosCEF
import CosmosCore
import CosmosEngine
@testable import CosmosChromium

/// Chromium, through CEF, for this test process. It can start only once in a process, so it is set up once and every
/// test that needs it shares it. Its helper apps are made from the CosmosHelper the build put next to the tests, inside a
/// stand-in app as they would be inside Cosmos.app (the helpers find the browser by that app's bundle identifier), and
/// its data goes in a folder of its own.
@MainActor
enum CEFTestRuntime {
    private final class Marker {}
    nonisolated static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cosmos-cef-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    nonisolated static let framework = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Vendor/CEF/Release/Chromium Embedded Framework.framework")
    nonisolated static var isAvailable: Bool { FileManager.default.fileExists(atPath: framework.path) }

    /// Nil once Chromium is set up to start; otherwise why it cannot.
    private static let failure: String? = configure()

    /// Chromium, started once with the default settings. Nil when it runs; otherwise why it does not.
    static func start() async -> String? {
        if let failure { return failure }
        let runtime = ChromiumRuntime.shared
        guard await runtime.start(settings: EngineSettings()) else { return runtime.failure ?? "Chromium did not start" }
        _ = stopsBeforeExit
        return nil
    }

    /// Swift Testing ends the process with exit() from a thread of its own, while the main thread may still be closing the
    /// last test's pages; exit() then takes the framework's globals away under Chromium. So Chromium is stopped first:
    /// exit runs the handlers registered last first, and this one is registered after the framework was loaded.
    private static let stopsBeforeExit: Void = {
        atexit {
            let stopped = DispatchSemaphore(value: 0)
            if Thread.isMainThread {
                CosmosCEFRuntime.shutdown { _ in stopped.signal() }
                let deadline = Date().addingTimeInterval(10)
                while stopped.wait(timeout: .now()) == .timedOut, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            } else {
                DispatchQueue.main.async { CosmosCEFRuntime.shutdown { _ in stopped.signal() } }
                _ = stopped.wait(timeout: .now() + 10)
            }
        }
    }()

    /// Makes `id`'s profile the default one (the one extensions run in, whose data is CEF's global context's), for the
    /// profiles made from now on.
    static func makeDefault(_ id: UUID) {
        _ = failure
        ChromiumRuntime.configuration?.defaultProfileID = id
    }

    /// The folders of test processes that have ended.
    private static func removeOldRoots() {
        let temporary = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("cosmos-cef-tests-") {
            guard let pid = Int32(name.dropFirst("cosmos-cef-tests-".count)), pid != ProcessInfo.processInfo.processIdentifier,
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static var products: URL { Bundle(for: Marker.self).bundleURL.deletingLastPathComponent() }

    /// An app as `scripts/build-app.sh` makes Cosmos.app: `executable` (if any) as its program, the framework, and the five
    /// helper apps, which find the browser by the app's bundle identifier. A helper loads the framework from three
    /// folders up from its executable, inside the app, where the sandbox lets it read: a copy (a clone, on APFS: no time
    /// or space), not a link into the repository.
    static func makeApp(at app: URL, identifier: String, executable: URL?) throws {
        let built = products.appendingPathComponent("CosmosHelper")
        let helpers = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let bundled = helpers.appendingPathComponent(framework.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        if let executable {
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: macOS.appendingPathComponent(executable.lastPathComponent))
            try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent(executable.lastPathComponent))
            info["CFBundleExecutable"] = executable.lastPathComponent
            info["LSUIElement"] = true
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if !FileManager.default.fileExists(atPath: bundled.path) { try FileManager.default.copyItem(at: framework, to: bundled) }
        for suffix in ["", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)"] {
            let name = "Cosmos Helper\(suffix)"
            let helperApp = helpers.appendingPathComponent("\(name).app", isDirectory: true)
            let macOS = helperApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: macOS.appendingPathComponent(name))
            try FileManager.default.copyItem(at: built, to: macOS.appendingPathComponent(name))
            let id = suffix.lowercased().filter(\.isLetter)
            let plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "\(identifier).helper" + (id.isEmpty ? "" : ".\(id)"),
                                        "CFBundlePackageType": "APPL", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: helperApp.appendingPathComponent("Contents/Info.plist"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["-s", "-", "-f", helperApp.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
        }
    }

    /// The program of an app with `CosmosEngineCheck` in it, made once.
    static let engineCheck: Result<URL, CDPError> = {
        let program = products.appendingPathComponent("CosmosEngineCheck")
        guard isAvailable, FileManager.default.fileExists(atPath: program.path) else {
            return .failure(CDPError(code: -1, message: "no CEF, or no CosmosEngineCheck next to the tests"))
        }
        let app = root.appendingPathComponent("Engine Check.app", isDirectory: true)
        do { try makeApp(at: app, identifier: "dev.cosmos.enginecheck", executable: program) } catch {
            return .failure(CDPError(code: -1, message: "could not make the engine check app: \(error)"))
        }
        return .success(app.appendingPathComponent("Contents/MacOS/CosmosEngineCheck"))
    }()

    private static func configure() -> String? {
        guard isAvailable else { return "no CEF in Vendor/CEF (scripts/fetch-cef.sh)" }
        removeOldRoots()
        guard FileManager.default.fileExists(atPath: products.appendingPathComponent("CosmosHelper").path) else { return "no CosmosHelper next to the tests" }
        let app = root.appendingPathComponent("Cosmos Tests.app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        do { try makeApp(at: app, identifier: "dev.cosmos.tests", executable: nil) } catch {
            return "could not make the helper apps: \(error)"
        }
        // The Keychain is left alone in tests (a second test binary would be asked about the first one's item), and a fake
        // camera and microphone stand in for the Mac's, so macOS never asks about them. The helpers cannot be sandboxed:
        // the sandbox lets them read only the app the browser process is, and this process is the test runner.
        ChromiumRuntime.configuration = ChromiumRuntime.Configuration(
            mainBundle: app, framework: frameworks.appendingPathComponent(framework.lastPathComponent),
            helper: frameworks.appendingPathComponent("Cosmos Helper.app/Contents/MacOS/Cosmos Helper"),
            root: root, defaultProfileID: UUID(), defaultCache: root.appendingPathComponent("Default", isDirectory: true),
            switches: ["--use-mock-keychain", "--use-fake-device-for-media-stream"], sandboxed: false)
        return nil
    }
}

/// The first of two ends of `within`: the work's, or the clock's.
private final class FirstEnd<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { continuation = c }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}

/// `work`, or an error once `seconds` have gone by: a Chromium that never answers fails the test instead of hanging it.
/// (A task group would wait for the work to end, and a command Chromium never answers does not end.)
func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        let once = FirstEnd(c)
        Task { do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) } }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.finish(.failure(CDPError(code: -9, message: "no answer in \(seconds) s"))) }
    }
}

@MainActor
@Suite(.enabled(if: CEFTestRuntime.isAvailable, "no CEF in Vendor/CEF (scripts/fetch-cef.sh)"), .serialized)
struct CEFRuntimeTests {
    final class Opened: EngineProfileDelegate {
        var pages: [(page: EnginePage, opener: EnginePage?)] = []
        func profile(_ profile: EngineProfile, didOpen page: EnginePage, opener: EnginePage?, request: NewPageRequest) -> Bool {
            pages.append((page, opener)); return true
        }
        func profile(_ profile: EngineProfile, didStartDownload download: EngineDownload) {}
        func profileDidRestart(_ profile: EngineProfile) {}
    }

    private func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// A page is drawn by CEF in a view of Cosmos's, as a page target Cosmos drives over the pipe. A popup it opens is
    /// made by CEF out of sight, and moves into the page Cosmos is given for it, next to its opener.
    @Test func aPageIsDrawnInCosmossViewAndItsPopupMovesIntoAPageOfItsOwn() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        profile.setPageScripts([])
        let opened = Opened()
        profile.delegate = opened
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let page = try #require(profile.makePage() as? ChromiumPage)
        page.view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(page.view)
        let server = try await SiteServer(routes: [
            "/": .init(type: "text/html", body: Data("<title>From CEF</title><body>hello</body>".utf8)),
            "/popup": .init(type: "text/html", body: Data("<title>Popup</title><body>popup</body>".utf8)),
        ])
        page.load(try #require(URL(string: "http://127.0.0.1:\(server.port)/")))
        try await waitFor { page.state.title == "From CEF" }
        #expect(page.state.title == "From CEF")
        #expect(page.cefBrowser?.view?.superview === page.view, "CEF draws inside Cosmos's view")
        #expect(page.targetID != nil && page.cefBrowser?.targetID == page.targetID, "the page knows which target its browser is")
        #expect(await page.evaluate("navigator.webdriver", in: .page) as? Bool == false)

        // As a click would: Chromium blocks a popup no user asked for.
        let session = try #require(page.sessionID)
        let c = try #require(profile.connection)
        _ = try await within(5) {
            _ = try await c.send("Runtime.evaluate", ["expression": "window.open('/popup'), 1", "userGesture": true], session: session)
            return true
        }
        try await waitFor { !opened.pages.isEmpty }
        let popup = try #require(opened.pages.first?.page as? ChromiumPage, "Cosmos was not given the popup")
        #expect(opened.pages.first?.opener === page)
        try await waitFor { popup.cefBrowser?.view?.superview === popup.view && popup.state.title == "Popup" }
        #expect(popup.cefBrowser?.view?.superview === popup.view, "the popup moved into the page Cosmos was given")
        #expect(popup.state.title == "Popup")
    }

    /// Cosmos gives a page the keyboard by making its view the first responder (after the Command Bar or the Find bar
    /// closes, on a tab switch): CEF's view takes it from there, and what is typed reaches the page.
    @Test func aPageGivenTheKeyboardGetsWhatIsTyped() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-focus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        profile.setPageScripts([])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let page = try #require(profile.makePage() as? ChromiumPage)
        page.view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(page.view)
        page.load(URL(string: "data:text/html,<title>Typing</title><input id=i autofocus>")!)
        try await waitFor { page.state.title == "Typing" }
        let cefView = try #require(page.cefBrowser?.view)
        #expect(window.makeFirstResponder(page.view), "the page's view did not take the keyboard")
        try await waitFor(5) { (window.firstResponder as? NSView)?.isDescendant(of: cefView) == true }
        #expect((window.firstResponder as? NSView)?.isDescendant(of: cefView) == true, "CEF's view does not have the keyboard")
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        window.sendEvent(key)
        var typed: String?
        for _ in 0..<100 {
            typed = await page.evaluate("document.getElementById('i').value", in: .page) as? String
            if typed == "a" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(typed == "a")
    }

    /// In a profile other than the default one (which has the bridge extension to clear everything), Clear Site Data
    /// reaches the storage of a site the profile was on even when none of its pages is open any more, and its cookies.
    @Test func clearingSiteDataInAnotherProfileReachesASiteItWasOn() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-clear-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        #expect(!profile.isDefault)
        profile.setPageScripts([])
        let script = "document.title = (localStorage.getItem('k') || 'none') + ' ' + (document.cookie || 'nocookie');"
            + "localStorage.setItem('k', 'kept'); document.cookie = 'c=kept; max-age=3600';"
        let server = try await SiteServer(routes: ["/": .init(type: "text/html", body: Data("<script>\(script)</script>".utf8))])
        let site = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
        func visit() async throws -> String? {
            let page = try #require(profile.makePage() as? ChromiumPage)
            defer { page.close() }
            page.load(site)
            try await waitFor { page.state.title.contains(" ") }
            return page.state.title
        }
        #expect(try await visit() == "none nocookie")
        #expect(try await visit() == "kept c=kept", "the site's storage and cookie are there before clearing")
        await profile.clearSiteData()
        #expect(try await visit() == "none nocookie")
    }

    /// A profile other than the default one has no blocker extension (Chromium loads extensions into the default one
    /// only): it blocks on its own. A request a rule stops never reaches the site, an element a rule hides is hidden, and
    /// a site the user allowed gets both.
    @Test func anotherProfileBlocksAndHidesOnItsOwn() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-block-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        #expect(!profile.isDefault)
        let lists = ContentBlocker.compile(name: "t", text: "/ad.js$script\n##.cosmos-test-ad\n").lists
            .map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        profile.setContentBlocking(lists, allowlist: [])
        profile.setPageScripts([])
        let server = try await SiteServer(routes: [
            "/": .init(type: "text/html", body: Data("<title>Ads</title><div class='cosmos-test-ad'>ad</div><script src='/ad.js'></script>".utf8)),
            "/ad.js": .init(type: "text/javascript", body: Data("window.adRan = true".utf8)),
        ])
        func visit() async throws -> (ran: Bool, display: String?) {
            let page = try #require(profile.makePage() as? ChromiumPage)
            defer { page.close() }
            page.load(try #require(URL(string: "http://127.0.0.1:\(server.port)/")))
            try await waitFor { page.state.title == "Ads" && !page.state.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            let ran = await page.evaluate("window.adRan === true", in: .page) as? Bool ?? false
            let display = await page.evaluate("getComputedStyle(document.querySelector('.cosmos-test-ad')).display", in: .page) as? String
            return (ran, display)
        }
        let blocked = try await visit()
        #expect(!blocked.ran)
        #expect(!server.requests.contains("/ad.js"), "the request never left")
        #expect(blocked.display == "none")
        profile.setContentBlocking(lists, allowlist: ["127.0.0.1"])
        try await Task.sleep(for: .milliseconds(500))
        let allowed = try await visit()
        #expect(allowed.ran)
        #expect(allowed.display == "block")
    }

    /// Chrome's blocker judges each hop of a redirect, and each page by its own site: a request that a page's script makes
    /// and that is sent on to a blocked address is stopped, and a tab that goes from a site the user allowed to one they
    /// did not is blocked again from its first request.
    @Test func anotherProfileBlocksRedirectsAndTheNextSiteInATab() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-block-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        let lists = ContentBlocker.compile(name: "t", text: "/ad.js$script\n").lists
            .map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        profile.setContentBlocking(lists, allowlist: ["localhost"])
        profile.setPageScripts([])
        let server = try await SiteServer(routes: [
            "/": .init(type: "text/html", body: Data("<title>Ads</title><script src='/ad.js'></script>".utf8)),
            "/sent-on": .init(type: "text/html", body: Data("<title>Sent on</title><script src='/out.js'></script>".utf8)),
            "/out.js": .init(type: "text/plain", body: Data(), headers: ["Location: /ad.js?via=redirect"], status: "302 Found"),
            "/ad.js": .init(type: "text/javascript", body: Data("window.adRan = true".utf8)),
        ])
        let page = try #require(profile.makePage() as? ChromiumPage)
        defer { page.close() }
        func visit(_ address: String, title: String) async throws -> Bool {
            page.load(try #require(URL(string: address)))
            try await waitFor { page.state.title == title && !page.state.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            return await page.evaluate("window.adRan === true", in: .page) as? Bool ?? false
        }
        #expect(try await visit("http://127.0.0.1:\(server.port)/sent-on", title: "Sent on") == false)
        #expect(server.requests.contains("/out.js"))
        #expect(!server.requests.contains { $0.hasPrefix("/ad.js") }, "the hop to the blocked address never left: \(server.requests)")

        #expect(try await visit("http://localhost:\(server.port)/", title: "Ads") == true, "the site the user allowed")
        let before = server.requests.filter { $0.hasPrefix("/ad.js") }.count
        #expect(try await visit("http://127.0.0.1:\(server.port)/", title: "Ads") == false, "the next site, in the same tab")
        #expect(server.requests.filter { $0.hasPrefix("/ad.js") }.count == before)
    }

    final class Downloads: EngineProfileDelegate {
        var started: [EngineDownload] = []
        func profile(_ profile: EngineProfile, didOpen page: EnginePage, opener: EnginePage?, request: NewPageRequest) -> Bool { false }
        func profile(_ profile: EngineProfile, didStartDownload download: EngineDownload) { started.append(download) }
        func profileDidRestart(_ profile: EngineProfile) {}
    }

    /// "Download Linked File" and "Download Image" download a file from another site too, with the page's profile, and
    /// the page stays where it is (Chromium ignores `<a download>` for another site's file and would go to it).
    @Test func aFileFromAnotherSiteIsDownloadedAndThePageStays() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        profile.setPageScripts([])
        let downloads = Downloads()
        profile.delegate = downloads
        let server = try await SiteServer(routes: [
            "/": .init(type: "text/html", body: Data("<title>Page</title>".utf8)),
            "/file.txt": .init(type: "text/plain", body: Data("the file".utf8)),
        ])
        let page = try #require(profile.makePage() as? ChromiumPage)
        let here = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
        page.load(here)
        try await waitFor { page.state.title == "Page" }
        profile.download(try #require(URL(string: "http://localhost:\(server.port)/file.txt")), from: page)
        try await waitFor(5) { !downloads.started.isEmpty }
        #expect(downloads.started.first?.suggestedFilename == "file.txt")
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.state.url == here, "the page went to the file")
    }

    final class WindowWatch: NSObject, NSWindowDelegate {
        var closed = false
        func windowWillClose(_ notification: Notification) { closed = true }
    }

    /// Closing a page ends its browser and leaves the window it was in alone (CEF's own way would ask the window to close,
    /// all of Cosmos's tabs with it).
    @Test func closingAPageEndsItsBrowserAndLeavesItsWindowOpen() async throws {
        if let failure = await CEFTestRuntime.start() { Issue.record(Comment(rawValue: failure)); return }
        let engine = ChromiumEngine()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try #require(engine.makeProfile(id: UUID(), directory: folder) as? ChromiumProfile)
        defer { profile.close() }
        profile.setPageScripts([])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let watch = WindowWatch()
        window.delegate = watch
        let page = try #require(profile.makePage() as? ChromiumPage)
        page.view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(page.view)
        page.load(URL(string: "data:text/html,<title>Closing</title>")!)
        try await waitFor { page.state.title == "Closing" }
        let browser = try #require(page.cefBrowser)
        page.close()
        try await waitFor(5) { browser.isClosed }
        #expect(browser.isClosed, "the page's browser did not end")
        #expect(!watch.closed, "closing the page closed its window")
    }

    /// Runs the engine check app on `address` for `seconds`, with its data in `folder`: the lines it printed. One that has
    /// not ended in 30 seconds is stopped, with its helpers.
    private func runEngineCheck(_ folder: URL, _ address: String, seconds: Double = 2) async throws -> [String] {
        let program = try CEFTestRuntime.engineCheck.get()
        let output = folder.appendingPathComponent("check-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let check = Process()
        check.executableURL = program
        check.arguments = [folder.appendingPathComponent("Engine", isDirectory: true).path, address, String(seconds)]
        // A file, not a pipe: Chromium's helpers have the check's output too, and a pipe stays open while one lives.
        check.standardOutput = try FileHandle(forWritingTo: output)
        check.standardError = FileHandle.nullDevice
        try check.run()
        let deadline = Date().addingTimeInterval(30)
        while check.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if check.isRunning {
            check.terminate()
            let helpers = Process()
            helpers.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            helpers.arguments = ["-9", "-f", program.deletingLastPathComponent().deletingLastPathComponent().path]
            try? helpers.run()
            helpers.waitUntilExit()
            Issue.record("the engine check did not end")
        }
        return String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// In Cosmos.app, Chromium's renderers and its network service run in Chromium's sandbox, as they do in Chrome: what
    /// a hostile page breaks into cannot reach the user's files. (Only a process of its own can check this: the sandbox
    /// lets the helpers read only the app the browser process is.)
    @Test func chromiumsProcessesRunInItsSandbox() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = try await runEngineCheck(folder, "data:text/html,<title>Sandboxed</title>")
        #expect(lines.contains("stopped"), "\(lines)")
        let renderers = lines.filter { $0.hasPrefix("renderer ") }
        #expect(!renderers.isEmpty, "\(lines)")
        #expect(renderers.allSatisfy { $0 == "renderer sandboxed" }, "\(lines)")
        #expect(lines.contains("utility network.mojom.NetworkService sandboxed"), "\(lines)")
    }

    /// Quitting stops Chromium before Cosmos ends, so what it had not written yet is on disk: a site's sign-in cookie,
    /// set a moment before, is there the next time. A cookie for this session only is not, as in Chrome.
    @Test func aCookieSetJustBeforeQuittingIsThereNextTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await SiteServer(routes: [
            "/set": .init(type: "text/html", body: Data("<title>Set</title>".utf8),
                          headers: ["Set-Cookie: kept=yes; Max-Age=3600; Path=/", "Set-Cookie: session=yes; Path=/"]),
            "/look": .init(type: "text/html", body: Data("<title>Look</title>".utf8)),
        ])
        let first = try await runEngineCheck(folder, "http://127.0.0.1:\(server.port)/set")
        #expect(first.contains("stopped"), "\(first)")
        #expect(!server.requestHeads(of: "/set").isEmpty, "the first run did not load the page")
        let second = try await runEngineCheck(folder, "http://127.0.0.1:\(server.port)/look")
        #expect(second.contains("stopped"), "\(second)")
        let cookies = server.requestHeads(of: "/look").flatMap { $0 }.filter { $0.lowercased().hasPrefix("cookie:") }
        #expect(cookies.contains { $0.contains("kept=yes") }, "\(cookies)")
        #expect(!cookies.contains { $0.contains("session=yes") }, "\(cookies)")
    }

    /// The addresses in Chromium's own history of a profile whose folder is `profile` (read once Chromium has stopped).
    private func chromiumHistory(_ profile: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(profile.appendingPathComponent("History").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT url FROM urls", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(statement, 0))) }
        return out
    }

    /// A profile other than the default one is told to keep no history of its own (Cosmos keeps the one people see, and
    /// only the default profile can clear Chromium's), and Chromium keeps none there; without that, it would.
    @Test func chromiumKeepsNoHistoryInAProfileToldNotTo() async throws {
        let server = try await SiteServer(routes: ["/": .init(type: "text/html", body: Data("<title>Visited</title>".utf8))])
        let address = "http://127.0.0.1:\(server.port)/"
        for keeps in [true, false] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-cef-history-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let profile = folder.appendingPathComponent("Engine/Default", isDirectory: true)
            ChromiumPreferences.prepare(profile: profile, root: nil, settings: EngineSettings(), keepsHistory: keeps)
            let lines = try await runEngineCheck(folder, address)
            #expect(lines.contains("stopped"), "\(lines)")
            #expect(chromiumHistory(profile).contains(address) == keeps, "keepsHistory \(keeps): \(chromiumHistory(profile))")
        }
    }
}
