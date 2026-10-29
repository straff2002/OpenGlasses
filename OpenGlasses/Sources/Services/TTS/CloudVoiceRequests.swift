import Foundation

/// The OpenAI, xAI and Gemini speech requests, built as values (Plan ID item 5, Plan JZ). `TextToSpeechService` sends
/// them; building them here keeps the request shape — the address, the bearer, the body — testable
/// without a network and without the audio session.
///
/// The credential travels only in the `Authorization` header, never in the URL, and each request
/// goes to the vendor's own fixed address: a custom base URL saved on an LLM model is never
/// followed, because a voice request is not a chat request and the key must not be sent to a
/// server it was not issued by.
enum CloudVoiceRequests {

    // MARK: OpenAI

    static let openAISpeechURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// A fixed model: the small speech model is the one priced for spoken replies.
    static let openAISpeechModel = "gpt-4o-mini-tts"
    /// OpenAI publishes no voice list endpoint, so the picker offers its fixed set.
    static let openAIVoices = ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable",
                               "marin", "nova", "onyx", "sage", "shimmer", "verse"]
    static let defaultOpenAIVoice = "coral"

    /// POST the reply text to OpenAI's speech endpoint for MP3 audio, which `AVAudioPlayer` plays
    /// as it plays ElevenLabs's.
    static func openAISpeech(text: String, apiKey: String, voice: String) throws -> URLRequest {
        var request = URLRequest(url: openAISpeechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": openAISpeechModel,
            "input": text,
            "voice": openAIVoices.contains(voice) ? voice : defaultOpenAIVoice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: xAI

    static let xaiSpeechURL = URL(string: "https://api.x.ai/v1/tts")!
    static let xaiVoiceCatalogURL = URL(string: "https://api.x.ai/v1/tts/voices")!
    static let defaultXAIVoice = "ara"

    /// POST the reply text to xAI's speech endpoint for MP3 audio. The language is left to the
    /// endpoint, as a reply can be in any language the wearer speaks.
    static func xaiSpeech(text: String, credential: String, voice: String) throws -> URLRequest {
        var request = URLRequest(url: xaiSpeechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "text": text,
            "voice_id": trimmed.isEmpty ? defaultXAIVoice : trimmed,
            "language": "auto",
            "output_format": ["codec": "mp3"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// GET the voices the xAI credential may use, for the picker.
    static func xaiVoiceCatalog(credential: String) -> URLRequest {
        var request = URLRequest(url: xaiVoiceCatalogURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A voice from xAI's catalog.
    struct XAIVoice: Identifiable, Hashable, Decodable {
        let voiceId: String
        let name: String?
        let gender: String?

        var id: String { voiceId }

        /// The picker's label: the name, with the gender when the catalog gives one.
        var label: String {
            let shown = (name?.isEmpty == false ? name : nil) ?? voiceId
            guard let gender, !gender.isEmpty else { return shown }
            return "\(shown) — \(gender)"
        }

        enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
            case name
            case gender
        }
    }

    private struct XAIVoicesResponse: Decodable {
        let voices: [XAIVoice]
    }

    /// The catalog's voices, without any entry missing an id.
    static func parseXAIVoices(_ data: Data) throws -> [XAIVoice] {
        try JSONDecoder().decode(XAIVoicesResponse.self, from: data).voices
            .filter { !$0.voiceId.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Gemini (Plan JZ)

    /// The speech model used until the wearer picks one from their key's list: the lighter
    /// current model, because a spoken reply values speed over studio fidelity. It reads the text
    /// as a verbatim transcript, so a reply that says "say it cheerfully" is spoken, not obeyed.
    static let defaultGeminiSpeechModel = "gemini-3.8-flash-lite-tts"
    /// The prebuilt voices. Google's larger voice library needs its own request, so the picker
    /// offers this fixed set.
    static let geminiVoices = ["Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede",
                               "Autonoe", "Callirrhoe", "Charon", "Despina", "Enceladus", "Erinome",
                               "Fenrir", "Gacrux", "Iapetus", "Kore", "Laomedeia", "Leda", "Orus",
                               "Puck", "Pulcherrima", "Rasalgethi", "Sadachbia", "Sadaltager",
                               "Schedar", "Sulafat", "Umbriel", "Vindemiatrix", "Zephyr",
                               "Zubenelgenubi"]
    static let defaultGeminiVoice = "Kore"

    static let geminiModelsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!

    /// Whether a model id is a speech model safe to put in the request's path. The id goes into
    /// the URL, and a saved setting or a server's list is not trusted with that: only letters,
    /// digits, `.`, `-` and `_`, and `tts` as a word of its own (`gemini-3.8-flash-tts`, never
    /// `gemini-3.8-flash-image` or an id that merely contains the letters).
    static func isGeminiSpeechModelID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) })
        else { return false }
        return id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" }).contains("tts")
    }

    /// Google's own address for the speech model, never a base URL saved on a Gemini model. An id
    /// that is not a safe speech-model id is the default model.
    static func geminiSpeechURL(model: String) -> URL {
        let safe = isGeminiSpeechModelID(model) ? model : defaultGeminiSpeechModel
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(safe):generateContent")!
    }

    /// POST the reply text to the Gemini speech model for audio. The key travels in
    /// `x-goog-api-key`: the Gemini chat path puts it in the URL's query, where a logged URL
    /// would carry it; this request does not. The language is left to the model, which detects it.
    static func geminiSpeech(text: String, apiKey: String, model: String, voice: String) throws -> URLRequest {
        var request = URLRequest(url: geminiSpeechURL(model: model))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": geminiVoices.contains(voice) ? voice : defaultGeminiVoice
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// GET the models the Gemini key may use, for the speech-model picker. The key travels in
    /// `x-goog-api-key`, as for the speech request.
    static func geminiSpeechModelCatalog(apiKey: String) -> URLRequest {
        var request = URLRequest(url: geminiModelsURL)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A speech model from the key's list.
    struct GeminiSpeechModel: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    private struct GeminiModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String?
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]?
    }

    /// The speech models in the key's list, and nothing else. The list also carries chat, image,
    /// embedding and Live models. What a model is for is the classifier's call (`ModelKind.speech`,
    /// Plan KA P1), as for every other picker; the id must still pass the URL-safety check, since
    /// it goes into the request's path, and the model must answer `generateContent`, the method
    /// the speech request calls.
    static func parseGeminiSpeechModels(_ data: Data) throws -> [GeminiSpeechModel] {
        let response = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        var seen = Set<String>()
        return (response.models ?? []).compactMap { model -> GeminiSpeechModel? in
            guard let name = model.name else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            let methods = model.supportedGenerationMethods.map(Set.init)
            guard ModelKindClassifier.kind(provider: .gemini, id: id,
                                           metadata: ModelListMetadata(generationMethods: methods)) == .speech,
                  isGeminiSpeechModelID(id),
                  methods?.contains("generateContent") == true,
                  seen.insert(id).inserted else { return nil }
            let shown = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return GeminiSpeechModel(id: id, displayName: shown.isEmpty ? id : shown)
        }
        .sorted { $0.id < $1.id }
    }
}

/// The Gemini speech model's answer, made playable (Plan JZ). Pure, so both shapes Google sends are
/// tested without a network.
///
/// The audio is base64 in `candidates[0].content.parts[].inlineData`. The 3.8 models answer a
/// single request with a complete WAV; the earlier preview models answer with headerless 16-bit
/// mono PCM labelled like `audio/L16;codec=pcm;rate=24000`. A WAV plays as it is; PCM is given a
/// WAV header at the rate its label names, so `AVAudioPlayer` plays both as it plays Kokoro's.
enum GeminiSpeechAudio {

    enum Failure: Error, Equatable {
        /// A 200 with no audio part: the candidate finished for safety or another reason.
        case noAudio
        /// The audio part's bytes were not base64.
        case undecodable
        /// An audio format this player does not take (MP3, Opus, A-law…). Never guessed at.
        case unsupportedFormat(String)
    }

    /// The rate the models speak at when a PCM label names none.
    static let defaultSampleRate = 24_000

    private struct Response: Decodable {
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let inlineData: InlineData? }
        struct InlineData: Decodable {
            let mimeType: String?
            let data: String?
        }
        let candidates: [Candidate]?
    }

    /// WAV bytes from a 200 answer, or a `Failure`.
    static func playableAudio(from data: Data) throws -> Data {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let inline = response.candidates?.first?.content?.parts?
                .compactMap(\.inlineData)
                .first(where: { ($0.mimeType ?? "").lowercased().hasPrefix("audio/") && $0.data != nil }),
              let encoded = inline.data else {
            throw Failure.noAudio
        }
        guard let audio = Data(base64Encoded: encoded), !audio.isEmpty else {
            throw Failure.undecodable
        }
        return try playable(audio, mimeType: inline.mimeType ?? "")
    }

    /// A WAV passes through; L16/PCM is wrapped at its stated rate; anything else is refused.
    static func playable(_ audio: Data, mimeType: String) throws -> Data {
        if audio.starts(with: Array("RIFF".utf8)) { return audio }
        let parts = mimeType.lowercased().split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.first ?? ""
        guard type == "audio/l16" || type == "audio/pcm" else {
            throw Failure.unsupportedFormat(type)
        }
        let rate = parts.lazy
            .compactMap { $0.hasPrefix("rate=") ? Int($0.dropFirst("rate=".count)) : nil }
            .first(where: { $0 > 0 }) ?? defaultSampleRate
        return wav(pcm16Mono: audio, sampleRate: rate)
    }

    /// A 44-byte RIFF header in front of 16-bit little-endian mono PCM. An odd trailing byte (half
    /// a sample) is dropped.
    static func wav(pcm16Mono pcm: Data, sampleRate: Int) -> Data {
        let samples = pcm.count / 2 * 2
        var data = Data(capacity: 44 + samples)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + samples))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))                 // PCM chunk size
        appendLE(UInt16(1))                  // PCM
        appendLE(UInt16(1))                  // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))     // byte rate
        appendLE(UInt16(2))                  // block align
        appendLE(UInt16(16))                 // bits per sample
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(samples))
        data.append(pcm.prefix(samples))
        return data
    }
}

