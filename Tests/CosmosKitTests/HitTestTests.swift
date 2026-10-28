import AppKit
import Foundation
import Testing
@testable import CosmosKit

/// A view that sits behind the interface to watch for keys fills the window, and an AppKit view in front of SwiftUI's own
/// drawing takes every click for itself unless it says it is not there. One that does not makes the whole window deaf: the
/// pointer moves, a row shrinks under the press, and nothing is chosen.
@MainActor
@Suite struct HitTestTests {
    /// Views that are meant to be clicked or dragged.
    static let meantToBeHit: Set<String> = ["WebContentHostView", "PaneContainer", "DividerView", "DragView", "RuntimeHostView"]

    @Test func everyBackgroundViewLetsClicksThrough() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let regex = try NSRegularExpression(pattern: #"final class (\w+): NSView"#)
        var offenders: [String] = []
        var seen = 0
        for folder in ["Sources/CosmosKit/UI", "Sources/CosmosKit/Settings"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for (index, match) in matches.enumerated() {
                    seen += 1
                    let name = String(text[Range(match.range(at: 1), in: text)!])
                    // The class runs to the next one (or the end of the file).
                    let start = text.index(text.startIndex, offsetBy: match.range.location)
                    let end = index + 1 < matches.count ? text.index(text.startIndex, offsetBy: matches[index + 1].range.location) : text.endIndex
                    if !Self.meantToBeHit.contains(name), !text[start..<end].contains("override func hitTest") { offenders.append("\(file.lastPathComponent): \(name)") }
                }
            }
        }
        #expect(seen >= 8, "the scan should have found the interface's own views")
        #expect(offenders.isEmpty, "background views that take clicks: \(offenders.joined(separator: ", "))")
    }

    private func hit(_ view: NSView) -> NSView? {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.frame = container.bounds
        container.addSubview(view)
        return container.hitTest(NSPoint(x: 50, y: 50))
    }

    @Test func theEscapeCatcherBehindTheWindowTakesNoClicks() {
        let catcher = OverlayEscapeCatcher.CatcherView()
        #expect(hit(catcher) !== catcher)
    }

    @Test func theKeyCatcherBehindAPeekTakesNoClicks() {
        let catcher = PeekKeyCatcher.CatcherView()
        #expect(hit(catcher) !== catcher)
    }
}
