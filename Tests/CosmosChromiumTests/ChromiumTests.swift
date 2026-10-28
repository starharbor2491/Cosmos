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

@Suite struct ChromiumProcessTests {
    /// Chromium is driven over a pipe only Cosmos holds: no debugging port that anything else on the Mac could reach.
    @Test func chromiumRunsHeadlessOverAPipeWithItsOwnData() {
        let args = ChromiumProcess.arguments(userDataDirectory: URL(fileURLWithPath: "/tmp/profile"), extraFlags: ["--disable-gpu"])
        #expect(args.contains("--headless"))
        #expect(args.contains("--remote-debugging-pipe"))
        #expect(!args.contains { $0.hasPrefix("--remote-debugging-port") })
        #expect(args.contains("--user-data-dir=/tmp/profile"))
        #expect(args.contains("--disable-gpu"))
        #expect(args.last == "about:blank")
    }

    /// Chromium picks its crash folder before it reads `--user-data-dir`, so without this it writes into the Chromium
    /// folder of the Mac's own Library.
    @Test func crashReportsStayInTheProfile() {
        let env = ChromiumProcess.environment(userDataDirectory: URL(fileURLWithPath: "/tmp/profile"),
                                              inherited: ["HOME": "/Users/x", "BREAKPAD_DUMP_LOCATION": "/elsewhere"])
        #expect(env.contains("BREAKPAD_DUMP_LOCATION=/tmp/profile/Crashpad"))
        #expect(env.filter { $0.hasPrefix("BREAKPAD_DUMP_LOCATION=") }.count == 1)
        #expect(env.contains("HOME=/Users/x"))
    }
}

@Suite struct ChromiumUpdatePolicyTests {
    private func state(current: Int? = nil, previous: Int? = nil, bad: [Int] = [], lastCheck: Date? = nil) -> ChromiumInstallState {
        var s = ChromiumInstallState()
        s.current = current; s.previous = previous; s.bad = bad; s.lastCheck = lastCheck
        return s
    }

