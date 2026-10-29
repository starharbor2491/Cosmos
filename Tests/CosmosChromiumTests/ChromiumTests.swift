import AppKit
import Foundation
import Testing
import CosmosCore
import CosmosEngine
@testable import CosmosChromium

// The parts of the Chromium layer that need no Chromium: how Cosmos talks to it, what it writes for it, and how it keeps
// it up to date. Cosmos on a running Chromium is tested in CosmosKitTests (PageAgentTests).

@Suite struct CDPFramingTests {
    @Test func messagesAreSplitAtEachNULAndAPartialOneWaits() {
        var buffer = Data(#"{"id":1}"#.utf8) + Data([0]) + Data(#"{"method":"#.utf8)
        let first = CDPFraming.split(&buffer)
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == [#"{"id":1}"#])
        #expect(String(decoding: buffer, as: UTF8.self) == #"{"method":"#)

        buffer.append(Data(#""Page.loadEventFired"}"#.utf8) + Data([0]) + Data(#"{"id":2}"#.utf8) + Data([0]))
        let rest = CDPFraming.split(&buffer)
        #expect(rest.map { String(decoding: $0, as: UTF8.self) } == [#"{"method":"Page.loadEventFired"}"#, #"{"id":2}"#])
        #expect(buffer.isEmpty)
    }

    @Test func aCommandEndsWithNULAndNamesItsSession() throws {
        let data = try #require(CDPFraming.encode(id: 7, method: "Page.navigate", params: ["url": "https://example.com/"], sessionID: "S1"))
        #expect(data.last == 0)
        let message = try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        #expect(message["id"] as? Int == 7)
        #expect(message["method"] as? String == "Page.navigate")
        #expect(message["sessionId"] as? String == "S1")
        #expect((message["params"] as? [String: Any])?["url"] as? String == "https://example.com/")
        let browser = try #require(CDPFraming.encode(id: 8, method: "Browser.getVersion", params: [:], sessionID: nil))
        #expect((try JSONSerialization.jsonObject(with: browser.dropLast()) as? [String: Any])?["sessionId"] == nil)
    }
}

@Suite struct CDPConnectionTests {
    /// A command to a page's session that is waiting when the page goes away (its tab closed) fails then, instead of
    /// waiting for ever; one to another session still gets its answer.
    @Test func aCommandToASessionThatGoesAwayFails() async throws {
        let toCosmos = Pipe(), toChromium = Pipe()
        let connection = CDPConnection(readFrom: toCosmos.fileHandleForReading, writeTo: toChromium.fileHandleForWriting)
        connection.start()
        defer { connection.close(); try? toCosmos.fileHandleForWriting.close() }
        func send(_ message: [String: Any]) throws {
            toCosmos.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data([0]))
        }
        let gone = Task { try await connection.send("Runtime.evaluate", ["expression": "1"], session: "closing") }
        let staying = Task { try await connection.send("Runtime.evaluate", ["expression": "2"], session: "staying") }
        // Both commands are out before the tab goes.
        var written = Data()
        while written.split(separator: 0).count < 2 { written.append(toChromium.fileHandleForReading.availableData) }
        let ids = written.split(separator: 0).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        let stayingID = try #require(ids.first { $0["sessionId"] as? String == "staying" }?["id"] as? Int)
        try send(["method": "Target.detachedFromTarget", "params": ["sessionId": "closing", "targetId": "T"]])
        await #expect(throws: CDPError.self) { try await gone.value }
        try send(["id": stayingID, "result": ["result": ["value": 2]]])
        #expect(try await staying.value["result"] as? [String: Int] == ["value": 2])
    }
}

@Suite struct ChromiumPreferencesTests {
    @Test func cosmossSettingsBecomeChromiumsOwnPreferences() throws {
        var s = EngineSettings()
        s.cookies = .blockThirdParty
        s.javaScript = false
        s.camera = .block
        s.doNotTrack = true
        s.preloadPages = false
        s.httpsFirst = true
        s.webRTC = .publicInterfaceOnly
        s.standardFont = "Georgia"
        s.languages = ["fr-CA", "en"]
        let p = ChromiumPreferences.preferences(s, keepsHistory: true, system: [])
        let profile = try #require(p["profile"] as? [String: Any])
        let values = try #require(profile["default_content_setting_values"] as? [String: Any])
        #expect(profile["cookie_controls_mode"] as? Int == 2)
        #expect(profile["block_third_party_cookies"] as? Bool == true)
        #expect(values["javascript"] as? Int == 2, "2 blocks")
        #expect(values["media_stream_camera"] as? Int == 2)
        #expect(values["geolocation"] as? Int == 3, "3 asks")
        #expect(p["enable_do_not_track"] as? Bool == true)
        #expect((p["net"] as? [String: Any])?["network_prediction_options"] as? Int == 2)
        #expect(p["https_only_mode_enabled"] as? Bool == true)
        #expect(((p["webrtc"] as? [String: Any])?["ip_handling_policy"] as? String) == "default_public_interface_only")
        #expect((p["intl"] as? [String: Any])?["accept_languages"] as? String == "fr-CA,fr,en")
        let webprefs = try #require((p["webkit"] as? [String: Any])?["webprefs"] as? [String: Any])
        #expect(((webprefs["fonts"] as? [String: Any])?["standard"] as? [String: Any])?["Zyyy"] as? String == "Georgia")
        let zoom = try #require(((p["partition"] as? [String: Any])?["default_zoom_level"] as? [String: Any])?["x"] as? Double)
        #expect(zoom == 0, "pages are drawn at the screen's own scale")
    }

    /// The headless Chromium Cosmos ran before drew pages at the screen's scale through Chromium's default zoom (200% on a
    /// Retina screen), saved in the same file a profile has now: it goes back to 100%, and the rest of the file stays.
    @Test func aProfileFromHeadlessChromiumIsBackAt100Percent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let old: [String: Any] = ["partition": ["default_zoom_level": ["x": log(2) / log(1.2)]], "profile": ["exit_type": "Normal"]]
        try JSONSerialization.data(withJSONObject: old).write(to: profile.appendingPathComponent("Preferences"))

        ChromiumPreferences.prepare(profile: profile, root: nil, settings: EngineSettings(), keepsHistory: true)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Preferences"))) as? [String: Any])
        #expect(((written["partition"] as? [String: Any])?["default_zoom_level"] as? [String: Any])?["x"] as? Double == 0)
        #expect((written["profile"] as? [String: Any])?["exit_type"] as? String == "Normal")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Local State").path), "only the browser writes Local State")

        ChromiumPreferences.prepare(profile: profile, root: root, settings: EngineSettings(), keepsHistory: true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Local State").path))
    }

    /// Chromium keeps what a profile allows a site in its `Preferences`, and Cosmos puts the user's decisions back as
    /// pages open: one the user took back while the site was not open must not be there. Camera, microphone, location and
    /// notifications from the last run are gone before the profile opens; Chromium's other site settings stay.
    @Test func permissionsFromTheLastRunAreGoneBeforeAProfileOpens() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let allowed: [String: Any] = ["https://site.test:443,*": ["setting": 1]]
        let old: [String: Any] = ["profile": ["content_settings": ["exceptions": [
            "geolocation": allowed, "notifications": allowed, "media_stream_camera": allowed, "media_stream_mic": allowed, "cookies": allowed,
        ]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: profile.appendingPathComponent("Preferences"))

        ChromiumPreferences.prepare(profile: profile, root: nil, settings: EngineSettings(), keepsHistory: true)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Preferences"))) as? [String: Any])
        let exceptions = try #require(((written["profile"] as? [String: Any])?["content_settings"] as? [String: Any])?["exceptions"] as? [String: Any])
        #expect(Set(exceptions.keys) == ["cookies"])
    }

    /// Cosmos keeps the history people see. Chromium keeps one of its own in each profile, which only the default profile
    /// can clear (through its bridge extension): the others keep none.
    @Test func onlyTheDefaultProfileKeepsChromiumsHistory() {
        func savingDisabled(_ keeps: Bool) -> Bool? {
            (ChromiumPreferences.preferences(EngineSettings(), keepsHistory: keeps, system: [])["history"] as? [String: Any])?["saving_disabled"] as? Bool
        }
        #expect(savingDisabled(true) == false)
        #expect(savingDisabled(false) == true)
    }

    @Test func theUsersOtherChromiumSettingsAreKept() {
        let base: [String: Any] = ["profile": ["exit_type": "Normal", "default_content_setting_values": ["images": 2, "midi": 1]], "extensions": ["x": 1]]
        let patch: [String: Any] = ["profile": ["default_content_setting_values": ["images": 1]]]
        let merged = ChromiumPreferences.merge(patch, into: base)
        let profile = merged["profile"] as? [String: Any]
        #expect(profile?["exit_type"] as? String == "Normal")
        #expect((profile?["default_content_setting_values"] as? [String: Any])?["images"] as? Int == 1)
        #expect((profile?["default_content_setting_values"] as? [String: Any])?["midi"] as? Int == 1)
        #expect((merged["extensions"] as? [String: Any])?["x"] as? Int == 1)
    }

    @Test func languagesFollowTheMacUnlessChosen() {
        #expect(ChromiumPreferences.languages(EngineSettings(), system: ["de_DE", "en-GB"]) == "de-DE,de,en-GB,en")
        #expect(ChromiumPreferences.languages(EngineSettings(), system: []) == "en-US,en")
    }

    @Test func turningTheGraphicsProcessorOffIsAFlag() {
        var s = EngineSettings()
        #expect(ChromiumPreferences.flags(settings: s).isEmpty)
        s.hardwareAcceleration = false
        #expect(ChromiumPreferences.flags(settings: s) == ["--disable-gpu"])
        #expect((ChromiumPreferences.localState(s)["hardware_acceleration_mode"] as? [String: Any])?["enabled"] as? Bool == false)
    }
}

@Suite struct BlockerExtensionTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-blocker-\(UUID().uuidString)", isDirectory: true) }

    private func json(_ url: URL) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) }

    private let network = CompiledBlockingList(name: "a.network.1", json: #"[{"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"||ads.example^"}}, {"priority":2,"action":{"type":"allow"},"condition":{"urlFilter":"||ads.example/ok"}}]"#,
                                               kind: .network, digest: "n1")
    private let cosmetic = CompiledBlockingList(name: "a.cosmetic.1", json: #"{"generic":[".ad"],"specific":{"news.example":[".promo"]},"exceptions":{"quiet.example":[".ad"]},"genericHide":["calm.example"],"hideNothing":[]}"#,
                                                kind: .cosmetic, digest: "c1")

    /// The lists become a Manifest V3 extension Chromium loads: rulesets with numbered rules, and hiding as content scripts.
    @Test func theListsBecomeAnExtensionChromiumLoads() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BlockerExtension.write([network, cosmetic], allowlist: ["Mine.example"], to: dir))

