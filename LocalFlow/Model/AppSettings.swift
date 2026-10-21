import AppKit
import Combine
import Foundation
import ServiceManagement

enum EngineMode: String, CaseIterable, Identifiable {
    case local, cloud
    var id: String { rawValue }
    var title: String { self == .local ? "Local only" : "Cloud" }
}

/// All user preferences, backed by UserDefaults. API keys live in the Keychain (see `Keychain`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var engineMode: EngineMode {
        didSet {
            defaults.set(engineMode.rawValue, forKey: "engineMode")
            if engineMode == .cloud { preferProviderWithKey() }
        }
    }
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
    /// On during setup so the test step is audible; off by default afterwards unless the user turned it on.
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    var playSoundsChosen: Bool { defaults.object(forKey: "playSounds") != nil }
    /// CoreAudio device UID of the microphone to record from; nil = system default.
    @Published var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    static let historyRetention: TimeInterval = 12 * 60 * 60

    /// Stock macOS login item (System Settings → General → Login Items lists it). Turned on when setup finishes.
    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        objectWillChange.send()
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { NSLog("Login item: \(error)") }
    }

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
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? !defaults.bool(forKey: "onboardingDone")
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

    /// Keeps an explicit pick, but a provider with no key gives way to the first one that has a key, so switching to
    /// Cloud right after importing an ElevenLabs key doesn't land on a keyless OpenAI.
    func preferProviderWithKey() {
        guard cloudProvider.apiKey == nil, let first = cloudProvidersWithKeys.first else { return }
        cloudProviderID = first.rawValue
    }

    func cloudModel(for provider: CloudProviderID) -> String {
        cloudModels[provider.rawValue] ?? provider.defaultModel
    }

    /// The menu bar's one-line answer to "what is transcribing right now": "Local · Best", "Cloud · ElevenLabs Scribe v2",
    /// "Cloud · Mixture of experts (3 services)".
    var engineLine: String {
        switch engineMode {
        case .local:
            return "Local · \(WhisperModel.named(localModelID).title)"
        case .cloud where mixtureOfExperts:
            let count = cloudProvidersWithKeys.count
            return "Cloud · \(MixtureOfExperts.title) (\(count) service\(count == 1 ? "" : "s"))"
        case .cloud:
            return "Cloud · \(cloudProvider.title) \(cloudProvider.modelTitle(cloudModel(for: cloudProvider)))"
        }
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