    @Test func itLooksOnceADayAndAfterTheClockWentBack() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ChromiumUpdatePolicy.isCheckDue(state(), now: now))
        #expect(!ChromiumUpdatePolicy.isCheckDue(state(lastCheck: now.addingTimeInterval(-3600)), now: now))
        #expect(ChromiumUpdatePolicy.isCheckDue(state(lastCheck: now.addingTimeInterval(-25 * 3600)), now: now))
        #expect(ChromiumUpdatePolicy.isCheckDue(state(lastCheck: now.addingTimeInterval(3600)), now: now), "a check dated in the future")
    }

    @Test func onlyANewerSnapshotThatHasNotFailedIsFetched() {
        #expect(ChromiumUpdatePolicy.shouldInstall(latest: 100, state: state()))
        #expect(ChromiumUpdatePolicy.shouldInstall(latest: 101, state: state(current: 100)))
        #expect(!ChromiumUpdatePolicy.shouldInstall(latest: 100, state: state(current: 100)))
        #expect(!ChromiumUpdatePolicy.shouldInstall(latest: 99, state: state(current: 100)))
        #expect(!ChromiumUpdatePolicy.shouldInstall(latest: 101, state: state(current: 100, bad: [101])))
    }

    /// A new snapshot that started becomes current and the old one is kept; one that stops starting goes back to it for
    /// good.
    @Test func aNewSnapshotIsKeptOnlyWhileItStarts() {
        let promoted = ChromiumUpdatePolicy.promoted(101, in: state(current: 100, previous: 99))
        #expect(promoted.current == 101 && promoted.previous == 100)
        #expect(ChromiumUpdatePolicy.removable(installed: [98, 99, 100, 101], state: promoted) == [98, 99])

        let rolledBack = ChromiumUpdatePolicy.rolledBack(promoted)
        #expect(rolledBack.current == 100 && rolledBack.previous == nil)
        #expect(rolledBack.bad == [101])
        #expect(!ChromiumUpdatePolicy.shouldInstall(latest: 101, state: rolledBack), "a snapshot that failed is not fetched again")

        let first = ChromiumUpdatePolicy.promoted(100, in: state())
        #expect(first.current == 100 && first.previous == nil)
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
        let p = ChromiumPreferences.preferences(s, defaultZoom: 2, system: [])
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
        #expect(abs(pow(1.2, zoom) - 2) < 1e-9, "Chromium counts zoom in steps of 20%")
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

    /// Headless Chromium calls itself HeadlessChrome, which some sites turn away; Cosmos gives the regular desktop one.
    @Test func sitesSeeARegularChromeUserAgent() {
        let ua = ChromiumPreferences.userAgent(chromiumVersion: "159.0.8129.0")
        #expect(ua.contains("Chrome/159.0.0.0"))
        #expect(!ua.contains("Headless"))
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
    /// AppKit hands out some standard cursors (`iBeam`) only once there is an application, as there always is in Cosmos;
    /// without one they are nil, and comparing them traps.
    init() { _ = NSApplication.shared }

    /// Files, links and text dragged in from other apps go to the page. A drag that started in Cosmos (a sidebar tab)
    /// never does, so a tab dragged over the page cannot land in it.
    @Test func thePageTakesWhatOtherAppsDropButNotSidebarTabs() throws {
        #expect(ChromiumPageView(frame: .zero).registeredDraggedTypes.contains(.fileURL))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cosmos-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/notes.txt") as NSURL])
        let files = try #require(ChromiumPageView.dragData(from: pasteboard, fromInsideCosmos: false))
        #expect(files["files"] as? [String] == ["/tmp/notes.txt"])
        #expect(ChromiumPageView.dragData(from: pasteboard, fromInsideCosmos: true) == nil)
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let text = try #require(ChromiumPageView.dragData(from: pasteboard, fromInsideCosmos: false))
        #expect((text["items"] as? [[String: Any]])?.first?["data"] as? String == "hello")
        #expect((text["items"] as? [[String: Any]])?.first?["mimeType"] as? String == "text/plain")
    }

    /// A menu from the keyboard's menu key is not tied to a click from half a minute ago.
    @Test func aRightClickCountsForTheMenuOnlyForAMoment() throws {
        let view = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let now = ProcessInfo.processInfo.systemUptime
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 9, y: 9), modifierFlags: .option, timestamp: now,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: event)
        #expect(view.recentContextClick(now: now + 0.5)?.location == NSPoint(x: 9, y: 9))
        #expect(view.recentContextClick(now: now + 0.5)?.modifiers == .option)
        #expect(view.recentContextClick(now: now + 30) == nil)
    }

    @Test func pageCursorsBecomeMacCursors() {
        #expect(ChromiumPageView.cursor(forCSS: "pointer") == .pointingHand)
        #expect(ChromiumPageView.cursor(forCSS: "text") == .iBeam)
        #expect(ChromiumPageView.cursor(forCSS: "col-resize") == .resizeLeftRight)
        #expect(ChromiumPageView.cursor(forCSS: "something-new") == .arrow)
    }

    @Test func modifierKeysBecomeChromiumsBits() {
        #expect(ChromiumPageView.modifiers([.command, .shift]) == 4 | 8)
        #expect(ChromiumPageView.modifiers([.option, .control]) == 1 | 2)
        #expect(ChromiumPageView.modifiers([.capsLock]) == 0)
    }
}

/// What VoiceOver reads: Chromium's accessibility tree of a page, as Cosmos hands it to AppKit.
@Suite struct ChromiumAccessibilityTests {
    private func node(_ id: String, _ role: String, _ name: String = "", parent: String? = nil, children: [String] = [], ignored: Bool = false,
                      backend: Int? = nil, properties: [[String: Any]] = []) -> [String: Any] {
        var n: [String: Any] = ["nodeId": id, "ignored": ignored, "role": ["type": "role", "value": role],
                                "name": ["type": "computedString", "value": name], "childIds": children, "properties": properties]
        if let parent { n["parentId"] = parent }
        if let backend { n["backendDOMNodeId"] = backend }
        return n
    }

