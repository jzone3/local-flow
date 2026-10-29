import Foundation

/// Turns raw chunk loudness into a 0…1 level for the bar's waveform that moves even on a quiet microphone.
/// The floor follows the quietest recent sound (room noise) and the ceiling the loudest; a chunk is placed
/// between them, so speech at −45 dB on a low input volume fills the bars like speech at −15 dB does.
/// Pure Foundation; covered by Tests/CoreTests.
struct AutoGain {
    /// Below this the mic is treated as silent.
    static let silence: Float = -60
    /// The floor and ceiling never come closer than this, so steady noise doesn't become a full-height waveform.
    static let minSpan: Float = 18

    private(set) var floor: Float = silence
    private(set) var ceiling: Float = silence + minSpan

    /// `rms` is the chunk's root-mean-square sample value (0…1).
    mutating func level(rms: Float) -> Float {
        let db = max(Self.silence, 20 * log10(max(rms, 1e-6)))
        floor = min(db, floor + 0.15)             // noise floor rises slowly, drops at once
        ceiling = max(db, ceiling - 0.1)           // the loudest sound decays slowly, so pauses stay low
        let top = max(ceiling, floor + Self.minSpan)
        return min(1, max(0, (db - floor) / (top - floor)))
    }

    mutating func reset() { self = AutoGain() }
}

/// A short press with no sound in it: Whisper would invent a sentence ("Let's get started.") instead of staying
/// silent, so a clip under `maxDuration` whose loudest tenth of a second stays below `threshold` dBFS is dropped.
enum SpeechGate {
    static let threshold: Float = -50
    static let maxDuration: Double = 1

    static func isSilentTap(_ samples: [Float], sampleRate: Int = 16_000) -> Bool {
        Double(samples.count) / Double(sampleRate) < maxDuration && !hasSpeech(samples, sampleRate: sampleRate)
    }

    static func hasSpeech(_ samples: [Float], sampleRate: Int = 16_000) -> Bool {
        let window = max(1, sampleRate / 10)
        var start = 0
        while start < samples.count {
            let chunk = samples[start..<min(samples.count, start + window)]
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            if 20 * log10(max(rms, 1e-6)) >= threshold { return true }
            start += window
        }
        return false
    }
}
