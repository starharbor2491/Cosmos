import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The Settings window draws every control itself. This keeps it that way: no source file under Settings/ may use a
/// system button, switch, picker, form, tab view, list, text field, alert or menu.
@Suite struct NoSystemControlsInSettingsTests {
    private static let forbidden: [(name: String, pattern: String)] = [
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

    @Test func settingsSourcesUseNoSystemControls() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CosmosKit/Settings", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5, "expected the settings sources at \(sources.path)")
        let patterns = try Self.forbidden.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let range = NSRange(code.startIndex..., in: code)
                for (name, regex) in patterns where regex.firstMatch(in: code, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1) uses \(name)")
                }
            }
        }
        #expect(offenders.isEmpty, "system controls in Settings: \(offenders.joined(separator: "; "))")
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