    /// Nodes no one reads (ignored ones, wrappers without a name, the boxes text is laid out in) are left out, and what
    /// they held moves up to their parent.
    @Test func whatIsNotReadIsLeftOutAndWhatItHeldMovesUp() throws {
        let nodes: [[String: Any]] = [
            node("1", "RootWebArea", "Test page", children: ["2"], backend: 1),
            node("2", "none", parent: "1", children: ["3", "4", "7"], ignored: true),
            node("3", "heading", "Welcome", parent: "2", children: ["5"], backend: 10, properties: [["name": "level", "value": ["type": "integer", "value": 2]]]),
            node("5", "StaticText", "Welcome", parent: "3", children: ["6"], backend: 11),
            node("6", "InlineTextBox", "Welcome", parent: "5"),
            node("4", "generic", parent: "2", children: ["8"]),
            node("8", "link", "More", parent: "4", backend: 12, properties: [
                ["name": "url", "value": ["type": "string", "value": "https://example.com/more"]],
                ["name": "focusable", "value": ["type": "booleanOrUndefined", "value": true]],
            ]),
            node("7", "button", "Press", parent: "2", backend: 13, properties: [["name": "disabled", "value": ["type": "boolean", "value": true]]]),
        ]
        let root = try #require(AXPageNode.tree(nodes))
        #expect(root.role == "RootWebArea" && root.name == "Test page")
        #expect(root.children.map(\.role) == ["heading", "link", "button"])
        let heading = root.children[0]
        #expect(heading.properties["level"] == "2")
        #expect(heading.children.map(\.role) == ["StaticText"])
        #expect(heading.children[0].children.isEmpty, "text boxes are left out")
        #expect(root.children[1].properties["url"] == "https://example.com/more")
        #expect(root.children[1].properties["focusable"] == "true")
        #expect(root.children[2].properties["disabled"] == "true")
        #expect(root.children[2].backendNodeID == 13)
    }

    /// Chromium's roles become the ones VoiceOver knows on the Mac, landmarks included.
    @Test func chromiumsRolesBecomeTheMacsOwn() {
        func role(_ r: String, _ properties: [String: String] = [:]) -> (NSAccessibility.Role, NSAccessibility.Subrole?) {
            let mac = AXPageNode(id: "1", role: r, name: "", properties: properties).macRole
            return (mac.role, mac.subrole)
        }
        #expect(role("RootWebArea").0.rawValue == "AXWebArea")
        #expect(role("heading").0.rawValue == "AXHeading")
        #expect(role("link").0 == .link)
        #expect(role("button").0 == .button)
        #expect(role("StaticText").0 == .staticText)
        #expect(role("image").0 == .image)
        #expect(role("textbox").0 == .textField)
        #expect(role("textbox", ["multiline": "true"]).0 == .textArea)
        #expect(role("checkbox").0 == .checkBox)
        #expect(role("navigation").0 == .group && role("navigation").1?.rawValue == "AXLandmarkNavigation")
        #expect(role("main").1?.rawValue == "AXLandmarkMain")
        #expect(role("somethingNew").0 == .group)
    }
}

@Suite struct KeyMappingTests {
    @Test func keysHaveTheirPhysicalCodeAndWindowsNumber() {
        #expect(KeyMapping.keys[0x00] == KeyMapping.Key(code: "KeyA", windowsCode: 65, named: nil))
        #expect(KeyMapping.keys[0x12] == KeyMapping.Key(code: "Digit1", windowsCode: 49, named: nil))
        #expect(KeyMapping.keys[0x24]?.named == "Enter")
        #expect(KeyMapping.keys[0x7B]?.code == "ArrowLeft")
        #expect(KeyMapping.keys[0x35]?.windowsCode == 27)
    }

    @Test func theDOMKeyIsTheNameOrWhatWasTyped() {
        #expect(KeyMapping.domKey(keyCode: 0x24, characters: "\r", ignoringModifiers: "\r", control: false) == "Enter")
        #expect(KeyMapping.domKey(keyCode: 0x00, characters: "a", ignoringModifiers: "a", control: false) == "a")
        #expect(KeyMapping.domKey(keyCode: 0x00, characters: "å", ignoringModifiers: "a", control: false) == "å", "⌥ typed a letter of its own")
        #expect(KeyMapping.domKey(keyCode: 0x00, characters: "\u{1}", ignoringModifiers: "a", control: true) == "a", "⌃A is the A key")
        #expect(KeyMapping.domKey(keyCode: 0x200, characters: nil, ignoringModifiers: nil, control: false) == "Unidentified")
    }

    @Test func onlyEditingCommandsGoToChromium() {
        #expect(KeyMapping.commands(fromSelectors: ["deleteBackward:", "insertTab:", "moveWordLeft:", "noop:"]) == ["deleteBackward", "moveWordLeft"])
    }
}