        let manifest = try #require(try json(dir.appendingPathComponent("manifest.json")) as? [String: Any])
        #expect(manifest["manifest_version"] as? Int == 3)
        #expect(manifest["permissions"] as? [String] == ["declarativeNetRequest"])
        let resources = try #require((manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]])
        #expect(resources.map { $0["id"] as? String } == ["r1", "allow"])

        let rules = try #require(try json(dir.appendingPathComponent("rules-1.json")) as? [[String: Any]])
        #expect(rules.map { $0["id"] as? Int } == [1, 2], "Chromium needs every rule numbered")
        let allow = try #require(try json(dir.appendingPathComponent("allow.json")) as? [[String: Any]])
        let condition = try #require(allow.first?["condition"] as? [String: Any])
        #expect((allow.first?["action"] as? [String: Any])?["type"] as? String == "allowAllRequests")
        #expect(condition["requestDomains"] as? [String] == ["mine.example"])
        #expect(allow.first?["priority"] as? Int ?? 0 > 4, "a site the user allowed beats every list")

        let scripts = try #require(manifest["content_scripts"] as? [[String: Any]])
        let generic = try #require(scripts.first { ($0["css"] as? [String]) == ["generic.css"] })
        #expect(Set(generic["exclude_matches"] as? [String] ?? []) == Set(BlockerExtension.patterns(for: "mine.example") + BlockerExtension.patterns(for: "calm.example")))
        #expect(try String(contentsOf: dir.appendingPathComponent("generic.css"), encoding: .utf8) == ".ad { display: none !important; }")
        let sites = try String(contentsOf: dir.appendingPathComponent("sites.js"), encoding: .utf8)
        #expect(sites.contains("news.example") && sites.contains(".promo"))
    }

    @Test func nothingToBlockWritesNoExtension() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!BlockerExtension.write([], allowlist: [], to: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
    }

    /// Chromium drops a whole style rule over one selector it does not know, so selectors go in small groups.
    @Test func selectorsGoInGroups() {
        let css = BlockerExtension.styleSheet((0..<5).map { ".s\($0)" }, groupSize: 2)
        #expect(css.components(separatedBy: "\n").filter { $0.hasSuffix("{ display: none !important; }") }.count == 3)
    }
}

