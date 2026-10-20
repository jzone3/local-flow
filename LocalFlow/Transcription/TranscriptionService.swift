import Foundation

/// Picks the engine from settings, retries cloud calls with backoff, falls back to local Whisper, then runs the
/// on-device cleanup and dictionary spelling passes.
final class TranscriptionService {
    struct Outcome {
        let text: String
        let rawText: String
        let engine: String
        let warning: String?
        let details: TranscriptionDetails
    }

    /// One provider's run: the result or the last error, plus how many requests it took and how long.
    struct Run {
        let outcome: Result<TranscriptionResult, Error>
        let tries: Int
        let seconds: Double
        var result: TranscriptionResult? { try? outcome.get() }
        var errorText: String? { if case .failure(let error) = outcome { return error.localizedDescription }; return nil }
        func attempt(service: String, model: String?, keepTranscript: Bool = false) -> TranscriptionDetails.Attempt {
            TranscriptionDetails.Attempt(service: service, model: model, tries: tries, error: errorText, seconds: seconds,
                                         transcript: keepTranscript ? result?.text : nil)
        }
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
        var details: TranscriptionDetails
        let started = Date()
        let localModel = WhisperModel.named(settings.localModelID)
        let localName = "Whisper \(localModel.title) (local)"

        switch settings.engineMode {
        case .local:
            let run = await attempt(local, request, attempts: 2)
            result = try run.outcome.get()
            details = TranscriptionDetails(mode: .local, seconds: 0, attempts: [run.attempt(service: localName, model: nil)], finalFrom: "Whisper \(localModel.title)")
        case .cloud where settings.mixtureOfExperts:
            let moe = await mixtureOfExperts(request)
            details = moe.details
            if let moeResult = moe.result {
                result = moeResult
                warning = moe.warning
            } else {
                let error = moe.error ?? TranscriptionError.badResponse("no transcripts")
                guard settings.fallbackToLocal, localModel.isDownloaded else {
                    throw TranscriptionError.allFailed(primary: error, fallback: nil)
                }
                let fallback = await attempt(local, request, attempts: 1)
                details.attempts.append(fallback.attempt(service: localName, model: nil))
                guard let fallbackResult = fallback.result else {
                    throw TranscriptionError.allFailed(primary: error, fallback: fallback.outcome.failureError)
                }
                result = fallbackResult
                warning = "Cloud services failed (\(error.localizedDescription)). Used the local model instead."
                details.usedLocalFallback = true
                details.fallbackReason = warning
                details.finalFrom = localName
            }
        case .cloud:
            let provider = settings.cloudProvider
            let model = settings.cloudModel(for: provider)
            let cloud = provider.makeProvider(model: model)
            let run = await attempt(cloud, request, attempts: Self.maxAttempts)
            details = TranscriptionDetails(mode: .cloud, seconds: 0, attempts: [run.attempt(service: provider.title, model: model)], finalFrom: "\(provider.title) \(model)")
            if let cloudResult = run.result {
                result = cloudResult
            } else {
                let error = run.outcome.failureError ?? TranscriptionError.badResponse("no result")
                guard settings.fallbackToLocal, localModel.isDownloaded else {
                    throw TranscriptionError.allFailed(primary: error, fallback: nil)
                }
                let fallback = await attempt(local, request, attempts: 1)
                details.attempts.append(fallback.attempt(service: localName, model: nil))
                guard let fallbackResult = fallback.result else {
                    throw TranscriptionError.allFailed(primary: error, fallback: fallback.outcome.failureError)
                }
                result = fallbackResult
                warning = "\(provider.title) failed (\(error.localizedDescription)). Used the local model instead."
                details.usedLocalFallback = true
                details.fallbackReason = warning
                details.finalFrom = localName
            }
        }
        details.seconds = Date().timeIntervalSince(started)

        return Outcome(text: Self.postProcess(result.text, vocabulary: vocabulary, cleanup: settings.cleanupEnabled, profile: profile),
                       rawText: result.text, engine: result.engine, warning: warning, details: details)
    }

    /// What the bar should say while this transcription runs.
    static func transcribingLabel(_ settings: AppSettings = .shared) -> String {
        MixtureOfExperts.transcribingLabel(modelCount: settings.usesMixtureOfExperts ? settings.cloudProvidersWithKeys.count : 1)
    }

    struct MixtureRun {
        var result: TranscriptionResult?
        var warning: String?
        var error: Error?
        var details: TranscriptionDetails
    }

