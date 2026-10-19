import Foundation

/// The pure parts of "Mixture of experts" cloud mode: which services take part, the prompt that asks an LLM to
/// merge their transcripts, and the cleanup of its answer. Networking lives in `TranscriptionService`.
enum MixtureOfExperts {
    struct Transcript: Equatable {
        let service: String
        let text: String
    }

    static let title = "Mixture of experts"
    static let explanation = "Sends your audio to every cloud service you have a key for, then an LLM merges the transcripts and picks the best wording. Slower, but more accurate."
    static let needMoreKeys = "Add keys for more services to use more models."
    static let needOpenAIKey = "Needs an OpenAI key to merge the results."

    /// What the bar says while the fan-out runs.
    static func transcribingLabel(modelCount: Int) -> String {
        modelCount > 1 ? "Transcribing with \(modelCount) models…" : "Transcribing…"
    }

    /// "OpenAI + ElevenLabs → gpt-5.4-mini", or "ElevenLabs only" when nothing was merged. Shown in History.
    static func engineLabel(services: [String], merger: String?) -> String {
        if services.count > 1, let merger { return "\(title) (\(services.joined(separator: " + ")) → \(merger))" }
        if services.count > 1 { return "\(title) (\(services.joined(separator: " + ")), not merged)" }
        return "\(title) (\(services.first ?? "no service") only)"
    }

    /// Picks one transcript when merging isn't possible: the first service in `preference` that answered.
    static func bestSingle(_ transcripts: [Transcript], preference: [String]) -> Transcript? {
        for service in preference {
            if let hit = transcripts.first(where: { $0.service == service }) { return hit }
        }
        return transcripts.first
    }

    static func mergePrompt(_ transcripts: [Transcript], terms: [String]) -> String {
        var lines = [
            "You are given \(transcripts.count) transcripts of the same short audio recording, each from a different speech-to-text service.",
            "Output ONLY the single best transcript of what was said. Where the transcripts disagree on a word, prefer the wording most of them agree on, unless it is clearly a transcription error.",
            "Keep the speaker's words, order and meaning; do not summarize, shorten, translate or add anything.",
        ]
        if !terms.isEmpty {
            lines.append("Spell these names and terms exactly like this when they were said: " + terms.joined(separator: ", ") + ".")
        }
        lines.append("No commentary, no quotes, no markdown, no labels — just the transcript text.")
        lines.append("")
        for (index, transcript) in transcripts.enumerated() {
            lines.append("Transcript \(index + 1) (\(transcript.service)):")
            lines.append(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips what chat models add anyway: code fences, a "Transcript:" label, wrapping quotes.
    static func cleanAnswer(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["Best transcript:", "Transcript:", "Merged transcript:", "Final transcript:"] {
            if text.lowercased().hasPrefix(label.lowercased()) {
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in quotes where text.count > 1 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