@MainActor
@Suite struct ChromiumExtensionHostTests {
    @Test func shortcutsComeFromTheManifestWithTheMacOnesFirst() {
        let manifest: [String: Any] = ["commands": [
            "_execute_action": ["suggested_key": ["default": "Ctrl+Shift+Y", "mac": "Command+Shift+Y"]],
            "toggle": ["suggested_key": ["default": "Alt+T"], "description": "Toggle it"],
            "unbound": ["description": "No key"],
        ]]
        let commands = ChromiumExtensionHost.commands(manifest, extensionID: "x")
        #expect(commands.map(\.name) == ["_execute_action", "toggle"])
        #expect(commands.first?.shortcut == "Command+Shift+Y")
        #expect(commands.last?.description == "Toggle it")
    }

    @Test func badgeColoursComeAsListsOrHex() {
        #expect(ChromiumExtensionHost.color([255.0, 0.0, 0.0, 255.0]) == RGBA(1, 0, 0, 1))
        #expect(ChromiumExtensionHost.color("#00ff00") == RGBA(hex: 0x00FF00))
        #expect(ChromiumExtensionHost.color("#f00") == RGBA(hex: 0xFF0000), "the short form too")
        #expect(ChromiumExtensionHost.color("red") == nil)
    }

    /// An icon path is the extension's own file: `../` cannot reach out of its folder, not even into one next to it.
    @Test func anIconIsReadOnlyFromInsideTheExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ext = root.appendingPathComponent("ext", isDirectory: true)
        let sibling = root.appendingPathComponent("ext-other", isDirectory: true)
        try FileManager.default.createDirectory(at: ext.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("own".utf8).write(to: ext.appendingPathComponent("icons/32.png"))
        try Data("secret".utf8).write(to: sibling.appendingPathComponent("x.png"))

        #expect(ChromiumExtensionHost.iconData(["16": "icons/16.png", "32": "icons/32.png"], folder: ext) == Data("own".utf8))
        #expect(ChromiumExtensionHost.iconData("../ext-other/x.png", folder: ext) == nil)
        #expect(ChromiumExtensionHost.iconData("/../ext-other/x.png", folder: ext) == nil)
    }
}

