import Foundation

/// The cloud services Local Flow knows about. To add one: add a case, its models, and a `TranscriptionProvider`.
enum CloudProviderID: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case elevenLabs = "elevenlabs"
    case gemini = "gemini"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .elevenLabs: return "ElevenLabs"
        case .gemini: return "Google Gemini"
        }
    }

    var keychainAccount: String { "\(rawValue).apiKey" }

    /// Environment variable names whose values are this provider's key, in order of preference.
    var environmentVariables: [String] {
        switch self {
        case .openAI: return ["OPENAI_API_KEY"]
        case .elevenLabs: return ["ELEVENLABS_API_KEY", "ELEVEN_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        }
    }

    var keyURL: URL {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    var models: [(id: String, title: String)] {
        switch self {
        case .openAI: return [
            ("gpt-4o-transcribe", "gpt-4o-transcribe (best)"),
            ("gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe (faster)"),
            ("whisper-1", "whisper-1"),
        ]
        case .elevenLabs: return [("scribe_v2", "Scribe v2"), ("scribe_v1", "Scribe v1")]
        case .gemini: return [
            ("gemini-3.5-flash", "Gemini 3.5 Flash (fast)"),
            ("gemini-2.5-pro", "Gemini 2.5 Pro"),
            ("gemini-2.5-flash", "Gemini 2.5 Flash"),
        ]
        }
    }

    var defaultModel: String { models[0].id }

    /// "Scribe v2" for scribe_v2; the picker's "(best)"/"(fast)" notes are dropped.
    func modelTitle(_ id: String) -> String {
        let title = models.first { $0.id == id }?.title ?? id
        return title.replacingOccurrences(of: " \\(.*\\)$", with: "", options: .regularExpression)
    }

    var apiKey: String? { Keychain.get(keychainAccount) }

    func makeProvider(model: String) -> TranscriptionProvider {
        switch self {
        case .openAI: return OpenAITranscriber(model: model)
        case .elevenLabs: return ElevenLabsTranscriber(model: model)
        case .gemini: return GeminiTranscriber(model: model)
        }
    }
}

struct OpenAITranscriber: TranscriptionProvider {
    let model: String
    var name: String { "OpenAI \(model)" }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let key = CloudProviderID.openAI.apiKey else { throw TranscriptionError.noAPIKey("OpenAI") }
        var form = HTTP.Multipart()
        form.field("model", model)
        form.field("response_format", "json")
        form.field("temperature", "0")
        if request.language != "auto" { form.field("language", request.language) }
        let hint = request.vocabulary.promptHint()
        if !hint.isEmpty { form.field("prompt", hint) }
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: request.wav)

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finish()
        let (data, _) = try await HTTP.send(req)
        guard let text = try HTTP.json(data)["text"] as? String else { throw TranscriptionError.badResponse("missing text") }
        return TranscriptionResult(text: text, engine: name)
    }
}

struct ElevenLabsTranscriber: TranscriptionProvider {
    let model: String
    var name: String { "ElevenLabs \(model)" }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let key = CloudProviderID.elevenLabs.apiKey else { throw TranscriptionError.noAPIKey("ElevenLabs") }
        var form = HTTP.Multipart()
        form.field("model_id", model)
        form.field("tag_audio_events", "false")
        form.field("diarize", "false")
        if request.language != "auto" { form.field("language_code", request.language) }
        for term in request.vocabulary.keyterms(limit: 100) { form.field("keyterms", term) }
        form.file("file", filename: "audio.wav", mime: "audio/wav", data: request.wav)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finish()
        let (data, _) = try await HTTP.send(req)
        guard let text = try HTTP.json(data)["text"] as? String else { throw TranscriptionError.badResponse("missing text") }
        return TranscriptionResult(text: text, engine: name)
    }
}

struct GeminiTranscriber: TranscriptionProvider {
    let model: String
    var name: String { "Gemini \(model)" }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let key = CloudProviderID.gemini.apiKey else { throw TranscriptionError.noAPIKey("Gemini") }
        var prompt = "Transcribe this audio exactly as spoken. Output only the transcript, nothing else. If there is no speech, output nothing."
        if request.language != "auto" { prompt += " The language is \(request.language)." }
        let hint = request.vocabulary.promptHint()
        if !hint.isEmpty { prompt += " Spellings to use when these are said: " + hint }
        let body: [String: Any] = [
            "contents": [["parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "audio/wav", "data": request.wav.base64EncodedString()]],
            ]]],
            "generationConfig": ["temperature": 0],
        ]
        let text = try await Gemini.generate(body: body, model: model, key: key)
        return TranscriptionResult(text: text, engine: name)
    }
}

/// One short chat completion; Mixture of experts uses it to merge the transcripts.
enum OpenAIChat {
    /// Newest small GPT model in /v1/models at the time of writing; a merge needs no reasoning, so effort is off.
    static let mergeModel = "gpt-5.4-mini"

    static func complete(_ prompt: String, model: String = mergeModel, key: String) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": prompt]]]
        if model.hasPrefix("gpt-5") { body["reasoning_effort"] = "none" } else { body["temperature"] = 0 }
        do {
            return try await send(body, key: key)
        } catch TranscriptionError.http(400, _) where body["reasoning_effort"] != nil {
            body["reasoning_effort"] = nil   // an older gpt-5 snapshot that only knows "minimal"
            return try await send(body, key: key)
        }
    }

    private static func send(_ body: [String: Any], key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await HTTP.send(req)
        guard let choices = try HTTP.json(data)["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw TranscriptionError.badResponse("missing content") }
        return text
    }
}

enum Gemini {
    static func generate(body: [String: Any], model: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await HTTP.send(req)
        let json = try HTTP.json(data)
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw TranscriptionError.badResponse(message)
            }
            if (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil { return "" }
            throw TranscriptionError.badResponse("no candidates")
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
