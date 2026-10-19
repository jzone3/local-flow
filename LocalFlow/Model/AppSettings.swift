import AppKit
import Combine
import Foundation

enum EngineMode: String, CaseIterable, Identifiable {
    case local, cloud
    var id: String { rawValue }
    var title: String { self == .local ? "Local only" : "Cloud" }
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
    @Published var mixtureOfExperts: Bool { didSet { defaults.set(mixtureOfExperts, forKey: "mixtureOfExperts") } }
    @Published var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var vocabularyText: String { didSet { defaults.set(vocabularyText, forKey: "vocabulary") } }
    @Published var dictionaryPacks: [String] { didSet { defaults.set(dictionaryPacks, forKey: "dictionaryPacks") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var hotkey: Hotkey { didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// CoreAudio device UID of the microphone to record from; nil = system default.
    @Published var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    static let historyRetention: TimeInterval = 12 * 60 * 60

    private init() {
        engineMode = EngineMode(rawValue: defaults.string(forKey: "engineMode") ?? "") ?? .local
        cloudProviderID = defaults.string(forKey: "cloudProvider") ?? CloudProviderID.openAI.rawValue
        cloudModels = defaults.dictionary(forKey: "cloudModels") as? [String: String] ?? [:]
        localModelID = WhisperModel.named(defaults.string(forKey: "localModel") ?? WhisperModel.recommended.id).id
        fallbackToLocal = defaults.object(forKey: "fallbackToLocal") as? Bool ?? true
        mixtureOfExperts = defaults.bool(forKey: "mixtureOfExperts")
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        vocabularyText = defaults.string(forKey: "vocabulary") ?? Vocabulary.defaultText
        dictionaryPacks = defaults.stringArray(forKey: "dictionaryPacks") ?? []
        language = defaults.string(forKey: "language") ?? "auto"
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .fn
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        onboardingDone = defaults.bool(forKey: "onboardingDone")
    }

    var vocabulary: Vocabulary { Vocabulary(text: vocabularyText) }

    func setPack(_ id: String, on: Bool) {
        let before = Set(dictionaryPacks)
        var after = before
        if on { after.insert(id) } else { after.remove(id) }
        guard after != before else { return }
        vocabularyText = VocabularyPack.apply(selected: after, previouslySelected: before, to: vocabularyText)
        dictionaryPacks = VocabularyPack.all.map(\.id).filter { after.contains($0) }
    }
    var cloudProvider: CloudProviderID { CloudProviderID(rawValue: cloudProviderID) ?? .openAI }

    /// Every cloud service with a key in the Keychain; Mixture of experts fans out to all of them.
    var cloudProvidersWithKeys: [CloudProviderID] { CloudProviderID.allCases.filter { $0.apiKey != nil } }

    var usesMixtureOfExperts: Bool { engineMode == .cloud && mixtureOfExperts }

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
