import Foundation

/// Where a custom Whisper model comes from: a Hugging Face file link or a ggml `.bin` already on this Mac.
/// Pure Foundation so the URL rules and the file check can be tested without AppKit.
enum ModelSource {
    enum Problem: Error, Equatable {
        case notAURL
        case notHuggingFace
        case notAFile          // a repo or folder page, not a file
        case notBin            // the file isn't a ggml .bin
    }

    struct HuggingFaceFile: Equatable {
        let repo: String       // "ggerganov/whisper.cpp"
        let revision: String   // "main"
        let fileName: String   // "ggml-base.en.bin"
        let downloadURL: URL   // https://huggingface.co/<repo>/resolve/<rev>/<file>
    }

    /// Accepts `https://huggingface.co/<owner>/<repo>/resolve/<rev>/<path>.bin` and the `/blob/` page link for the
    /// same file (rewritten to `/resolve/`). Query strings (`?download=true`) and `hf.co` are fine too.
    static func parseHuggingFace(_ text: String) -> Result<HuggingFaceFile, Problem> {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .failure(.notAURL) }
        if !raw.contains("://") { raw = "https://" + raw }
        guard var parts = URLComponents(string: raw), let host = parts.host?.lowercased() else { return .failure(.notAURL) }
        guard ["huggingface.co", "www.huggingface.co", "hf.co"].contains(host) else { return .failure(.notHuggingFace) }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // <owner> <repo> (resolve|blob) <rev> <path…>
        guard segments.count >= 5, segments[2] == "resolve" || segments[2] == "blob" else { return .failure(.notAFile) }
        let repo = segments[0] + "/" + segments[1]
        let revision = segments[3]
        let path = segments[4...].joined(separator: "/")
        guard let fileName = segments.last, fileName.lowercased().hasSuffix(".bin"), fileName.count > 4 else { return .failure(.notBin) }
        parts.scheme = "https"
        parts.host = "huggingface.co"
        parts.port = nil
        parts.path = "/\(repo)/resolve/\(revision)/\(path)"
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { return .failure(.notAURL) }
        return .success(HuggingFaceFile(repo: repo, revision: revision, fileName: fileName, downloadURL: url))
    }

    /// whisper.cpp only loads its own ggml format: the file starts with 0x67676d6c ("ggml") as a little-endian
    /// uint32, i.e. the bytes "lmgg". GGUF Whisper files don't exist for whisper.cpp yet, so nothing else passes.
    static let ggmlMagic: UInt32 = 0x6767_6d6c

    static func hasGgmlMagic(_ header: Data) -> Bool {
        guard header.count >= 4 else { return false }
        let bytes = [UInt8](header.prefix(4))
        let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return value == ggmlMagic
    }

    static func isGgmlModel(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return hasGgmlMagic((try? handle.read(upToCount: 4)) ?? Data())
    }

    /// "ggml-base.en.bin" → "base.en"; what a custom row is called.
    static func displayName(forFile fileName: String) -> String {
        var name = fileName
        if name.lowercased().hasSuffix(".bin") { name = String(name.dropLast(4)) }
        if name.lowercased().hasPrefix("ggml-") { name = String(name.dropFirst(5)) }
        return name.isEmpty ? fileName : name
    }

    static let notWhisperMessage = "This file isn't a Whisper ggml model."

    /// One custom model as remembered between launches.
    struct CustomRecord: Codable, Equatable, Identifiable {
        let id: String
        let fileName: String
        var bytes: Int64
        let sourceURL: URL?
    }

    /// "huggingface.co/ggerganov/whisper.cpp" for a row caption.
    static func shortSource(_ url: URL) -> String {
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let host = url.host, segments.count >= 2 else { return url.absoluteString }
        return "\(host)/\(segments[0])/\(segments[1])"
    }
}
