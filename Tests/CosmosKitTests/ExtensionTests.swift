import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct ExtensionTests {
    /// A small Manifest V3 extension: a content script that marks the page and asks the background worker a question.
    func writeTestExtension(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Cosmos Test Extension","version":"1.2.3",
         "permissions":["storage","tabs"],"host_permissions":["http://localhost/*"],
         "background":{"service_worker":"background.js"},
         "content_scripts":[{"matches":["http://localhost/*"],"js":["content.js"],"run_at":"document_end"}],
         "action":{"default_title":"Test action"}}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          sendResponse({ echo: message.ping, tabURL: sender.tab ? sender.tab.url : null });
        });
        """.write(to: folder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try """
        document.documentElement.setAttribute('data-cosmos-ext', 'injected');
        chrome.runtime.sendMessage({ ping: 42 }, (reply) => {
          document.documentElement.setAttribute('data-cosmos-reply', JSON.stringify(reply));
        });
        """.write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
    }

    func attribute(_ name: String, in runtime: TabRuntime) async -> String? {
        try? await runtime.webView.evaluateJavaScript("document.documentElement.getAttribute('\(name)')") as? String
    }

    @Test(.enabled(if: ExtensionCenter.isSupported))
    func anInstalledExtensionRunsOnPagesAndTalksToItsBackgroundWorker() async throws {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)

        let center = ExtensionCenter(store: rig.store, directory: rig.dir, persistentStorage: false)
        rig.store.extensionCenter = center
        center.start()
        #expect(center.controllerObject != nil)

        // The prompt is shown with what the manifest asks for, in plain words.
        var summary: ExtensionRequestSummary?
        let installed = try await center.install(from: source, origin: "a test folder") { s in summary = s; return true }
        #expect(installed.name == "Cosmos Test Extension")
        #expect(center.items.count == 1)
        #expect(center.loadErrors.isEmpty)
        #expect(summary?.lines.contains { $0.contains("localhost") } == true)
        #expect(summary?.lines.contains { $0.contains("titles and addresses") } == true)
        #expect(FileManager.default.fileExists(atPath: center.folder(for: installed).appendingPathComponent("manifest.json").path))

        // A real tab, configured by its profile, gets the content script and a reply from the background worker.
        let server = try await PageServer(html: "<html><head><title>page</title></head><body>hello</body></html>")
        let pageURL = try #require(URL(string: "http://localhost:\(server.port)/"))
        let id = try #require(rig.store.newTab(url: pageURL, in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        for _ in 0..<100 where runtime.isLoading || runtime.url == nil { try await Task.sleep(for: .milliseconds(100)) }

        var injected: String?
        var reply: String?
        for _ in 0..<100 where reply == nil {
            try await Task.sleep(for: .milliseconds(100))
            injected = await attribute("data-cosmos-ext", in: runtime)
            reply = await attribute("data-cosmos-reply", in: runtime)
        }
        #expect(injected == "injected")
        let json = try #require(reply)
        #expect(json.contains("\"echo\":42"))
        #expect(json.contains("localhost"))     // sender.tab.url: WebKit knows about Cosmos's tab

        // The toolbar button exists for the tab.
        let actions = center.actions(for: runtime)
        #expect(actions.count == 1)
        #expect(actions.first?.label == "Test action")

        // Turning it off removes it again; removing deletes the files.
        center.setEnabled(installed.id, false)
        #expect(center.actions(for: runtime).isEmpty)
        center.remove(installed.id)
        #expect(center.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.folder(for: installed).path))
    }

    @Test(.enabled(if: ExtensionCenter.isSupported))
    func installedExtensionsSurviveARestart() async throws {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let center = ExtensionCenter(store: rig.store, directory: rig.dir, persistentStorage: false)
        rig.store.extensionCenter = center
        center.start()
        let installed = try await center.install(from: source, origin: "a test folder") { _ in true }
        center.setEnabled(installed.id, false)

        let again = ExtensionCenter(store: rig.store, directory: rig.dir, persistentStorage: false)
        #expect(again.items.map(\.name) == ["Cosmos Test Extension"])
        #expect(again.items.first?.enabled == false)
        #expect(again.items.first?.id == installed.id)
    }

    @Test(.enabled(if: ExtensionCenter.isSupported))
    func aFolderWithoutAManifestIsRejectedAndNothingIsLeftBehind() async throws {
        let rig = Rig()
        let empty = rig.dir.appendingPathComponent("not-an-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let center = ExtensionCenter(store: rig.store, directory: rig.dir, persistentStorage: false)
        rig.store.extensionCenter = center
        center.start()
        await #expect(throws: ExtensionError.self) { try await center.install(from: empty, origin: "x") { _ in true } }
        #expect(center.items.isEmpty)
    }

    @Test(.enabled(if: ExtensionCenter.isSupported))
    func decliningThePromptInstallsNothing() async throws {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let center = ExtensionCenter(store: rig.store, directory: rig.dir, persistentStorage: false)
        rig.store.extensionCenter = center
        center.start()
        await #expect(throws: ExtensionError.self) { try await center.install(from: source, origin: "x") { _ in false } }
        #expect(center.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.extensionsFolder.path))
    }

    @Test func permissionsAreExplainedInPlainWords() {
        let all = ExtensionRequestSummary(name: "A", version: "1", origin: "x", permissions: ["tabs", "storage", "webRequest"], hostPatterns: ["<all_urls>"], problems: [])
        #expect(all.lines.first == "Read and change your data on all websites")
        #expect(all.lines.contains("See your network requests"))
        let some = ExtensionRequestSummary(name: "B", version: "1", origin: "x", permissions: [], hostPatterns: ["https://*.example.com/*", "https://news.site/*"], problems: [])
        #expect(some.lines == ["Read and change your data on example.com, news.site"])
        let none = ExtensionRequestSummary(name: "C", version: "1", origin: "x", permissions: [], hostPatterns: [], problems: [])
        #expect(none.lines.isEmpty)
    }
}