@MainActor
@Suite struct ChromiumPageViewTests {
    /// The page is CEF's view, inside this one, so the click is seen on its way there. A menu from the keyboard's menu
    /// key is not tied to a click from half a minute ago.
    @Test func aRightClickOnThePageCountsForTheMenuOnlyForAMoment() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = NSView(frame: view.bounds)
        view.addSubview(page)
        window.contentView?.addSubview(view)
        let now = ProcessInfo.processInfo.systemUptime
        func click(at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: .option, timestamp: now,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.saw(try click(at: NSPoint(x: 9, y: 9)))
        #expect(view.recentContextClick(now: now + 0.5)?.location == NSPoint(x: 9, y: 9))
        #expect(view.recentContextClick(now: now + 0.5)?.modifiers == .option)
        #expect(view.recentContextClick(now: now + 30) == nil)

        // A click on something over the page (Cosmos's own) is not the page's.
        let over = NSView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(over)
        view.saw(try click(at: NSPoint(x: 300, y: 9)))
        #expect(view.recentContextClick(now: now + 0.5)?.location == NSPoint(x: 9, y: 9))
    }
}

/// The copy of an extension Chromium loads, with Cosmos's scripts ahead of the extension's own.
@Suite struct ExtensionStageTests {
    @Test func theWorkerRunsCosmossScriptFirstAndKeepsItsOwnFolder() {
        let (classic, worker) = ExtensionStage.rewrite(["background": ["service_worker": "js/bg.js"]])
        #expect((classic["background"] as? [String: Any])?["service_worker"] as? String == "js/cosmos-worker.js",
                "next to the extension's own, so its relative importScripts resolve as before")
        #expect(worker.path == "js/cosmos-worker.js")
        let shim = ChromiumResources.jsString("/cosmos-extension/worker.js")
        #expect(worker.source == "importScripts(\(shim), \(ChromiumResources.jsString("/js/bg.js")));\n")

