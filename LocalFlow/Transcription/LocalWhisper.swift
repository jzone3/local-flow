import Combine
import Foundation
import whisper

/// A Whisper model the user can pick: one of the three built-in tiers, or a custom ggml file they added from a
/// Hugging Face link or from this Mac. Best is the default; the others trade accuracy for size.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let title: String
    let fileName: String
    let detail: String
    let bytes: Int64
    /// Where to download it from; nil for a custom model copied in from a local file.
    let url: URL?
    let isCustom: Bool

    /// The whisper.cpp name without the ggml-/.bin wrapping ("large-v3-turbo-q5_0"), for people who know the models.
    var shortName: String {
        var name = fileName
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        if name.hasSuffix(".bin") { name.removeLast(4) }
        return name
    }

    private init(id: String, title: String, file: String, detail: String, bytes: Int64) {
        self.id = id
        self.title = title
        fileName = "ggml-\(file).bin"
        self.detail = detail
        self.bytes = bytes
        url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(file).bin")!
        isCustom = false
    }

    init(custom record: ModelSource.CustomRecord) {
        id = record.id
        title = ModelSource.displayName(forFile: record.fileName)
        fileName = record.fileName
        detail = record.sourceURL.map { "Custom · " + ModelSource.shortSource($0) } ?? "Custom · added from this Mac"
        bytes = record.bytes
        url = record.sourceURL
        isCustom = true
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo", title: "Best", file: "large-v3-turbo", detail: "Most accurate. Still instant on Apple silicon.", bytes: 1_624_555_275),
        WhisperModel(id: "large-v3-turbo-q5_0", title: "Classic", file: "large-v3-turbo-q5_0", detail: "Same model, a third of the size. Nearly as accurate.", bytes: 574_041_195),
        WhisperModel(id: "small", title: "Tiny", file: "small", detail: "Small and fast. Fine for short notes and older Macs.", bytes: 487_601_967),
    ]

    static let recommended = all[0]

    /// The models the user added themselves (Settings → Transcription → Custom model…).
    static var custom: [WhisperModel] { CustomModelStore.shared.records.map(WhisperModel.init(custom:)) }

    /// Built-ins first, then custom models in the order they were added.
    static var allIncludingCustom: [WhisperModel] { all + custom }

    /// The model dictation actually uses: the selected one, or — if that isn't on disk (defaults reset, file deleted) —
    /// the first downloaded one, so having a model never fails for the sake of a stale selection.
    static var active: WhisperModel {
        let selected = named(AppSettings.shared.localModelID)
        if selected.isDownloaded { return selected }
        return allIncludingCustom.first { $0.isDownloaded } ?? selected
    }

    /// Older builds stored other model IDs; those map to the nearest tier.
    static func named(_ id: String) -> WhisperModel {
        allIncludingCustom.first { $0.id == id } ?? (["large-v3", "medium.en", "medium"].contains(id) ? recommended : id.hasPrefix("small") || id.hasPrefix("base") ? all[2] : recommended)
    }

    static var directory: URL {
        let dir = AppSettings.supportDirectory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localURL: URL { WhisperModel.directory.appendingPathComponent(fileName) }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// The Tiny tier used to be ggml-base; nothing loads that file any more (unless the user added it as a custom model).
    static func removeRetiredFiles() {
        guard !custom.contains(where: { $0.fileName == "ggml-base.bin" }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("ggml-base.bin"))
    }
}

/// The list of custom models, kept in UserDefaults. The files themselves live next to the built-ins in Models/.
final class CustomModelStore: ObservableObject {
    static let shared = CustomModelStore()
    private static let key = "customModels"