/// Which saved credential each of the new cloud voices may use (Plan ID item 5). Pure over the
/// saved models, apart from asking the xAI sign-in for a token.
enum CloudVoiceCredentials {

    /// The OpenAI API key for the speech endpoint: the first saved OpenAI model whose address is
    /// OpenAI's own and that carries a key, else the legacy single-provider key.
    ///
    /// A ChatGPT sign-in never counts. It is a different provider here (`.chatgpt`), and the speech
    /// endpoint refuses a subscription token anyway: the voice is paid from API credit. A key saved
    /// on an OpenAI model pointed at another server belongs to that server and is never sent to
    /// OpenAI.
    static func openAIKey(savedModels: [ModelConfig], legacyKey: String) -> String {
        for model in savedModels where model.llmProvider == .openai && isHost(model.baseURL, "api.openai.com") {
            let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return legacyKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key on the first saved xAI model that carries one, or empty.
    static func xaiModelKey(savedModels: [ModelConfig]) -> String {
        for model in savedModels where model.llmProvider == .xai && isHost(model.baseURL, "x.ai") {
            let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return ""
    }

    /// The key on the first saved Gemini model whose address is Google's own and that carries one,
    /// or empty (Plan JZ). A key saved on a Gemini model pointed at another server belongs to that
    /// server and is never sent to Google. The Vertex sign-in is a different provider here
    /// (`.geminiVertex`), with another host and a bearer token, and never counts.
    static func geminiKey(savedModels: [ModelConfig]) -> String {
        for model in savedModels
        where model.llmProvider == .gemini && isHost(model.baseURL, "generativelanguage.googleapis.com") {
            let key = model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return ""
    }

    /// Where the xAI voice's credential comes from: a typed key wins, else the connected account.
    enum XAISource: Equatable {
        case modelKey
        case account
        case none
    }

    static func xaiSource(savedModels: [ModelConfig], accountConnected: Bool) -> XAISource {
        if !xaiModelKey(savedModels: savedModels).isEmpty { return .modelKey }
        return accountConnected ? .account : .none
    }

    /// The bearer for an xAI voice request: the saved key, else the account's (refreshed) token,
    /// else empty — the same order `XAIAuth` gives the chat route.
    @MainActor
    static func resolveXAICredential(savedModels: [ModelConfig], account: XAIOAuthService) async -> String {
        await XAIAuth.resolveCredential(apiKey: xaiModelKey(savedModels: savedModels), account: account)
    }

    /// Whether a saved base URL is the vendor's own host (or a subdomain of it). An empty base URL
    /// means the provider default, which is.
    static func isHost(_ baseURL: String, _ vendorHost: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == vendorHost || host.hasSuffix("." + vendorHost)
    }
}
