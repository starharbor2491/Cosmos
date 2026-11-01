import AppKit
import Testing
@testable import CosmosKit

/// The Keyboard Shortcuts list and the Command Bar's hints say what the menus do: every chord they name that the menus
/// have is there, written the same way. (They once said ⇧⌘D for Favorites, which is ⌥⌘D.)
@MainActor
@Suite struct ShortcutTableTests {
    /// What the menus show for each item's shortcut, as the list writes it: ⌃⌥⇧⌘ then the key.
    private func menuChords() -> Set<String> {
        let menu = CosmosAppDelegate(options: LaunchOptions()).makeMainMenu()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let arrows: [Character: String] = [Character(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", Character(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
                                           Character(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", Character(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return Set(items(menu).compactMap { item in
            guard let key = item.keyEquivalent.first else { return nil }
            let m = item.keyEquivalentModifierMask
            let mods = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
            let glyph = arrows[key] ?? (key == "\t" ? "⇥" : String(key).uppercased())
            return mods + glyph
        })
    }

    /// The chords one entry names: "⌘[  ⌘]" is two, "⌘1–9" stands for ⌘1 and ⌘9.
    private func chords(_ keys: String) -> [String] {
        keys.components(separatedBy: "  ").flatMap { chord -> [String] in
            guard let dash = chord.firstIndex(of: "–") else { return [chord] }
            let head = chord[..<dash], last = chord[chord.index(after: dash)...]
            return [String(head), String(head.dropLast()) + last]
        }
    }

    @Test func everyChordInTheListIsTheMenusOwn() {
        let menus = menuChords()
        // These belong to the Command Bar's field, not to a menu.
        let field: Set<String> = ["⌘↩", "Tab", "esc"]
        for (_, entries) in ShortcutsPanel.groups {
            for entry in entries where !field.contains(entry.keys) {
                for chord in chords(entry.keys) {
                    #expect(menus.contains(chord), "“\(entry.what)”: \(chord) is not what the menus have")
                }
            }
        }
    }

    @Test func everyCommandsHintIsTheMenusOwn() {
        let menus = menuChords()
        for command in BrowserCommand.allCases {
            guard let hint = command.shortcut else { continue }
            #expect(menus.contains(hint), "\(command): \(hint) is not what the menus have")
        }
    }
}
