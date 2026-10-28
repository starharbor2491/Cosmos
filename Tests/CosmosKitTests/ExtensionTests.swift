import Foundation
import Testing
import AppKit
import CosmosEngine
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

    /// A store with a tab on screen and an extension center started on it; the tab's profile is the fake engine's first.
    private func started() throws -> (Rig, ExtensionCenter, TabRuntime, FakeExtensions) {
        let rig = Rig()
        let center = ExtensionCenter(store: rig.store, directory: rig.dir)
        rig.store.extensionCenter = center
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        center.start()
        let engine = try #require(rig.store.fakeEngine.profiles.first?.fakeExtensions)
        return (rig, center, runtime, engine)
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(done())
    }

    @Test func anInstalledExtensionIsCopiedLoadedAndGetsItsButton() async throws {
        let (rig, center, runtime, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)

        // The prompt is shown with what the manifest asks for, in plain words.
        var summary: ExtensionRequestSummary?
        let installed = try await center.install(from: source, origin: "a test folder") { s in summary = s; return true }
        #expect(installed.name == "Cosmos Test Extension")
        #expect(installed.version == "1.2.3")
        #expect(center.items.count == 1)
        #expect(center.loadErrors.isEmpty)
        #expect(summary?.lines.contains { $0.contains("localhost") } == true)
        #expect(summary?.lines.contains { $0.contains("titles and addresses") } == true)
        #expect(summary?.problems.isEmpty == true)
        let folder = center.folder(for: installed)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        // The engine runs the copy, not the folder it came from.
        let engineID = FakeExtensions.id(for: folder)
        #expect(engine.loaded[engineID]?.standardizedFileURL == folder.standardizedFileURL)

        // Its button shows over the tab, labelled by the engine, and a click goes to the engine.
        engine.buttons = [ExtensionAction(extensionID: engineID, title: "Test action", badgeText: "3")]
        let actions = center.actions(for: runtime)
        #expect(actions.map(\.label) == ["Test action"])
        #expect(actions.first?.badge == "3")
        center.performAction(installed.id, runtime: runtime, anchor: nil)
        try await until { engine.performed == [engineID] }

        // Turning it off takes it out of the engine; removing deletes the files.
        center.setEnabled(installed.id, false)
        #expect(center.actions(for: runtime).isEmpty)
        try await until { engine.unloaded == [engineID] }
        center.remove(installed.id)
        #expect(center.items.isEmpty)
        try await until { !FileManager.default.fileExists(atPath: folder.path) }
    }

    @Test func anExtensionTheEngineCannotLoadIsNotKept() async throws {
        let (rig, center, _, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        engine.refusal = "the manifest is broken"
        // The engine's reason reaches the user, and no entry or files stay behind.
        do {
            try await center.install(from: source, origin: "x") { _ in true }
            Issue.record("installed an extension the engine refused")
        } catch {
            #expect(error.localizedDescription.contains("the manifest is broken"))
        }
        #expect(center.items.isEmpty)
        try await until { ((try? FileManager.default.contentsOfDirectory(atPath: center.extensionsFolder.path)) ?? []).isEmpty }
    }

    /// Adding a Web Store extension that is already there replaces the old copy, but only once the new one loaded.
    @Test func aNewCopyFromTheWebStoreReplacesTheOldOneOnceItLoads() async throws {
        let (rig, center, _, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let first = try await center.install(from: source, origin: "Chrome Web Store", webStoreID: "abcdefghijklmnopabcdefghijklmnop") { _ in true }

        engine.refusal = "it would not load"
        await #expect(throws: ExtensionError.self) {
            try await center.install(from: source, origin: "Chrome Web Store", webStoreID: "abcdefghijklmnopabcdefghijklmnop") { _ in true }
        }
        #expect(center.items.map(\.id) == [first.id], "a copy that would not load leaves the old one in place")
        #expect(engine.loaded[FakeExtensions.id(for: center.folder(for: first))] != nil)
        engine.refusal = nil

        let second = try await center.install(from: source, origin: "Chrome Web Store", webStoreID: "abcdefghijklmnopabcdefghijklmnop") { _ in true }
        #expect(center.items.map(\.id) == [second.id])
        try await until { engine.unloaded.contains(FakeExtensions.id(for: center.folder(for: first))) }
    }

    /// Items an extension added to the right-click menu: only those that run something, for what was clicked.
    @Test func menuItemsAreTheLeavesForWhatWasClicked() async throws {
        let (rig, center, runtime, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let installed = try await center.install(from: source, origin: "x") { _ in true }
        let id = FakeExtensions.id(for: center.folder(for: installed))
        engine.items = [
            ExtensionMenuItem(extensionID: id, itemID: "parent", title: "Parent", contexts: ["all"]),
            ExtensionMenuItem(extensionID: id, itemID: "child", title: "Child", contexts: ["link"], parentID: "parent"),
            ExtensionMenuItem(extensionID: id, itemID: "page", title: "Page", contexts: ["page"]),
            ExtensionMenuItem(extensionID: "someone-else", itemID: "x", title: "Not ours", contexts: ["page"]),
        ]
        #expect(center.menuItems(for: runtime, contexts: ["page", "all"]).map(\.itemID) == ["page"])
        #expect(center.menuItems(for: runtime, contexts: ["link", "all"]).map(\.itemID) == ["child"])
        let context = ExtensionClickContext(pageURL: URL(string: "https://example.com/"), linkURL: URL(string: "https://example.com/a"))
        center.performMenuItem(engine.items[1], context: context, on: runtime)
        try await until { engine.clicked.count == 1 }
        #expect(engine.clicked.first?.1 == context)
    }

    /// An extension's notification goes to macOS (here, the stand-in), and what the user does with it goes back to the
    /// extension.
    @Test func anExtensionsNotificationIsPostedAndAnsweredThroughTheCenter() async throws {
        let (rig, _, _, engine) = try started()
        let notifier = FakeNotifier()
        rig.store.notifier = notifier
        let note = EngineNotification(id: "n1", title: "Done", body: "Uploaded", source: "Uploader", buttons: ["Open"])
        engine.onNotification?("ext-uploader", note)
        let shown = try #require(notifier.shown.first)
        #expect(shown.note == note)
        shown.onAction(.button(0))
        try await until { engine.notificationActions.count == 1 }
        #expect(engine.notificationActions.first?.id == "n1")
        #expect(engine.notificationActions.first?.extensionID == "ext-uploader")
        #expect(engine.notificationActions.first?.action == .button(0))
        engine.onNotificationClosed?("ext-uploader", "n1")
        #expect(notifier.closed == [shown.key])
    }

    /// An extension asks for its side panel: the window shows the panel's page beside the tab's, and asking again (the
    /// button, a second time) closes it.
    @Test func anExtensionsSidePanelOpensInTheWindowAndClosesOnTheSecondAsk() async throws {
        let (rig, center, runtime, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let installed = try await center.install(from: source, origin: "x") { _ in true }
        let id = FakeExtensions.id(for: center.folder(for: installed))
        engine.onSidePanelRequest?(id, runtime.page)
        try await until { rig.window.sidePanel != nil }
        #expect(rig.window.sidePanel?.extensionID == id)
        #expect(rig.window.sidePanel?.title == "Cosmos Test Extension")
        #expect(engine.sidePanelsOpened == [id])
        engine.onSidePanelRequest?(id, runtime.page)
        try await until { rig.window.sidePanel == nil }
    }

    @Test func aProfileOpenedLaterGetsTheEnabledExtensions() async throws {
        let (rig, center, _, _) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let on = try await center.install(from: source, origin: "x") { _ in true }
        let off = try await center.install(from: source, origin: "x") { _ in true }
        center.setEnabled(off.id, false)

        let profileID = rig.store.addProfile(named: "Work")
        _ = rig.store.environment(forProfile: profileID)
        let later = try #require(rig.store.fakeEngine.profiles.last?.fakeExtensions)
        try await until { !later.loaded.isEmpty }
        #expect(Set(later.loaded.keys) == [FakeExtensions.id(for: center.folder(for: on))])
    }

    @Test func installedExtensionsSurviveARestart() async throws {
        let (rig, center, _, _) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        let installed = try await center.install(from: source, origin: "a test folder") { _ in true }
        center.setEnabled(installed.id, false)

        let again = ExtensionCenter(store: rig.store, directory: rig.dir)
        #expect(again.items.map(\.name) == ["Cosmos Test Extension"])
        #expect(again.items.first?.enabled == false)
        #expect(again.items.first?.id == installed.id)
    }

    @Test func aFolderWithoutAManifestIsRejectedAndNothingIsLeftBehind() async throws {
        let (rig, center, _, _) = try started()
        let empty = rig.dir.appendingPathComponent("not-an-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await #expect(throws: ExtensionError.self) { try await center.install(from: empty, origin: "x") { _ in true } }
        #expect(center.items.isEmpty)
    }

    @Test func decliningThePromptInstallsNothing() async throws {
        let (rig, center, _, engine) = try started()
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try writeTestExtension(to: source)
        await #expect(throws: ExtensionError.self) { try await center.install(from: source, origin: "x") { _ in false } }
        #expect(center.items.isEmpty)
        #expect(engine.loaded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.extensionsFolder.path))
    }

    /// What Chromium no longer runs, and what it runs but Cosmos has nowhere to show, is said before anything is added.
    @Test func theManifestsProblemsAreSpelledOut() {
        let v2 = ExtensionRequestSummary.read(["manifest_version": 2, "version": "1", "permissions": ["tabs", "https://a.com/*"]])
        #expect(v2.problems.contains { $0.contains("Manifest V2") })
        #expect(v2.permissions == ["tabs"])
        #expect(v2.hostPatterns == ["https://a.com/*"])
        let shown = ExtensionRequestSummary.read(["manifest_version": 3, "version": "2", "permissions": ["sidePanel", "notifications", "identity"]])
        #expect(shown.problems.isEmpty, "side panels, notifications and sign-in pages are all drawn by Cosmos")
        let google = ExtensionRequestSummary.read(["manifest_version": 3, "version": "2", "permissions": ["identity"], "oauth2": ["client_id": "x"]])
        #expect(google.problems == ["Its Google sign-in goes through a web page instead of a Google account in the browser; some Google services refuse that."])
        let fine = ExtensionRequestSummary.read(["manifest_version": 3, "version": "3", "permissions": ["storage"],
                                                 "content_scripts": [["matches": ["https://b.com/*", "https://b.com/*"]]]])
        #expect(fine.problems.isEmpty)
        #expect(fine.hostPatterns == ["https://b.com/*"])
    }

    @Test func permissionsAreExplainedInPlainWords() {
        let all = ExtensionRequestSummary(name: "A", version: "1", origin: "x", permissions: ["tabs", "storage", "webRequest"], hostPatterns: ["<all_urls>"], problems: [])
        #expect(all.lines.first == "Read and change your data on all websites")
        #expect(all.lines.contains("See your network requests"))
        let some = ExtensionRequestSummary(name: "B", version: "1", origin: "x", permissions: [], hostPatterns: ["https://*.example.com/*", "https://news.site/*"], problems: [])
        #expect(some.lines == ["Read and change your data on example.com, news.site"])
        let none = ExtensionRequestSummary(name: "C", version: "1", origin: "x", permissions: [], hostPatterns: [], problems: [])
        #expect(none.lines.isEmpty)
        // Files on the Mac are not a website, and are said separately.
        let files = ExtensionRequestSummary(name: "D", version: "1", origin: "x", permissions: [], hostPatterns: ["file:///*", "https://a.com/*"], problems: [])
        #expect(files.lines == ["Read and change your data on a.com", "Read files on your Mac that you open in Cosmos"])
    }
}

@MainActor
@Suite struct ExtensionShortcutTests {
    private func key(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// On a Mac a manifest's `Ctrl` is ⌘ and `MacCtrl` is ⌃.
    @Test func manifestShortcutsReadTheMacWay() {
        #expect(ExtensionShortcut("Ctrl+Shift+Y")?.modifiers == [.command, .shift])
        #expect(ExtensionShortcut("Ctrl+Shift+Y")?.key == "y")
        #expect(ExtensionShortcut("MacCtrl+Comma")?.modifiers == [.control])
        #expect(ExtensionShortcut("MacCtrl+Comma")?.key == ",")
        #expect(ExtensionShortcut("Alt+Up")?.key == "\u{F700}")
        #expect(ExtensionShortcut("Shift+Y") == nil, "a shortcut needs more than Shift")
        #expect(ExtensionShortcut("Ctrl+") == nil)
    }

    @Test func aShortcutMatchesOnlyItsOwnKeys() {
        let shortcut = ExtensionShortcut("Ctrl+Shift+Y")!
        #expect(shortcut.matches(key("Y", keyCode: 16, [.command, .shift])))
        #expect(!shortcut.matches(key("y", keyCode: 16, [.command])))
        #expect(!shortcut.matches(key("Y", keyCode: 16, [.command, .shift, .option])))
    }

    /// With ⇧ held a digit types its symbol; the shortcut is still for the digit.
    @Test func aShiftedDigitIsStillTheDigit() {
        let shortcut = ExtensionShortcut("Ctrl+Shift+1")!
        #expect(shortcut.matches(key("!", keyCode: 18, [.command, .shift])))
    }
}
