import Foundation
import whisper

/// The whisper.cpp decode shared by the Mac and iPhone apps: the settled parameters, the dictionary hint on every
/// window, and prompt echoes dropped. `samples` are 16 kHz mono floats.
enum WhisperDecode {
    static func run(_ ctx: OpaquePointer, samples input: [Float], hint: String, language: String,
                    temperatureInc: Float) -> (status: Int32, text: String) {
        var samples = input
        // whisper.cpp wants at least a second of audio; pad short clips with silence.
        let minimum = Int(16_000 * 1.1)
        if samples.count < minimum { samples.append(contentsOf: [Float](repeating: 0, count: minimum - samples.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // Timestamps stay on even though we never show them: without them whisper.cpp treats every 30 s window as
        // finished the moment the decoder stops, so one early stop or echoed prompt silently drops the rest of
        // the window. With them it only advances to the last timestamp and retries a window that produced nothing.
        // Timestamps stay on even though we never show them: without them whisper.cpp treats every 30 s window as
        // finished the moment the decoder stops, so one early stop or echoed prompt silently drops the rest of
        // the window. With them it only advances to the last timestamp and retries a window that produced nothing.
        params.no_timestamps = false
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        // whisper.cpp's temperature fallback samples, so the same audio can come back with different words.
        // whisper.cpp's temperature fallback samples, so the same audio can come back with different words.
        params.temperature_inc = temperatureInc
        params.no_speech_thold = 0.6
        params.translate = false

        let status: Int32 = language.withCString { langPtr in
            hint.withCString { hintPtr in
                params.language = langPtr
                params.detect_language = false
                params.initial_prompt = hint.isEmpty ? nil : hintPtr
                // Every window is conditioned on the dictionary hint alone. Carrying decoded text forward lets one
                // bad window (silence heard as "Thank you.") poison the rest of a long dictation.
                // Every window is conditioned on the dictionary hint alone. Carrying decoded text forward lets one
                // bad window (silence heard as "Thank you.") poison the rest of a long dictation.
                params.carry_initial_prompt = true
                params.n_max_text_ctx = hint.isEmpty ? 0 : whisper_token_count(ctx, hintPtr) + 1
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else { return (status, "") }

        var pieces: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
            let piece = String(cString: segment)
            if !Vocabulary.isPromptEcho(piece) { pieces.append(piece) }
        }
        return (0, TextCleanup.dropTrailingSilenceEcho(pieces).joined().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
