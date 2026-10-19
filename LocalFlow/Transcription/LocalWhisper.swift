import Combine
import Foundation
import whisper

/// The three Whisper models the user can pick from. Best is the default; the others trade accuracy for size.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let title: String
    let file: String
    let detail: String
    let bytes: Int64

    var fileName: String { "ggml-\(file).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo", title: "Best", file: "large-v3-turbo", detail: "Most accurate. Still instant on Apple silicon.", bytes: 1_624_555_275),
        WhisperModel(id: "large-v3-turbo-q5_0", title: "Classic", file: "large-v3-turbo-q5_0", detail: "Same model, a third of the size. Nearly as accurate.", bytes: 574_041_195),
        WhisperModel(id: "small", title: "Tiny", file: "small", detail: "Small and fast. Fine for short notes and older Macs.", bytes: 487_601_967),
    ]

    static let recommended = all[0]

    /// Older builds stored other model IDs; those map to the nearest tier.
    static func named(_ id: String) -> WhisperModel {
        all.first { $0.id == id } ?? (["large-v3", "medium.en", "medium"].contains(id) ? recommended : id.hasPrefix("small") || id.hasPrefix("base") ? all[2] : recommended)
    }

    static var directory: URL {
        let dir = AppSettings.supportDirectory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localURL: URL { WhisperModel.directory.appendingPathComponent(fileName) }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// The Tiny tier used to be ggml-base; nothing loads that file any more.
    static func removeRetiredFiles() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("ggml-base.bin"))
    }
}

/// Downloads a model file with progress, writing to a temp file so a half download never looks installed.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published var installedVersion = 0  // bumps when a model finishes so views refresh

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func isDownloading(_ model: WhisperModel) -> Bool { tasks[model.id] != nil }

    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil, !model.isDownloaded else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        LocalWhisper.shared.unloadIfCurrent(model)
        installedVersion += 1
        // Keep the selection on a model that exists, or dictation fails until the user notices the radio.
        if AppSettings.shared.localModelID == model.id,
           let next = WhisperModel.all.first(where: { $0.isDownloaded }) {
            AppSettings.shared.localModelID = next.id
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : WhisperModel.named(id).bytes
        let fraction = Double(totalBytesWritten) / Double(max(expected, 1))
        Task { @MainActor in self.progress[id] = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let model = WhisperModel.named(id)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: String?
        if status != 200 {
            failure = "Download failed (HTTP \(status))."
        } else {
            do {
                try? FileManager.default.removeItem(at: model.localURL)
                try FileManager.default.moveItem(at: location, to: model.localURL)
            } catch { failure = error.localizedDescription }
        }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            self.errors[id] = failure
            self.installedVersion += 1
            // A fresh install picks "Best" by default; if that one isn't on disk, the model just fetched becomes the active one.
            if failure == nil, !WhisperModel.named(AppSettings.shared.localModelID).isDownloaded {
                AppSettings.shared.localModelID = id
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription, (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            self.errors[id] = error.localizedDescription
        }
    }
}

/// whisper.cpp running in-process with Metal. The context is loaded once per model and kept warm.
final class LocalWhisper: TranscriptionProvider {
    static let shared = LocalWhisper()

    private var context: OpaquePointer?
    private var loadedModelID: String?
    private let queue = DispatchQueue(label: "LocalFlow.whisper", qos: .userInitiated)

    var name: String { "Whisper \(loadedModelID ?? AppSettings.shared.localModelID) (local)" }

    deinit { if let context { whisper_free(context) } }

    func unloadIfCurrent(_ model: WhisperModel) {
        queue.sync {
            guard loadedModelID == model.id, let context else { return }
            whisper_free(context)
            self.context = nil
            loadedModelID = nil
        }
    }

    /// Loads the selected model ahead of time so the first dictation doesn't pay the load cost.
    func preload() {
        let model = WhisperModel.named(AppSettings.shared.localModelID)
        guard model.isDownloaded else { return }
        queue.async { _ = try? self.loadedContext(for: model) }
    }

    private func loadedContext(for model: WhisperModel) throws -> OpaquePointer {
        if let context, loadedModelID == model.id { return context }
        guard model.isDownloaded else { throw TranscriptionError.modelMissing(model.title) }
        if let context { whisper_free(context); self.context = nil }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(model.localURL.path, params) else {
            throw TranscriptionError.modelFailed("couldn't load \(model.fileName)")
        }
        context = ctx
        loadedModelID = model.id
        return ctx
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let model = WhisperModel.named(AppSettings.shared.localModelID)
        let engine = "Whisper \(model.title) (local)"
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let ctx = try self.loadedContext(for: model)
                    let text = try self.run(ctx, request: request, model: model)
                    continuation.resume(returning: TranscriptionResult(text: text, engine: engine))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(_ ctx: OpaquePointer, request: TranscriptionRequest, model: WhisperModel) throws -> String {
        var samples = request.samples
        // whisper.cpp wants at least a second of audio; pad short clips with silence.
        let minimum = Int(AudioRecorder.sampleRate * 1.1)
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
        params.no_timestamps = false
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        // whisper.cpp's temperature fallback samples, so the same audio can come back with different words. Tiny
        // (ggml-small) never needs it; the bigger models keep it as a safety net.
        params.temperature_inc = model == WhisperModel.all[2] ? 0 : 0.2
        params.no_speech_thold = 0.6
        params.translate = false

        let englishOnly = model.id.hasSuffix(".en")
        let language: String = englishOnly ? "en" : (request.language == "auto" ? "auto" : request.language)
        let hint = request.vocabulary.promptHint()

        let status: Int32 = language.withCString { langPtr in
            hint.withCString { hintPtr in
                params.language = langPtr
                params.detect_language = false
                params.initial_prompt = hint.isEmpty ? nil : hintPtr
                // Every window is conditioned on the dictionary hint alone. Carrying decoded text forward lets one
                // bad window (silence heard as "Thank you.") poison the rest of a long dictation.
                params.carry_initial_prompt = true
                params.n_max_text_ctx = hint.isEmpty ? 0 : whisper_token_count(ctx, hintPtr) + 1
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else { throw TranscriptionError.modelFailed("whisper_full returned \(status)") }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
            let piece = String(cString: segment)
            if !Vocabulary.isPromptEcho(piece) { text += piece }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
