import Foundation

/// Turns a Mac key press into the fields of `Input.dispatchKeyEvent`. Pure, so it can be tested without a keyboard.
enum KeyMapping {
    struct Key: Equatable {
        /// DOM `code` (`KeyA`, `ArrowLeft`): the physical key.
        var code: String
        /// Windows virtual key code, which `KeyboardEvent.keyCode` reports.
        var windowsCode: Int
        /// DOM `key` for keys that have a name rather than a character (`Enter`, `Shift`); nil for character keys.
        var named: String?
    }

    /// macOS virtual key codes (`kVK_*`), US layout positions.
    static let keys: [UInt16: Key] = {
        var k: [UInt16: Key] = [:]
        let letters: [(UInt16, Character)] = [(0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"), (0x04, "H"), (0x05, "G"), (0x06, "Z"), (0x07, "X"),
                                              (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"), (0x0D, "W"), (0x0E, "E"), (0x0F, "R"), (0x10, "Y"),
                                              (0x11, "T"), (0x1F, "O"), (0x20, "U"), (0x22, "I"), (0x23, "P"), (0x25, "L"), (0x26, "J"), (0x28, "K"),
                                              (0x2D, "N"), (0x2E, "M")]
        for (code, letter) in letters { k[code] = Key(code: "Key\(letter)", windowsCode: Int(letter.asciiValue!), named: nil) }
        let digits: [(UInt16, Int)] = [(0x1D, 0), (0x12, 1), (0x13, 2), (0x14, 3), (0x15, 4), (0x17, 5), (0x16, 6), (0x1A, 7), (0x1C, 8), (0x19, 9)]
        for (code, d) in digits { k[code] = Key(code: "Digit\(d)", windowsCode: 48 + d, named: nil) }
        let pad: [(UInt16, Int)] = [(0x52, 0), (0x53, 1), (0x54, 2), (0x55, 3), (0x56, 4), (0x57, 5), (0x58, 6), (0x59, 7), (0x5B, 8), (0x5C, 9)]
        for (code, d) in pad { k[code] = Key(code: "Numpad\(d)", windowsCode: 96 + d, named: nil) }
        let punctuation: [(UInt16, String, Int)] = [(0x18, "Equal", 187), (0x1B, "Minus", 189), (0x1E, "BracketRight", 221), (0x21, "BracketLeft", 219),
                                                    (0x27, "Quote", 222), (0x29, "Semicolon", 186), (0x2A, "Backslash", 220), (0x2B, "Comma", 188),
                                                    (0x2C, "Slash", 191), (0x2F, "Period", 190), (0x32, "Backquote", 192), (0x0A, "IntlBackslash", 226),
                                                    (0x31, "Space", 32), (0x41, "NumpadDecimal", 110), (0x43, "NumpadMultiply", 106),
                                                    (0x45, "NumpadAdd", 107), (0x4B, "NumpadDivide", 111), (0x4E, "NumpadSubtract", 109),
                                                    (0x51, "NumpadEqual", 187)]
        for (code, name, vk) in punctuation { k[code] = Key(code: name, windowsCode: vk, named: nil) }
        let named: [(UInt16, String, Int, String)] = [
            (0x24, "Enter", 13, "Enter"), (0x4C, "NumpadEnter", 13, "Enter"), (0x30, "Tab", 9, "Tab"), (0x33, "Backspace", 8, "Backspace"),
            (0x35, "Escape", 27, "Escape"), (0x75, "Delete", 46, "Delete"), (0x72, "Insert", 45, "Insert"), (0x73, "Home", 36, "Home"),
            (0x77, "End", 35, "End"), (0x74, "PageUp", 33, "PageUp"), (0x79, "PageDown", 34, "PageDown"),
            (0x7B, "ArrowLeft", 37, "ArrowLeft"), (0x7C, "ArrowRight", 39, "ArrowRight"), (0x7D, "ArrowDown", 40, "ArrowDown"),
            (0x7E, "ArrowUp", 38, "ArrowUp"), (0x47, "NumLock", 12, "Clear"),
            (0x38, "ShiftLeft", 16, "Shift"), (0x3C, "ShiftRight", 16, "Shift"), (0x3B, "ControlLeft", 17, "Control"),
            (0x3E, "ControlRight", 17, "Control"), (0x3A, "AltLeft", 18, "Alt"), (0x3D, "AltRight", 18, "Alt"),
            (0x37, "MetaLeft", 91, "Meta"), (0x36, "MetaRight", 93, "Meta"), (0x39, "CapsLock", 20, "CapsLock"),
            (0x7A, "F1", 112, "F1"), (0x78, "F2", 113, "F2"), (0x63, "F3", 114, "F3"), (0x76, "F4", 115, "F4"), (0x60, "F5", 116, "F5"),
            (0x61, "F6", 117, "F6"), (0x62, "F7", 118, "F7"), (0x64, "F8", 119, "F8"), (0x65, "F9", 120, "F9"), (0x6D, "F10", 121, "F10"),
            (0x67, "F11", 122, "F11"), (0x6F, "F12", 123, "F12"),
        ]
        for (code, name, vk, key) in named { k[code] = Key(code: name, windowsCode: vk, named: key) }
        return k
    }()

    /// CDP's modifier bits.
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let alt = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let meta = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    /// The DOM `key` for a press: the key's name, or the character it typed. With Control held the Mac reports a control
    /// character, so the character without modifiers is used instead.
    static func domKey(keyCode: UInt16, characters: String?, ignoringModifiers: String?, control: Bool) -> String {
        if let named = keys[keyCode]?.named { return named }
        let typed = characters ?? ""
        if control || typed.isEmpty || typed.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
            return ignoringModifiers?.isEmpty == false ? ignoringModifiers! : "Unidentified"
        }
        return typed
    }

    /// The editing commands Chromium should run for what the Mac's key bindings asked for (`deleteBackward:` ...). Tab and
    /// Escape are left to the page's own key handling, which Chromium does by itself.
    static func commands(fromSelectors selectors: [String]) -> [String] {
        let ignored: Set<String> = ["noop", "insertTab", "insertBacktab", "cancelOperation", "insertText", "complete"]
        return selectors.map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 }.filter { !ignored.contains($0) }
    }
}