    @Published private(set) var records: [ModelSource.CustomRecord] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: Self.key) }
    }

    private init() {
        records = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ModelSource.CustomRecord].self, from: $0) } ?? []
    }

    /// Why a file name can't be added, or nil when it can.
    static func conflict(fileName: String, builtIns: [WhisperModel] = WhisperModel.all, customNames: [String]) -> String? {
        if let tier = builtIns.first(where: { $0.fileName == fileName }) { return "That's the built-in \(tier.title) model. Download it from the list above." }
        if customNames.contains(fileName) { return "That model is already in the list." }
        return nil
    }

    func conflict(fileName: String) -> String? { Self.conflict(fileName: fileName, customNames: records.map(\.fileName)) }

    @discardableResult
    func add(fileName: String, bytes: Int64, sourceURL: URL?) -> WhisperModel {
        let record = ModelSource.CustomRecord(id: "custom:" + fileName, fileName: fileName, bytes: bytes, sourceURL: sourceURL)
        records.removeAll { $0.id == record.id }
        records.append(record)
        return WhisperModel(custom: record)
    }

    func remove(id: String) { records.removeAll { $0.id == id } }

    func updateBytes(id: String, bytes: Int64) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].bytes != bytes else { return }
        records[index].bytes = bytes
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
        guard tasks[model.id] == nil, !model.isDownloaded, let url = model.url else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    /// Removes the file. A custom model loses its row too; a built-in just goes back to "Download".
    func delete(_ model: WhisperModel) {
        cancel(model)
        try? FileManager.default.removeItem(at: model.localURL)
        LocalWhisper.shared.unloadIfCurrent(model)
        if model.isCustom {
            CustomModelStore.shared.remove(id: model.id)
            errors[model.id] = nil
        }
        installedVersion += 1
        // Keep the selection on a model that exists, or dictation fails until the user notices the radio.
        if AppSettings.shared.localModelID == model.id,
           let next = WhisperModel.all.first(where: { $0.isDownloaded }) {
            AppSettings.shared.localModelID = next.id
        }
    }

    /// A ggml file already on this Mac: copied into the Models folder and listed as a custom model.
    func addLocalFile(_ source: URL) -> String? {
        let fileName = source.lastPathComponent
        if let conflict = CustomModelStore.shared.conflict(fileName: fileName) { return conflict }
        guard ModelSource.isGgmlModel(at: source) else { return ModelSource.notWhisperMessage }
        let destination = WhisperModel.directory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch { return error.localizedDescription }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        let model = CustomModelStore.shared.add(fileName: fileName, bytes: bytes, sourceURL: nil)
        finishedInstalling(model.id)
        return nil
    }

    /// A Hugging Face file: listed right away, then downloaded like a built-in.
    func addRemote(_ file: ModelSource.HuggingFaceFile, bytes: Int64) -> String? {
        if let conflict = CustomModelStore.shared.conflict(fileName: file.fileName) { return conflict }
        let model = CustomModelStore.shared.add(fileName: file.fileName, bytes: bytes, sourceURL: file.downloadURL)
        installedVersion += 1
        download(model)
        return nil
    }

    private func finishedInstalling(_ id: String) {
        installedVersion += 1
        // A fresh install picks "Best" by default; if that one isn't on disk, the model just fetched becomes the active one.
        if !WhisperModel.named(AppSettings.shared.localModelID).isDownloaded {
            AppSettings.shared.localModelID = id
        }
        LocalWhisper.shared.preload()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : WhisperModel.named(id).bytes
            self.progress[id] = Double(totalBytesWritten) / Double(max(expected, 1))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The temp file is gone once this returns, so move it before hopping to the main actor.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlow-\(UUID().uuidString).bin")
        var failure: String?
        if status != 200 {
            failure = "Download failed (HTTP \(status))."
        } else if !ModelSource.isGgmlModel(at: location) {
            failure = ModelSource.notWhisperMessage
        } else {
            do { try FileManager.default.moveItem(at: location, to: staging) } catch { failure = error.localizedDescription }
        }
        Task { @MainActor in
            let model = WhisperModel.named(id)
            if failure == nil {
                do {
                    try? FileManager.default.removeItem(at: model.localURL)
                    try FileManager.default.moveItem(at: staging, to: model.localURL)
                } catch { failure = error.localizedDescription }
            }
            try? FileManager.default.removeItem(at: staging)
            self.tasks[id] = nil
            self.progress[id] = nil
            self.errors[id] = failure
            if failure == nil {
                if model.isCustom, let size = try? FileManager.default.attributesOfItem(atPath: model.localURL.path)[.size] as? Int64 {
                    CustomModelStore.shared.updateBytes(id: id, bytes: size)
                }
                self.finishedInstalling(id)
            } else {
                self.installedVersion += 1
            }
            if failure == nil, AppSettings.shared.localModelID == id { LocalWhisper.shared.preload() }
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
    /// Which model is loaded and ready, readable off the whisper queue so a dictation can say "Loading model…" up front.
    private let readyLock = NSLock()
    private var readyModelID: String?
    private func setReady(_ id: String?) { readyLock.lock(); readyModelID = id; readyLock.unlock() }
    func isReady(_ model: WhisperModel) -> Bool { readyLock.lock(); defer { readyLock.unlock() }; return readyModelID == model.id }

    var name: String { "Whisper \(loadedModelID ?? AppSettings.shared.localModelID) (local)" }
    /// Called on the main thread with `true` while a dictation waits for the model to load, then `false`.
    var onModelLoading: ((Bool) -> Void)?

    deinit { if let context { whisper_free(context) } }

    func unloadIfCurrent(_ model: WhisperModel) {
        queue.sync {
            guard loadedModelID == model.id, let context else { return }
            whisper_free(context)
            self.context = nil
            loadedModelID = nil
            setReady(nil)
        }
    }

    /// Loads the selected model ahead of time so the first dictation doesn't pay the load cost.
    func preload() {
        let model = WhisperModel.active
        guard model.isDownloaded else { return }
        queue.async { _ = try? self.loadedContext(for: model) }
    }

    private func loadedContext(for model: WhisperModel) throws -> OpaquePointer {
        if let context, loadedModelID == model.id { return context }
        guard model.isDownloaded else { throw TranscriptionError.modelMissing(model.title) }
        if let context { whisper_free(context); self.context = nil; setReady(nil) }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(model.localURL.path, params) else {
            throw TranscriptionError.modelFailed("couldn't load \(model.fileName)")
        }
        context = ctx
        loadedModelID = model.id
        setReady(model.id)
        return ctx
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let model = WhisperModel.active
        let engine = "Whisper \(model.title) (local)"
        // Decided before queueing: a preload still running on the queue also counts as "loading".
        let needsLoad = !isReady(model)
        if needsLoad { DispatchQueue.main.async { self.onModelLoading?(true) } }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let loaded = { if needsLoad { DispatchQueue.main.async { self.onModelLoading?(false) } } }
                do {
                    let ctx = try self.loadedContext(for: model)
                    loaded()
                    let text = try self.run(ctx, request: request, model: model)
                    continuation.resume(returning: TranscriptionResult(text: text, engine: engine))
                } catch {
                    loaded()
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

        var pieces: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
            let piece = String(cString: segment)
            if hint.isEmpty || !Vocabulary.isPromptEcho(piece) { pieces.append(piece) }
        }
        return TextCleanup.dropTrailingSilenceEcho(pieces).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