        let (_, module) = ExtensionStage.rewrite(["background": ["service_worker": "bg.js", "type": "module"]])
        #expect(module.path == "cosmos-worker.js")
        #expect(module.source == "import \(shim);\nimport \(ChromiumResources.jsString("/bg.js"));\n")

        // One without a worker gets one: its pages ask Cosmos through it.
        let (none, only) = ExtensionStage.rewrite(["name": "x"])
        #expect((none["background"] as? [String: Any])?["service_worker"] as? String == "cosmos-worker.js")
        #expect(only.source == "importScripts(\(shim));\n")
    }

    @Test func cosmossContentScriptGoesAheadOfTheExtensionsInItsWorldOnly() {
        let manifest: [String: Any] = ["content_scripts": [
            ["matches": ["<all_urls>"], "js": ["a.js", "b.js"]],
            ["matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN"],
            ["matches": ["<all_urls>"], "css": ["c.css"]],
        ]]
        let sets = ExtensionStage.rewrite(manifest).manifest["content_scripts"] as? [[String: Any]] ?? []
        #expect(sets.map { $0["js"] as? [String] ?? [] } == [["cosmos-extension/content.js", "a.js", "b.js"], ["main.js"], []])
    }

    @Test func aPageGetsCosmossScriptFirst() {
        let tag = "<script src=\"/cosmos-extension/page.js\"></script>"
        #expect(ExtensionStage.withPageShim("<!doctype html><html lang=en><HEAD><title>t</title></head>") == "<!doctype html><html lang=en><HEAD>\(tag)<title>t</title></head>")
        #expect(ExtensionStage.withPageShim("<!DOCTYPE html><body>x</body>") == "<!DOCTYPE html>\(tag)<body>x</body>", "after the doctype, never before it")
        #expect(ExtensionStage.withPageShim("<p>bare</p>") == "\(tag)<p>bare</p>")
    }

    @Test func aStagedCopyHasCosmossFilesAndTheExtensionsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "t", "version": "1", "background": {"service_worker": "w.js"}}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        try Data("self.own = 1".utf8).write(to: source.appendingPathComponent("w.js"))
        try Data("<html><head></head></html>".utf8).write(to: source.appendingPathComponent("popup.html"))
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try ExtensionStage.stage(source, to: staged, scripts: .init(worker: "W", content: "C", page: "P"))
        #expect(try String(contentsOf: staged.appendingPathComponent("cosmos-extension/worker.js"), encoding: .utf8) == "W")
        #expect(try String(contentsOf: staged.appendingPathComponent("w.js"), encoding: .utf8) == "self.own = 1")
        #expect(try String(contentsOf: staged.appendingPathComponent("popup.html"), encoding: .utf8).contains("cosmos-extension/page.js"))
        #expect(try String(contentsOf: source.appendingPathComponent("popup.html"), encoding: .utf8) == "<html><head></head></html>", "the extension's own folder is left as it was")
    }

    /// Staging writes into the copy (the manifest, its pages, the worker). A link in the extension's folder would carry
    /// those writes to the file it points at, anywhere on the Mac; a worker path with ".." would put the worker outside.
    @Test func anExtensionWithALinkOrAPathOutOfItsFolderIsNotStaged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let outside = root.appendingPathComponent("someone's notes.html")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><head></head>mine</html>".utf8).write(to: outside)

        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "t", "version": "1"}"#.utf8).write(to: linked.appendingPathComponent("manifest.json"))
        try fm.createSymbolicLink(at: linked.appendingPathComponent("popup.html"), withDestinationURL: outside)
        #expect(throws: CDPError.self) {
            try ExtensionStage.stage(linked, to: root.appendingPathComponent("staged-1"), scripts: .init(worker: "W", content: "C", page: "P"))
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "<html><head></head>mine</html>", "the file the link points at is untouched")

        let escaping = root.appendingPathComponent("escaping", isDirectory: true)
        try fm.createDirectory(at: escaping, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "t", "version": "1", "background": {"service_worker": "../../w.js"}}"#.utf8)
            .write(to: escaping.appendingPathComponent("manifest.json"))
        #expect(throws: CDPError.self) {
            try ExtensionStage.stage(escaping, to: root.appendingPathComponent("a/b/staged-2"), scripts: .init(worker: "W", content: "C", page: "P"))
        }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("a/cosmos-worker.js").path))
    }
}

