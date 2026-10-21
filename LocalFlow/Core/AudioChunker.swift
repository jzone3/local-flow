import Foundation

/// Splits long audio into parts short enough to upload: OpenAI caps a file at 25 MB and Gemini inline audio at
/// about 20 MB, and 16 kHz 16-bit WAV is 1.92 MB a minute. Each cut lands on the quietest moment before the
/// limit so a word isn't sliced in half. The local model gets the same parts, which is what makes an hour-long
/// file show progress instead of sitting on "Transcribing…". Pure Foundation; covered by Tests/CoreTests.
enum AudioChunker {
    static let sampleRate = 16_000
    /// Longest part: 5 minutes ≈ 9.6 MB of WAV, under every service's limit even after base64.
    static let maxSeconds = 300.0
    /// A cut may move this far back from the limit to find a pause.
    static let searchSeconds = 45.0
    /// Loudness is measured over windows this long; the quietest one in the search range is the cut.
    static let windowSeconds = 0.25
    /// A tail shorter than this is dropped rather than sent on its own.
    static let minSeconds = 1.0

    /// Sample ranges, in order, covering the audio. One range (the whole thing) when it fits in a single part.
    static func ranges(count: Int, maxSeconds: Double = maxSeconds, loudness: (Range<Int>) -> Float) -> [Range<Int>] {
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        let searchSamples = Int(searchSeconds * Double(sampleRate))
        let window = Int(windowSeconds * Double(sampleRate))
        let minSamples = Int(minSeconds * Double(sampleRate))
        guard count > maxSamples else { return count > 0 ? [0..<count] : [] }

        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maxSamples {
            let limit = start + maxSamples
            var cut = limit
            var quietest = Float.greatestFiniteMagnitude
            var position = max(start + minSamples, limit - searchSamples)
            while position + window <= limit {
                let level = loudness(position..<(position + window))
                if level <= quietest { quietest = level; cut = position + window / 2 }  // ties → the later window, so parts stay long
                position += window
            }
            ranges.append(start..<cut)
            start = cut
        }
        if count - start >= minSamples { ranges.append(start..<count) }
        return ranges
    }

    static func ranges(_ samples: [Float], maxSeconds: Double = maxSeconds) -> [Range<Int>] {
        ranges(count: samples.count, maxSeconds: maxSeconds) { range in
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            return sum / Float(max(1, range.count))
        }
    }

    /// Parts' texts meet with a paragraph break when the first ended a sentence, otherwise a space.
    static func join(_ head: String, _ tail: String) -> String {
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        let endsSentence = head.last.map { ".!?".contains($0) } ?? false
        return head + (endsSentence ? "\n\n" : " ") + tail
    }
}
