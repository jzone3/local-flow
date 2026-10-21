import Foundation

/// What happened during one transcription, kept with the History entry so Cloud mode is not a black box:
/// which service and model, how many tries, whether the local model had to step in, and for Mixture of experts
/// every service's transcript and who produced the final text. Pure Foundation; `text` is what History shows.
struct TranscriptionDetails: Codable, Equatable {
    struct Attempt: Codable, Equatable {
        var service: String        // "ElevenLabs", "Whisper Best (local)"
        var model: String?         // "scribe_v2"
        var tries: Int             // how many requests were made
        var error: String?         // nil when it answered
        var seconds: Double
        var transcript: String?    // kept for Mixture of experts so the merge can be checked
    }

    enum Mode: String, Codable { case local, cloud, mixture }

    var mode: Mode
    var seconds: Double
    var attempts: [Attempt] = []
    /// The service whose transcript became the final text (before cleanup).
    var finalFrom: String
    var merger: String?            // "OpenAI gpt-5.4-mini" when an LLM merged the transcripts
    var mergeError: String?        // why the merge didn't happen, when it was supposed to
    var usedLocalFallback = false
    var fallbackReason: String?
    /// Long files are transcribed in parts (see AudioChunker); the attempts kept are part 1's.
    var parts: Int?

    static func seconds(_ value: Double) -> String { String(format: value < 10 ? "%.1f s" : "%.0f s", value) }

    /// Plain lines for the History "Details" disclosure.
    var text: String {
        var lines: [String] = []
        if let parts, parts > 1 { lines.append("Transcribed in \(parts) parts of up to \(Int(AudioChunker.maxSeconds / 60)) minutes; the lines below are for part 1.") }
        switch mode {
        case .local:
            lines.append("Local · \(finalFrom) · \(Self.seconds(seconds))")
        case .cloud:
            lines.append("Cloud · \(Self.seconds(seconds))")
            lines.append(contentsOf: attempts.map(line))
            if usedLocalFallback {
                lines.append("Local fallback used: \(finalFrom)")
                if let fallbackReason { lines.append("Why: \(fallbackReason)") }
            } else {
                lines.append("Final text from \(finalFrom)")
            }
        case .mixture:
            let answered = attempts.filter { $0.transcript != nil }.count
            lines.append("Mixture of experts · \(attempts.count) service\(attempts.count == 1 ? "" : "s"), \(answered) answered · \(Self.seconds(seconds))")
            for attempt in attempts {
                lines.append(line(attempt))
                if let transcript = attempt.transcript { lines.append("    “\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))”") }
            }
            if let merger { lines.append("Merged by \(merger) → final text") }
            else if let mergeError { lines.append("Merge: \(mergeError)") }
            if usedLocalFallback {
                lines.append("Local fallback used: \(finalFrom)")
                if let fallbackReason { lines.append("Why: \(fallbackReason)") }
            } else if merger == nil {
                lines.append("Final text from \(finalFrom)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func line(_ attempt: Attempt) -> String {
        var head = attempt.service
        if let model = attempt.model { head += " (\(model))" }
        let tries = attempt.tries == 1 ? "1 try" : "\(attempt.tries) tries"
        if let error = attempt.error {
            return attempt.tries == 0 ? "✗ \(head) — \(error)" : "✗ \(head) — failed after \(tries): \(error)"
        }
        return "✓ \(head) — \(tries), \(Self.seconds(attempt.seconds))"
    }
}