    /// Every cloud service with a key transcribes at once; an OpenAI chat model merges what came back.
    private func mixtureOfExperts(_ request: TranscriptionRequest) async -> MixtureRun {
        let providers = settings.cloudProvidersWithKeys
        var run = MixtureRun(details: TranscriptionDetails(mode: .mixture, seconds: 0, finalFrom: "nobody"))
        guard !providers.isEmpty else { run.error = TranscriptionError.noAPIKey("any cloud service"); return run }

        var runs: [CloudProviderID: Run] = [:]
        await withTaskGroup(of: (CloudProviderID, Run).self) { group in
            for provider in providers {
                let cloud = provider.makeProvider(model: settings.cloudModel(for: provider))
                group.addTask {
                    let started = Date()
                    do {
                        return (provider, try await Self.withTimeout(Self.expertTimeout) {
                            await self.attempt(cloud, request, attempts: Self.maxAttempts)
                        })
                    } catch {
                        // Timed out: the retries were cut short, so the count is unknown (0).
                        return (provider, Run(outcome: .failure(error), tries: 0, seconds: Date().timeIntervalSince(started)))
                    }
                }
            }
            for await (provider, result) in group { runs[provider] = result }
        }
        for provider in providers {
            if let one = runs[provider] {
                run.details.attempts.append(one.attempt(service: provider.title, model: settings.cloudModel(for: provider), keepTranscript: true))
            }
        }
        if Task.isCancelled { run.error = TranscriptionError.cancelled; return run }

        let answered = providers.filter { runs[$0]?.result != nil }
        let candidates = answered.map { MixtureOfExperts.Transcript(service: $0.title, text: runs[$0]!.result!.text) }
        guard let first = candidates.first else {
            run.error = providers.compactMap { runs[$0]?.outcome.failureError }.first ?? TranscriptionError.badResponse("no transcripts")
            return run
        }
        let services = answered.map(\.title)

        if candidates.count == 1 {
            run.result = TranscriptionResult(text: first.text, engine: MixtureOfExperts.engineLabel(services: services, merger: nil))
            run.warning = "Only \(first.service) answered; used it alone."
            run.details.finalFrom = first.service
            run.details.mergeError = "nothing to merge, only one service answered"
            return run
        }
        let best = MixtureOfExperts.bestSingle(candidates, preference: CloudProviderID.allCases.map(\.title)) ?? first
        let unmerged = TranscriptionResult(text: best.text, engine: MixtureOfExperts.engineLabel(services: services, merger: nil))
        run.details.finalFrom = best.service
        guard let key = CloudProviderID.openAI.apiKey else {
            run.result = unmerged
            run.warning = "No OpenAI key to merge the results; used \(best.service) alone."
            run.details.mergeError = "no OpenAI key; used \(best.service) alone"
            return run
        }
        let mergeStarted = Date()
        do {
            let prompt = MixtureOfExperts.mergePrompt(candidates, terms: request.vocabulary.terms)
            let merged = MixtureOfExperts.cleanAnswer(try await OpenAIChat.complete(prompt, key: key))
            guard !merged.isEmpty else { throw TranscriptionError.badResponse("empty merge") }
            run.result = TranscriptionResult(text: merged, engine: MixtureOfExperts.engineLabel(services: services, merger: OpenAIChat.mergeModel))
            run.details.merger = "OpenAI \(OpenAIChat.mergeModel) (\(TranscriptionDetails.seconds(Date().timeIntervalSince(mergeStarted))))"
            run.details.finalFrom = "OpenAI \(OpenAIChat.mergeModel)"
        } catch is CancellationError {
            run.error = TranscriptionError.cancelled
        } catch {
            run.result = unmerged
            run.warning = "Merge failed (\(error.localizedDescription)); used \(best.service) alone."
            run.details.mergeError = "OpenAI \(OpenAIChat.mergeModel) failed (\(error.localizedDescription)); used \(best.service) alone"
        }
        return run
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
        var tries = 0
        return try await attemptThrowing(provider, request, attempts: attempts, tries: &tries)
    }

    func attempt(_ provider: TranscriptionProvider, _ request: TranscriptionRequest, attempts: Int) async -> Run {
        let started = Date()
        var tries = 0
        do {
            let result = try await attemptThrowing(provider, request, attempts: attempts, tries: &tries)
            return Run(outcome: .success(result), tries: tries, seconds: Date().timeIntervalSince(started))
        } catch {
            return Run(outcome: .failure(error), tries: tries, seconds: Date().timeIntervalSince(started))
        }
    }

    private func attemptThrowing(_ provider: TranscriptionProvider, _ request: TranscriptionRequest, attempts: Int, tries: inout Int) async throws -> TranscriptionResult {
        var lastError: Error = TranscriptionError.badResponse("no attempts")
        for attempt in 0..<max(1, attempts) {
            tries = attempt + 1
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

private extension Result {
    var failureError: Failure? { if case .failure(let error) = self { return error }; return nil }
}
