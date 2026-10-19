import Foundation

/// Picks the engine from settings, retries cloud calls with backoff, falls back to local Whisper, then runs the
/// on-device cleanup and dictionary spelling passes.
final class TranscriptionService {
    struct Outcome {
        let text: String
        let rawText: String
        let engine: String
        let warning: String?
    }

    static let maxAttempts = 3
    /// One slow service must not hold up the paste when others have answered.
    static let expertTimeout: TimeInterval = 25

    let settings: AppSettings
    private let local: TranscriptionProvider

    init(settings: AppSettings = .shared, local: TranscriptionProvider = LocalWhisper.shared) {
        self.settings = settings
        self.local = local
    }

    func transcribe(samples: [Float], profile: CleanupProfile = .standard) async throws -> Outcome {
        let vocabulary = settings.vocabulary
        let request = TranscriptionRequest(samples: samples, wav: AudioRecorder.wavData(from: samples),
                                           vocabulary: vocabulary, language: settings.language)
        var warning: String?
        let result: TranscriptionResult

        switch settings.engineMode {
        case .local:
            result = try await withRetries(local, request, attempts: 2)
        case .cloud where settings.mixtureOfExperts:
            do {
                let moe = try await mixtureOfExperts(request)
                result = moe.result
                warning = moe.warning
            } catch {
                guard settings.fallbackToLocal, WhisperModel.named(settings.localModelID).isDownloaded else {
                    throw TranscriptionError.allFailed(primary: error, fallback: nil)
                }
                do {
                    result = try await withRetries(local, request, attempts: 1)
                    warning = "Cloud services failed (\(error.localizedDescription)). Used the local model instead."
                } catch let fallbackError {
                    throw TranscriptionError.allFailed(primary: error, fallback: fallbackError)
                }
            }
        case .cloud:
            let provider = settings.cloudProvider
            let cloud = provider.makeProvider(model: settings.cloudModel(for: provider))
            do {
                result = try await withRetries(cloud, request, attempts: Self.maxAttempts)
            } catch {
                guard settings.fallbackToLocal, WhisperModel.named(settings.localModelID).isDownloaded else {
                    throw TranscriptionError.allFailed(primary: error, fallback: nil)
                }
                do {
                    result = try await withRetries(local, request, attempts: 1)
                    warning = "\(provider.title) failed (\(error.localizedDescription)). Used the local model instead."
                } catch let fallbackError {
                    throw TranscriptionError.allFailed(primary: error, fallback: fallbackError)
                }
            }
        }

        return Outcome(text: Self.postProcess(result.text, vocabulary: vocabulary, cleanup: settings.cleanupEnabled, profile: profile),
                       rawText: result.text, engine: result.engine, warning: warning)
    }

    /// What the bar should say while this transcription runs.
    static func transcribingLabel(_ settings: AppSettings = .shared) -> String {
        MixtureOfExperts.transcribingLabel(modelCount: settings.usesMixtureOfExperts ? settings.cloudProvidersWithKeys.count : 1)
    }

    /// Every cloud service with a key transcribes at once; an OpenAI chat model merges what came back.
    private func mixtureOfExperts(_ request: TranscriptionRequest) async throws -> (result: TranscriptionResult, warning: String?) {
        let providers = settings.cloudProvidersWithKeys
        guard !providers.isEmpty else { throw TranscriptionError.noAPIKey("any cloud service") }

        var transcripts: [CloudProviderID: String] = [:]
        var firstError: Error?
        try await withThrowingTaskGroup(of: (CloudProviderID, Result<TranscriptionResult, Error>).self) { group in
            for provider in providers {
                let cloud = provider.makeProvider(model: settings.cloudModel(for: provider))
                group.addTask {
                    do {
                        let result = try await Self.withTimeout(Self.expertTimeout) {
                            try await self.withRetries(cloud, request, attempts: Self.maxAttempts)
                        }
                        return (provider, .success(result))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            for try await (provider, outcome) in group {
                switch outcome {
                case .success(let result): transcripts[provider] = result.text
                case .failure(let error): if firstError == nil { firstError = error }
                }
            }
        }
        try Task.checkCancellation()

        let answered = providers.filter { transcripts[$0] != nil }
        let candidates = answered.map { MixtureOfExperts.Transcript(service: $0.title, text: transcripts[$0]!) }
        guard let first = candidates.first else { throw firstError ?? TranscriptionError.badResponse("no transcripts") }
        let services = answered.map(\.title)

        if candidates.count == 1 {
            return (TranscriptionResult(text: first.text, engine: MixtureOfExperts.engineLabel(services: services, merger: nil)),
                    "Only \(first.service) answered; used it alone.")
        }
        let best = MixtureOfExperts.bestSingle(candidates, preference: CloudProviderID.allCases.map(\.title)) ?? first
        let unmerged = TranscriptionResult(text: best.text, engine: MixtureOfExperts.engineLabel(services: services, merger: nil))
        guard let key = CloudProviderID.openAI.apiKey else {
            return (unmerged, "No OpenAI key to merge the results; used \(best.service) alone.")
        }
        do {
            let prompt = MixtureOfExperts.mergePrompt(candidates, terms: request.vocabulary.terms)
            let merged = MixtureOfExperts.cleanAnswer(try await OpenAIChat.complete(prompt, key: key))
            guard !merged.isEmpty else { throw TranscriptionError.badResponse("empty merge") }
            return (TranscriptionResult(text: merged, engine: MixtureOfExperts.engineLabel(services: services, merger: OpenAIChat.mergeModel)), nil)
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            return (unmerged, "Merge failed (\(error.localizedDescription)); used \(best.service) alone.")
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TranscriptionError.network(URLError(.timedOut))
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func postProcess(_ raw: String, vocabulary: Vocabulary, cleanup: Bool, profile: CleanupProfile = .standard) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = vocabulary.applySpelling(to: text)
        if cleanup { text = TextCleanup.clean(text, profile: profile, vocabulary: vocabulary) }
        else { text = TextCleanup.normalizeWhitespace(TextCleanup.removeNonSpeechTags(text)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    /// Retries only errors worth retrying (timeouts, 429/5xx), with 0.5 s, 1 s, 2 s… between attempts.
    func withRetries(_ provider: TranscriptionProvider, _ request: TranscriptionRequest, attempts: Int) async throws -> TranscriptionResult {
        var lastError: Error = TranscriptionError.badResponse("no attempts")
        for attempt in 0..<max(1, attempts) {
            do {
                return try await provider.transcribe(request)
            } catch {
                lastError = error
                let retryable = (error as? TranscriptionError)?.isRetryable ?? true
                guard retryable, attempt < attempts - 1 else { break }
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (1 << attempt)))
            }
        }
        throw lastError
    }
}
