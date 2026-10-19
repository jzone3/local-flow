import Foundation

/// A hotkey is either a lone modifier held down (Fn, Right Option…) or a regular key with modifiers.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags.rawValue, device-independent

    // NSEvent.ModifierFlags raw values, so the core stays AppKit-free.
    static let capsLockFlag: UInt = 1 << 16
    static let shiftFlag: UInt = 1 << 17
    static let controlFlag: UInt = 1 << 18
    static let optionFlag: UInt = 1 << 19
    static let commandFlag: UInt = 1 << 20
    static let numericPadFlag: UInt = 1 << 21
    static let functionFlag: UInt = 1 << 23
    static let modifierMask: UInt = shiftFlag | controlFlag | optionFlag | commandFlag

    static let fn = Hotkey(keyCode: 63, modifiers: functionFlag)
    static let rightOption = Hotkey(keyCode: 61, modifiers: optionFlag)
    static let rightCommand = Hotkey(keyCode: 54, modifiers: commandFlag)

    static let modifierKeyCodes: [UInt16: String] = [
        63: "Fn", 54: "Right ⌘", 55: "⌘", 58: "⌥", 61: "Right ⌥", 59: "⌃", 62: "Right ⌃", 56: "⇧", 60: "Right ⇧", 57: "⇪",
    ]

    /// The flag a modifier key sets while held.
    static func modifierFlag(for keyCode: UInt16) -> UInt? {
        switch keyCode {
        case 63: return functionFlag
        case 54, 55: return commandFlag
        case 58, 61: return optionFlag
        case 59, 62: return controlFlag
        case 56, 60: return shiftFlag
        default: return nil
        }
    }

    /// The modifiers that matter for a key combo: ⌃⌥⇧⌘ only. Caps Lock, the keypad bit, the Fn bit (set
    /// automatically for arrows and F-keys) and the undocumented bits on tapped events are dropped so recording
    /// and matching agree.
    static func comboModifiers(_ raw: UInt) -> UInt { raw & modifierMask }

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    var isModifierOnly: Bool { Hotkey.modifierKeyCodes[keyCode] != nil }
    var isFn: Bool { keyCode == Hotkey.fn.keyCode }

    /// True when macOS's own Dictation shortcut is "Press Fn twice" (symbolic hotkey 164),
    /// which fights with our double-tap. Read live from com.apple.symbolichotkeys.
    static var systemDictationUsesFnTwice: Bool {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotkeys["164"] as? [String: Any] else { return true }  // stock Macs default to Fn twice
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
        let params = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber] ?? []
        return enabled && params.first?.intValue == 8_388_608
    }

    var displayName: String {
        if let name = Hotkey.modifierKeyCodes[keyCode] { return name }
        return Hotkey.symbols(for: modifiers) + Hotkey.keyName(keyCode)
    }

    /// "⌃⌥⇧⌘" in the order macOS shows them.
    static func symbols(for modifiers: UInt) -> String {
        var parts = ""
        if modifiers & controlFlag != 0 { parts += "⌃" }
        if modifiers & optionFlag != 0 { parts += "⌥" }
        if modifiers & shiftFlag != 0 { parts += "⇧" }
        if modifiers & commandFlag != 0 { parts += "⌘" }
        if modifiers & functionFlag != 0 { parts += "Fn" }
        return parts
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
        ]
        if let s = special[code] { return s }
        let letters: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"]
        return letters[code] ?? "Key \(code)"
    }
}

/// The hotkey recorder's state machine, fed raw key events. Held modifiers show live but don't commit; a
/// non-modifier key going down commits the combo, a single modifier pressed and released on its own commits
/// a modifier-only hotkey, Esc cancels. A plain key with no modifier is only accepted if it's an F-key.
struct HotkeyRecording {
    enum Event {
        case flagsChanged(keyCode: UInt16, flags: UInt)
        case keyDown(keyCode: UInt16, flags: UInt)
    }

    enum Step: Equatable {
        case recording(modifiers: UInt)
        case committed(Hotkey)
        case cancelled
    }

    private(set) var held: UInt = 0
    /// The one modifier key that is down alone and would commit if released without anything else.
    private var soloModifier: UInt16?

    mutating func handle(_ event: Event) -> Step {
        switch event {
        case let .flagsChanged(keyCode, raw):
            let flags = raw & (Hotkey.modifierMask | Hotkey.functionFlag)
            guard flags != held else { return .recording(modifiers: held) }
            let wentDown = flags & ~held != 0
            let releasedSolo = soloModifier == keyCode && flags == 0 && Hotkey.modifierFlag(for: keyCode) != nil
            soloModifier = wentDown && held == 0 ? keyCode : nil
            held = flags
            if releasedSolo, let flag = Hotkey.modifierFlag(for: keyCode) {
                return .committed(Hotkey(keyCode: keyCode, modifiers: flag))
            }
            return .recording(modifiers: held)
        case let .keyDown(keyCode, raw):
            if keyCode == 53 { return .cancelled }
            soloModifier = nil
            let modifiers = Hotkey.comboModifiers(raw)
            if modifiers == 0, !Hotkey.functionKeyCodes.contains(keyCode) { return .recording(modifiers: held) }
            return .committed(Hotkey(keyCode: keyCode, modifiers: modifiers))
        }
    }
}
