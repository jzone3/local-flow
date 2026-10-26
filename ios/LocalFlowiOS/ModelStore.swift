import Foundation

/// The one speech model the iPhone app uses ("Classic": large-v3-turbo, 5-bit). Downloaded once from Hugging Face.
@MainActor
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    nonisolated static let fileName = "ggml-large-v3-turbo-q5_0.bin"
    nonisolated static let bytes: Int64 = 574_041_195
    nonisolated static let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!

    nonisolated static var localURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    nonisolated static var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    @Published private(set) var isDownloaded = FileManager.default.fileExists(atPath: ModelStore.localURL.path)
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func download() {
        guard task == nil, !isDownloaded else { return }
        error = nil
        progress = 0
        task = session.downloadTask(with: Self.url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.bytes
        Task { @MainActor in self.progress = Double(totalBytesWritten) / Double(expected) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        var failure: String?
        if status != 200 {
            failure = "Download failed (HTTP \(status))."
        } else if size != Self.bytes {
            failure = "Download was incomplete. Try again."
        } else {
            // The temp file is gone once this returns, so move it now.
            var destination = Self.localURL
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? destination.setResourceValues(values)
            } catch { failure = error.localizedDescription }
        }
        Task { @MainActor in
            self.task = nil
            self.progress = nil
            self.error = failure
            if failure == nil { self.isDownloaded = true }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in
            self.task = nil
            self.progress = nil
            self.error = error.localizedDescription
        }
    }
}
