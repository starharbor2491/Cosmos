import Foundation
import Testing
@testable import CosmosKit

/// The system draws a text field's placeholder in a fixed grey (about 1.2:1 on a themed panel). Fields in the interface
/// draw their own prompt in the palette's hint colour (`PromptTextField`, or `placeholderAttributedString`).
@Suite struct PlaceholderSourceTests {
    static let pattern = #"(TextField\(\s*"[^"]+"|\.placeholderString\s*=|\.prompt\s*:)"#

    static func offences(in text: String, file: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.contains("in a system alert"), regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { return nil }
            return "\(file):\(index + 1)"
        }
    }

    @Test func noFieldInTheInterfaceUsesTheSystemPlaceholder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for folder in ["Sources/CosmosKit/UI", "Sources/CosmosKit/Settings"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                scanned += 1
                offenders += try Self.offences(in: String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
            }
        }
        #expect(scanned > 30)
        #expect(offenders.isEmpty, "system placeholders: \(offenders.joined(separator: ", "))")
    }

    /// A native field paints its placeholder solid whatever alpha the colour has (a translucent hint came out as dark as
    /// typed text), so whoever hands it one must pass `palette.placeholder`, which is already mixed with the ground.
    static func translucentHints(in text: String, file: String) -> [String] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), code.contains("placeholderColor:"), !code.contains("let placeholderColor"), !code.contains("palette.placeholder") else { return nil }
            return "\(file):\(index + 1)"
        }
    }

    @Test func nativeFieldsAreGivenASolidHintColour() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var withHints = 0
        for folder in ["Sources/CosmosKit/UI", "Sources/CosmosKit/Settings"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("placeholderColor") { withHints += 1 }
                offenders += Self.translucentHints(in: text, file: file.lastPathComponent)
            }
        }
        #expect(withHints >= 3, "the Command Bar, Find and Settings fields should have been found")
        #expect(offenders.isEmpty, "hint colours that are not palette.placeholder: \(offenders.joined(separator: ", "))")
    }

    @Test func theHintScanSeesWhatItLooksFor() {
        let bad = """
        FindField(text: $t, placeholderColor: NSColor(palette.tertiary),
        CommandField(placeholderColor: NSColor.white.withAlphaComponent(0.4))
        FindField(text: $t, placeholderColor: NSColor(palette.placeholder),
        let placeholderColor: NSColor
        // placeholderColor: NSColor.red
        """
        #expect(Self.translucentHints(in: bad, file: "V.swift") == ["V.swift:1", "V.swift:2"])
    }

    @Test func theScanSeesWhatItLooksFor() throws {
        let bad = """
        TextField("Name", text: $name)
        field.placeholderString = "Find"
        TextField("", text: $text)
        // TextField("Commented", text: $x)
        """
        #expect(try Self.offences(in: bad, file: "V.swift") == ["V.swift:1", "V.swift:2"])
    }
}
