import Foundation
import Testing
@testable import CosmosKit

/// Every animation in the interface comes from `Motion`, which stands down under Reduce Motion. A raw
/// `.animation(.easeOut…)` or `withAnimation(.spring…)` would keep moving for someone who asked it not to.
@Suite struct MotionSourceTests {
    static let rawAnimation = #"(\.animation\(\s*\.|withAnimation\s*\{|withAnimation\(\s*\.|\.animation\(\s*Animation)"#

    static func rawUses(in text: String, file: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: rawAnimation)
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { return nil }
            return "\(file):\(index + 1)"
        }
    }

    @Test func noViewAnimatesWithoutGoingThroughMotion() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CosmosKit", isDirectory: true)
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            offenders += try Self.rawUses(in: String(contentsOf: url, encoding: .utf8), file: url.lastPathComponent)
        }
        #expect(scanned > 40, "expected the CosmosKit sources at \(sources.path)")
        #expect(offenders.isEmpty, "animations that ignore Reduce Motion: \(offenders.joined(separator: ", "))")
    }

    @Test func theScanSeesWhatItLooksFor() throws {
        let bad = """
        view.animation(.easeOut(duration: 0.2), value: x)
        withAnimation { y.toggle() }
        withAnimation(.spring()) { z = 1 }
        view.animation(Motion.quick, value: x)
        withAnimation(Motion.standard) { y.toggle() }
        // withAnimation { commented }
        """
        #expect(try Self.rawUses(in: bad, file: "V.swift") == ["V.swift:1", "V.swift:2", "V.swift:3"])
    }
}
