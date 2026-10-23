import Foundation
import whisper

/// whisper.cpp in-process with Metal. The model is loaded once and kept warm.
final class WhisperEngine {
    static let shared = WhisperEngine()

    private var context: OpaquePointer?
    private let queue = DispatchQueue(label: "LocalFlow.whisper", qos: .userInitiated)

    deinit { if let context { whisper_free(context) } }

    func preload() { queue.async { _ = self.loadedContext() } }

    private func loadedContext() -> OpaquePointer? {
        if let context { return context }
        guard FileManager.default.fileExists(atPath: ModelStore.localURL.path) else { return nil }
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false  // whisper.cpp's Metal backend crashes in the Simulator (XPC misuse); real iPhones use Metal.
        #else
        params.use_gpu = true
        #endif
        params.flash_attn = true
        context = whisper_init_from_file_with_params(ModelStore.localURL.path, params)
        DebugLog.write("model loaded: \(context != nil), footprint \(Memory.footprintMB) MB")
        return context
    }

    /// Returns the raw transcript (before spelling fixes and cleanup).
    func transcribe(_ samples: [Float], hint: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let ctx = self.loadedContext() else {
                    continuation.resume(throwing: DictationError("Couldn't load the speech model."))
                    return
                }
                let (status, text) = WhisperDecode.run(ctx, samples: samples, hint: hint, language: "auto", temperatureInc: 0.2)
                if status == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: DictationError("Transcription failed (\(status))."))
                }
            }
        }
    }
}

struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The app's memory footprint as iOS counts it for jetsam (phys_footprint).
enum Memory {
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

/// DEBUG builds append to Documents/debug.log (model load, memory peaks). Release builds write nothing.
enum DebugLog {
    static func write(_ line: String) {
        #if DEBUG
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("debug.log")
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
        #endif
    }
}
