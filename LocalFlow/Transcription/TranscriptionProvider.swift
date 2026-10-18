import Foundation

struct TranscriptionRequest {
    let samples: [Float]          // 16 kHz mono
    let wav: Data                 // same audio as 16-bit WAV, for HTTP uploads
    let vocabulary: Vocabulary
    let language: String          // "auto" or an ISO 639-1 code
    var duration: Double { Double(samples.count) / AudioRecorder.sampleRate }
}

struct TranscriptionResult {
    let text: String
    let engine: String
}

enum TranscriptionError: LocalizedError {
    case noAPIKey(String)
    case http(status: Int, body: String)
    case network(Error)
    case badResponse(String)
    case modelMissing(String)
    case modelFailed(String)
    case cancelled
    case allFailed(primary: Error, fallback: Error?)

    /// Whether another attempt at the same provider could succeed.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .http(let status, _): return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
        case .badResponse: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider): return "No API key for \(provider). Add one in Settings → Transcription."
        case .http(let status, let body):
            // Bodies are usually JSON or an HTML error page; neither belongs in the bar.
            var detail = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            if detail.hasPrefix("{") || detail.hasPrefix("<") || detail.hasPrefix("[") { detail = "" }
            if status == 401 || status == 403 { detail = "the API key was rejected" }
            return "Server error \(status)" + (detail.isEmpty ? "" : ": \(detail)")
        case .network(let error): return error.localizedDescription
        case .badResponse(let why): return "Unexpected response: \(why)"
        case .modelMissing(let title):
            if WhisperModel.all.contains(where: { $0.isDownloaded }) {
                return "Whisper \(title) isn't downloaded. Pick a downloaded model in Settings → Transcription."
            }
            return "No local Whisper model downloaded yet. Pick one in Settings → Transcription."
        case .modelFailed(let why): return "Local model failed: \(why)"
        case .cancelled: return "Cancelled"
        case .allFailed(let primary, let fallback):
            if let fallback { return "\(primary.localizedDescription) Fallback also failed: \(fallback.localizedDescription)" }
            return primary.localizedDescription
        }
    }
}

/// Anything that turns audio into text. Add a provider by conforming to this and registering it in `CloudProviderID`.
protocol TranscriptionProvider {
    var name: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

/// Shared HTTP helpers for cloud providers.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse("not HTTP") }
            if !(200..<300).contains(http.statusCode) {
                throw TranscriptionError.http(status: http.statusCode, body: String(decoding: data.prefix(2000), as: UTF8.self))
            }
            return (data, http)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            if (error as? URLError)?.code == .cancelled { throw TranscriptionError.cancelled }
            throw TranscriptionError.network(error)
        }
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.badResponse("not JSON")
        }
        return obj
    }

    struct Multipart {
        let boundary = "LocalFlow-\(UUID().uuidString)"
        private var body = Data()

        mutating func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }

        mutating func file(_ name: String, filename: String, mime: String, data: Data) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        func finish() -> Data {
            var out = body
            out.append("--\(boundary)--\r\n".data(using: .utf8)!)
            return out
        }

        var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    }
}