@Suite struct ExtensionMatchPatternTests {
    private func matches(_ pattern: String, _ url: String) -> Bool {
        ExtensionMatchPattern(pattern)?.matches(URL(string: url)!) ?? false
    }

    @Test func patternsMatchAsChromesDo() {
        #expect(matches("<all_urls>", "https://a.example/x"))
        #expect(matches("<all_urls>", "file:///tmp/x"))
        #expect(!matches("<all_urls>", "chrome-extension://abc/x"))
        #expect(matches("*://*/*", "http://a.example/"))
        #expect(!matches("*://*/*", "file:///tmp/x"), "* is http or https")
        #expect(matches("https://*.example.com/*", "https://example.com/a"))
        #expect(matches("https://*.example.com/*", "https://a.b.example.com/a?q=1"))
        #expect(!matches("https://*.example.com/*", "https://notexample.com/"))
        #expect(!matches("https://*.example.com/*", "http://example.com/"))
        #expect(matches("http://127.0.0.1/*", "http://127.0.0.1:8080/page"), "no port in the pattern: every port")
        #expect(!matches("http://127.0.0.1:9/*", "http://127.0.0.1:8080/page"))
        #expect(matches("https://example.com/a/*/c", "https://example.com/a/b/c"))
        #expect(!matches("https://example.com/a/*/c", "https://example.com/a/b/d"))
        #expect(ExtensionMatchPattern("https://a*.example.com/*") == nil, "a star only as the whole host or its first label")
        #expect(ExtensionMatchPattern("example.com") == nil)
    }
}

/// Cosmos's own matching of the filter lists' request rules, for profiles the blocker extension does not reach.
@Suite struct RequestRulesTests {
    private func filter(_ f: String, _ url: String, caseSensitive: Bool = false) -> Bool { URLFilter(f, caseSensitive: caseSensitive).matches(url) }

