import AppKit
import Combine
import Foundation

enum EngineMode: String, CaseIterable, Identifiable {
    case local, cloud
    var id: String { rawValue }
    var title: String { self == .local ? "Local only" : "Cloud" }
}

/// A hotkey is either a lone modifier held down (Fn, Right Option…) or a regular key with optional modifiers.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags.rawValue, device-independent

    static let fn = Hotkey(keyCode: 63, modifiers: NSEvent.ModifierFlags.function.rawValue)
    static let rightOption = Hotkey(keyCode: 61, modifiers: NSEvent.ModifierFlags.option.rawValue)
    static let rightCommand = Hotkey(keyCode: 54, modifiers: NSEvent.ModifierFlags.command.rawValue)

    static let modifierKeyCodes: [UInt16: String] = [
        63: "Fn", 54: "Right ⌘", 55: "⌘", 58: "⌥", 61: "Right ⌥", 59: "⌃", 62: "Right ⌃", 56: "⇧", 60: "Right ⇧", 57: "⇪",
    ]

    var isModifierOnly: Bool { Hotkey.modifierKeyCodes[keyCode] != nil }

    var displayName: String {
        if let name = Hotkey.modifierKeyCodes[keyCode] { return name }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.function) { parts.append("Fn") }
        parts.append(Hotkey.keyName(keyCode))
        return parts.joined()
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let s = special[code] { return s }
        let letters: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"]
        return letters[code] ?? "Key \(code)"
    }
}

/// All user preferences, backed by UserDefaults. API keys live in the Keychain (see `Keychain`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var engineMode: EngineMode { didSet { defaults.set(engineMode.rawValue, forKey: "engineMode") } }
    @Published var cloudProviderID: String { didSet { defaults.set(cloudProviderID, forKey: "cloudProvider") } }
    @Published var cloudModels: [String: String] { didSet { defaults.set(cloudModels, forKey: "cloudModels") } }
    @Published var localModelID: String { didSet { defaults.set(localModelID, forKey: "localModel") } }
    @Published var fallbackToLocal: Bool { didSet { defaults.set(fallbackToLocal, forKey: "fallbackToLocal") } }
    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var vocabularyText: String { didSet { defaults.set(vocabularyText, forKey: "vocabulary") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var hotkey: Hotkey { didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    static let historyRetention: TimeInterval = 12 * 60 * 60

    private init() {
        engineMode = EngineMode(rawValue: defaults.string(forKey: "engineMode") ?? "") ?? .local
        cloudProviderID = defaults.string(forKey: "cloudProvider") ?? CloudProviderID.openAI.rawValue
        cloudModels = defaults.dictionary(forKey: "cloudModels") as? [String: String] ?? [:]
        localModelID = defaults.string(forKey: "localModel") ?? WhisperModel.recommended.id
        fallbackToLocal = defaults.object(forKey: "fallbackToLocal") as? Bool ?? true
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        vocabularyText = defaults.string(forKey: "vocabulary") ?? Vocabulary.defaultText
        language = defaults.string(forKey: "language") ?? "auto"
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .fn
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        onboardingDone = defaults.bool(forKey: "onboardingDone")
    }

    var vocabulary: Vocabulary { Vocabulary(text: vocabularyText) }
    var cloudProvider: CloudProviderID { CloudProviderID(rawValue: cloudProviderID) ?? .openAI }

    func cloudModel(for provider: CloudProviderID) -> String {
        cloudModels[provider.rawValue] ?? provider.defaultModel
    }

    func setCloudModel(_ model: String, for provider: CloudProviderID) {
        cloudModels[provider.rawValue] = model
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Local Flow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
