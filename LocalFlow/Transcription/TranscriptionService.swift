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

    let settings: AppSettings
    private let local: TranscriptionProvider

    init(settings: AppSettings = .shared, local: TranscriptionProvider = LocalWhisper.shared) {
        self.settings = settings
        self.local = local
    }

    func transcribe(samples: [Float]) async throws -> Outcome {
        let vocabulary = settings.vocabulary
        let request = TranscriptionRequest(samples: samples, wav: AudioRecorder.wavData(from: samples),
                                           vocabulary: vocabulary, language: settings.language)
        var warning: String?
        let result: TranscriptionResult

        switch settings.engineMode {
        case .local:
            result = try await withRetries(local, request, attempts: 2)
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

        return Outcome(text: Self.postProcess(result.text, vocabulary: vocabulary, cleanup: settings.cleanupEnabled),
                       rawText: result.text, engine: result.engine, warning: warning)
    }

    static func postProcess(_ raw: String, vocabulary: Vocabulary, cleanup: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = vocabulary.applySpelling(to: text)
        if cleanup { text = TextCleanup.clean(text) }
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

/// Builds dictionary suggestions from the one-off "who are you / what do you do" answer. The answer is only sent
/// to the provider the user already configured and is never written to disk.
enum DictionaryBuilder {
    static func suggestTerms(about answer: String, provider: CloudProviderID) async throws -> [String] {
        let prompt = """
        A person described themselves so a dictation app can learn vocabulary it should spell correctly. Based on the \
        description, list 30-60 proper nouns, product names, company names, tools, acronyms and jargon this person is \
        likely to say while dictating messages and documents. Prefer terms speech-to-text models misspell (brand \
        capitalisation, acronyms, compound words). One term per line, exact capitalisation, no numbering, no explanations.

        Description: \(answer)
        """
        let text = try await TextGeneration.complete(prompt: prompt, provider: provider)
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789. ")) }
            .filter { !$0.isEmpty && $0.count < 40 && !$0.contains(":") && seen.insert($0.lowercased()).inserted }
    }

    /// Merges suggestions into the existing dictionary text without duplicates.
    static func merge(_ terms: [String], into text: String) -> String {
        let existing = Set(Vocabulary(text: text).terms.map { $0.lowercased() })
        let fresh = terms.filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + fresh.joined(separator: "\n")
    }
}
