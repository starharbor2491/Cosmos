import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The Settings window draws every control itself. This keeps it that way: no source file under Settings/ may use a
/// system button, switch, picker, form, tab view, list, text field, alert, menu, tooltip or colour/date picker.
/// Two things cannot be drawn by Cosmos and are allowed in exactly one file each: the text-editing engine inside the
/// text field (an AppKit field with no chrome, so typing, selection and input methods work) and the file chooser that
/// picks an extension folder.
@Suite struct NoSystemControlsInSettingsTests {
    private static let allowed: [String: Set<String>] = [
        "NSTextField": ["SettingsControls.swift"], "NSTextView": ["SettingsControls.swift"], "NSTextFieldDelegate": ["SettingsControls.swift"],
        "NSOpenPanel": ["ExtensionsPane.swift"],
    ]

    private static let forbidden: [(name: String, pattern: String)] = [
        ("ColorPicker", #"\bColorPicker\b"#), ("DatePicker", #"\bDatePicker\b"#), ("Table", #"(?<![A-Za-z_])Table\s*[({]"#),
        ("contextMenu", #"\.contextMenu"#), ("fileImporter", #"\.file(Importer|Exporter|Mover)"#), ("help tooltip", #"\.help\s*\("#),
        ("NSOpenPanel", #"\bNSOpenPanel\b"#), ("NSSavePanel", #"\bNSSavePanel\b"#), ("NSColorPanel", #"\bNSColorPanel\b"#),
        ("NSTextField", #"\bNSTextField\b"#), ("NSTextView", #"\bNSTextView\b"#), ("NSTextFieldDelegate", #"\bNSTextFieldDelegate\b"#),
        ("Gauge", #"\bGauge\s*[({]"#), ("NavigationStack", #"\bNavigation(Stack|SplitView|View)\b"#), ("toolbar", #"\.toolbar\s*[({]"#),
        ("NSSegmentedControl", #"\bNSSegmentedControl\b"#), ("NSPopover", #"\bNSPopover\b"#), ("NSMenu", #"\bNSMenu\b"#),
        ("Toggle", #"\bToggle\s*[({]"#), ("Picker", #"\bPicker\s*[({]"#), ("Form", #"\bForm\s*[({]"#), ("TabView", #"\bTabView\b"#),
        ("List", #"\bList\s*[({]"#), ("Button", #"(?<![A-Za-z_])Button\s*[({]"#), ("TextField", #"\bTextField\s*[({]"#),
        ("SecureField", #"\bSecureField\b"#), ("TextEditor", #"\bTextEditor\b"#), ("Slider", #"\bSlider\s*[({]"#),
        ("Stepper", #"\bStepper\s*[({]"#), ("Menu", #"(?<![A-Za-z_])Menu\s*[({]"#), ("ProgressView", #"\bProgressView\b"#),
        ("Section", #"(?<![A-Za-z_])Section\s*[({]"#), ("formStyle", #"\.formStyle"#), ("buttonStyle", #"\.buttonStyle"#),
        ("toggleStyle", #"\.toggleStyle"#), ("pickerStyle", #"\.pickerStyle"#), ("menuStyle", #"\.menuStyle"#),
        ("NSAlert", #"\bNSAlert\b"#), ("DisclosureGroup", #"\bDisclosureGroup\b"#), ("GroupBox", #"\bGroupBox\b"#),
        ("Link", #"(?<![A-Za-z_])Link\s*\("#), ("Divider", #"\bDivider\s*\("#), ("LabeledContent", #"\bLabeledContent\b"#),
        ("alert", #"\.alert\s*\("#), ("confirmationDialog", #"\.confirmationDialog"#), ("sheet", #"\.sheet\s*\("#),
        ("popover", #"\.popover\s*\("#), ("NSPopUpButton", #"\bNSPopUpButton\b"#), ("NSButton", #"\bNSButton\b"#), ("NSSwitch", #"\bNSSwitch\b"#),
    ]

    /// Every forbidden use in `text`, as "file:line uses Name".
    static func violations(in text: String, file: String) throws -> [String] {
        let patterns = try forbidden.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var found: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            let range = NSRange(code.startIndex..., in: code)
            for (name, regex) in patterns where regex.firstMatch(in: code, range: range) != nil {
                if allowed[name]?.contains(file) == true { continue }
                found.append("\(file):\(index + 1) uses \(name)")
            }
        }
        return found
    }

    @Test func settingsSourcesUseNoSystemControls() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CosmosKit/Settings", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5, "expected the settings sources at \(sources.path)")
        var offenders: [String] = []
        for file in files {
            offenders += try Self.violations(in: String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        #expect(offenders.isEmpty, "system controls in Settings: \(offenders.joined(separator: "; "))")
    }

    @Test func theScanFindsWhatItLooksFor() throws {
        let bad = """
        Toggle("x", isOn: $a)
        Text("y").help("tooltip")
        ColorPicker("c", selection: $c)
        let f = NSTextField()
        // Button { } is only a comment
        """
        let found = try Self.violations(in: bad, file: "SomePane.swift")
        #expect(found == ["SomePane.swift:1 uses Toggle", "SomePane.swift:2 uses help tooltip", "SomePane.swift:3 uses ColorPicker", "SomePane.swift:4 uses NSTextField"])
    }

    @Test func theTwoAllowedSystemPiecesStayInTheirOwnFiles() throws {
        #expect(try Self.violations(in: "let f = NSTextField()", file: "SettingsControls.swift").isEmpty)
        #expect(try Self.violations(in: "let f = NSTextField()", file: "GeneralPane.swift").count == 1)
        #expect(try Self.violations(in: "let p = NSOpenPanel()", file: "ExtensionsPane.swift").isEmpty)
        #expect(try Self.violations(in: "let p = NSOpenPanel()", file: "SettingsPanes.swift").count == 1)
    }
}

@MainActor
@Suite struct SettingsDialogTests {
    private func waitForDialog(_ model: SettingsModel) async {
        for _ in 0..<200 where model.dialog == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aConfirmationResolvesWithTheAnswer() async {
        let model = SettingsModel()
        let answer = Task { await model.confirm(.init(title: "Clear?", message: "Sure?", confirmTitle: "Clear")) }
        await waitForDialog(model)
        #expect(model.dialog?.title == "Clear?")
        model.resolve(true)
        #expect(await answer.value)
        #expect(model.dialog == nil)

        let no = Task { await model.confirm(.init(title: "Again", message: "", confirmTitle: "Yes")) }
        await waitForDialog(model)
        model.resolve(false)
        #expect(await no.value == false)
    }

    @Test func aNewQuestionCancelsTheOneStillOpen() async {
        let model = SettingsModel()
        let first = Task { await model.confirm(.init(title: "First", message: "", confirmTitle: "OK")) }
        await waitForDialog(model)
        let second = Task { await model.confirm(.init(title: "Second", message: "", confirmTitle: "OK")) }
        #expect(await first.value == false, "the superseded question must not hang")
        for _ in 0..<200 where model.dialog?.title != "Second" { try? await Task.sleep(for: .milliseconds(5)) }
        model.resolve(true)
        #expect(await second.value)
    }

    @Test func resolvingWithNothingOpenIsHarmless() {
        let model = SettingsModel()
        model.resolve(true)
        #expect(model.dialog == nil)
    }
}

@Suite struct SitePermissionTests {
    @Test func aStoredDecisionKeyBecomesASiteAndAKind() throws {
        let p = try #require(SitePermission(key: "meet.example.com|cameraAndMicrophone", allowed: true))
        #expect(p.host == "meet.example.com")
        #expect(p.name == "Camera & microphone")
        #expect(p.allowed)
        #expect(SitePermission(key: "example.com|location", allowed: false)?.name == "Location")
        #expect(SitePermission(key: "a.com|midi", allowed: true)?.name == "Midi")
    }

    @Test func malformedKeysAreSkippedNotCrashed() {
        #expect(SitePermission(key: "", allowed: true) == nil)
        #expect(SitePermission(key: "nobar", allowed: true) == nil)
        #expect(SitePermission(key: "|camera", allowed: true) == nil)
    }

    @Test func permissionsAreListedBySiteThenKind() {
        let list = SitePermission.list(from: ["b.com|camera": true, "a.com|microphone": false, "a.com|camera": true, "junk": true])
        #expect(list.map(\.key) == ["a.com|camera", "a.com|microphone", "b.com|camera"])
    }
}

@MainActor
@Suite struct SettingsTabTests {
    @Test func everyTabHasATitleAndAnIcon() {
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbol.isEmpty)
        }
        #expect(SettingsTab.allCases.first == .general)
        #expect(SettingsTab(rawValue: "blocking") == .blocking, "automation and links address tabs by name")
    }
}

@Suite struct ScrollEdgesTests {
    @Test func contentThatFitsFadesNowhere() {
        let edges = ScrollEdges(offset: 0, contentHeight: 300, viewport: 400)
        #expect(edges.top == 1 && edges.bottom == 1, "1 means the edge is solid")
    }

    @Test func atTheTopOnlyTheBottomFades() {
        let edges = ScrollEdges(offset: 0, contentHeight: 1000, viewport: 400)
        #expect(edges.top == 1)
        #expect(edges.bottom == 0)
    }

    @Test func inTheMiddleBothEdgesFade() {
        let edges = ScrollEdges(offset: 300, contentHeight: 1000, viewport: 400)
        #expect(edges.top == 0 && edges.bottom == 0)
    }

    @Test func atTheEndOnlyTheTopFades() {
        let edges = ScrollEdges(offset: 600, contentHeight: 1000, viewport: 400)
        #expect(edges.top == 0)
        #expect(edges.bottom == 1)
    }

    @Test func theFadeGrowsAsYouApproachAnEdge() {
        let half = ScrollEdges(offset: 12, contentHeight: 1000, viewport: 400, fade: 24)
        #expect(abs(half.top - 0.5) < 0.001)
        let nearEnd = ScrollEdges(offset: 588, contentHeight: 1000, viewport: 400, fade: 24)
        #expect(abs(nearEnd.bottom - 0.5) < 0.001)
    }

    @Test func overscrollAndUnmeasuredSizesStayInRange() {
        for edges in [ScrollEdges(offset: -50, contentHeight: 1000, viewport: 400), ScrollEdges(offset: 5000, contentHeight: 1000, viewport: 400),
                      ScrollEdges(offset: 0, contentHeight: 0, viewport: 0)] {
            #expect((0...1).contains(edges.top) && (0...1).contains(edges.bottom))
        }
    }
}

/// Settings has no overlays of its own: "Show Welcome" has to show it in a browser window, in front of Settings.
@MainActor
@Suite struct PresentOverlayTests {
    @Test func theAppIsAskedToShowItWhenItHasAHook() {
        let rig = Rig(seed: true)
        var shown: [Overlay] = []
        rig.store.onPresent = { shown.append($0) }
        rig.store.present(.welcome)
        #expect(shown == [.welcome])
        #expect(rig.window.overlay == nil)
    }

    @Test func withoutAHookTheActiveWindowShowsIt() {
        let rig = Rig(seed: true)
        rig.store.activeWindow = rig.window
        rig.store.present(.welcome)
        #expect(rig.window.overlay == .welcome)
    }
}

/// The Welcome screen's main button says what it does: "Start Fresh" before anything is brought over, "Start Exploring"
/// after, and "Done" when Welcome is being looked at again after setup.
@Suite struct WelcomeTitleTests {
    @Test func firstRunWithNothingImportedStartsFresh() {
        #expect(WelcomeView.doneTitle(imported: false, setUpBefore: false) == "Start Fresh")
    }

    @Test func firstRunAfterAnImportStartsExploring() {
        #expect(WelcomeView.doneTitle(imported: true, setUpBefore: false) == "Start Exploring")
    }

    @Test func openedAgainLaterItIsJustDone() {
        #expect(WelcomeView.doneTitle(imported: false, setUpBefore: true) == "Done")
        #expect(WelcomeView.doneTitle(imported: true, setUpBefore: true) == "Done")
    }
}
