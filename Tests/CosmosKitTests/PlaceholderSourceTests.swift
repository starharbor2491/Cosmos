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