    @Test func urlFiltersMatchAsDeclarativeNetRequestsDo() {
        #expect(filter("||ads.example.com^", "https://ads.example.com/x.js"))
        #expect(filter("||ads.example.com^", "https://cdn.ads.example.com/x.js"), "a subdomain")
        #expect(!filter("||ads.example.com^", "https://badads.example.com/x.js"), "not merely ending the same")
        #expect(filter("||ads.example.com^", "https://ads.example.com"), "^ stands for the end too")
        #expect(!filter("||ads.example.com^", "https://ads.example.community/"))
        #expect(filter("/ad.js", "http://site.test/ad.js?v=1"))
        #expect(filter("/banner/*/img", "http://site.test/banner/a/b/img.png"))
        #expect(!filter("/banner/*/img", "http://site.test/banner/img.png"))
        #expect(filter("|https://", "https://a.test/"))
        #expect(!filter("|https://", "http://a.test/?https://"))
        #expect(filter(".swf|", "http://a.test/movie.swf"))
        #expect(!filter(".swf|", "http://a.test/movie.swf?x"))
        #expect(filter("&ad_box=", "http://a.test/?x=1&AD_BOX=2"), "case does not matter unless the rule says")
        #expect(!filter("&ad_box=", "http://a.test/?x=1&AD_BOX=2", caseSensitive: true))
        #expect(URLFilter("||ads.example.com^", caseSensitive: false).token == "example")
        #expect(URLFilter("ad", caseSensitive: false).token == nil)
    }

    private func list(_ rules: [[String: Any]]) -> CompiledBlockingList {
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return CompiledBlockingList(name: "t", json: String(decoding: data, as: UTF8.self), kind: .network, digest: "d")
    }

    /// Rules are made away from the main thread, a set at a time; a set made for an older change (a slower build) that
    /// finishes after a newer one does not replace it.
    @Test func olderRulesDoNotReplaceNewerOnes() {
        let holder = OwnRequestRules()
        let older = holder.nextGeneration(), newer = holder.nextGeneration()
        let blocking = RequestRules(lists: [list([["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "||tracker.test^"]]])], allowlist: [])
        holder.set(blocking, generation: newer)
        holder.set(nil, generation: older)
        #expect(holder.blocks(.init(url: "https://tracker.test/a.js", type: "script", initiator: nil, documents: [])))
    }

    @Test func theRuleOfHighestPriorityDecides() {
        let rules = RequestRules(lists: [list([
            ["priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "||tracker.test^"]],
            ["priority": 2, "action": ["type": "allow"], "condition": ["urlFilter": "||tracker.test/ok.js"]],
            ["priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "/ad.js", "resourceTypes": ["script"], "domainType": "thirdParty"]],
            ["priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "/only-here.js", "initiatorDomains": ["news.test"]]],
            ["priority": 3, "action": ["type": "allowAllRequests"], "condition": ["urlFilter": "||friendly.test^", "resourceTypes": ["main_frame", "sub_frame"]]],
        ])], allowlist: ["mine.test"])
        func blocks(_ url: String, _ type: String = "script", from initiator: String? = "https://news.test", in documents: [String] = ["https://news.test/"]) -> Bool {
            rules.blocks(.init(url: url, type: type, initiator: initiator, documents: documents))
        }
        #expect(blocks("https://tracker.test/t.js"))
        #expect(!blocks("https://tracker.test/ok.js"), "a higher allow")
        #expect(!blocks("https://tracker.test/", "main_frame", from: nil, in: []), "without resource types, not a page itself")
        #expect(blocks("https://cdn.test/ad.js"), "a third party's")
        #expect(!blocks("https://news.test/ad.js"), "the site's own")
        #expect(!blocks("https://cdn.test/ad.js", "image"), "another kind of request")
        #expect(blocks("https://cdn.test/only-here.js"))
        #expect(!blocks("https://cdn.test/only-here.js", from: "https://other.test", in: ["https://other.test/"]))
        #expect(!blocks("https://tracker.test/t.js", from: "https://friendly.test", in: ["https://friendly.test/"]), "a page excepted as a whole")
        #expect(!blocks("https://tracker.test/t.js", from: "https://a.mine.test", in: ["https://a.mine.test/"]), "the user's own allowed site")
        #expect(!blocks("https://tracker.test/t.js", from: "https://x.test", in: ["https://x.test/frame", "https://mine.test/"]), "a frame in an allowed site")
        #expect(rules.count == 6)
    }
}
