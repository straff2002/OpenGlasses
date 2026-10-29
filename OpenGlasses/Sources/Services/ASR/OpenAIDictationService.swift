import Foundation

// MARK: - Request (pure)

/// The OpenAI transcription request for one dictation turn (Plan JM P2). Pure: the WAV encoding,
/// the multipart body and the prompt are built and tested without a network.
///
/// Whole-utterance: the question's audio is uploaded once, when the turn ends, with the OpenAI
/// **API key**. A ChatGPT sign-in is a chat backend's token and cannot reach this endpoint.
enum OpenAIDictationRequest {

    static let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// OpenAI's recommended model for recorded speech. It replaced `gpt-4o-transcribe`, which OpenAI
    /// removes on 2027-02-26 (Plan KC P2). Its `json` reply adds `languages` beside `text`;
    /// `transcript(from:)` reads only `text`.
    static let model = "gpt-transcribe"
    /// The rate the audio is uploaded at: plenty for speech, and a third of a 48 kHz capture.
    static let uploadSampleRate = 16_000
    /// The vocabulary rides in `prompt`. Bounded so a large vault cannot turn the prompt into an
    /// essay; the vocabulary is ordered most-specific first, so the bound trims the generic end.
    static let maxPromptCharacters = 800
    /// The longest question uploaded. Far past any question; it stops a stuck turn from uploading
    /// minutes of a room, and keeps the body well inside the endpoint's own size limit.
    static let maxSeconds: Double = 120
    static let requestTimeout: TimeInterval = 30

    /// The vocabulary joined by ", ", whole terms only, within `maxPromptCharacters`.
    static func prompt(from vocabulary: [String]) -> String {
        var seen = Set<String>()
        var prompt = ""
        for raw in vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let next = prompt.isEmpty ? term : prompt + ", " + term
            guard next.count <= maxPromptCharacters else { break }
            prompt = next
        }
        return prompt
    }

    /// 16-bit little-endian mono PCM in a RIFF/WAVE container.
    static func wav(samples: [Float], sampleRate: Int) -> Data {
        let pcm = PCMConverter.linear16(fromMono: samples)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteRate = sampleRate * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // PCM fmt chunk size
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// The form fields, in order. `prompt` is left out when there is no vocabulary.
    static func fields(vocabulary: [String]) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [("model", model), ("response_format", "json")]
        let prompt = prompt(from: vocabulary)
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        return fields
    }

    static func multipartBody(wav: Data, fields: [(name: String, value: String)], boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(contentsOf: Array((text + "\r\n").utf8)) }
        for field in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(field.name)\"")
            line("")
            line(field.value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"question.wav\"")
        line("Content-Type: audio/wav")
        line("")
        body.append(wav)
        line("")
        line("--\(boundary)--")
        return body
    }

    static func make(wav: Data, apiKey: String, vocabulary: [String],
                     boundary: String = "avenkin-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(wav: wav, fields: fields(vocabulary: vocabulary), boundary: boundary)
        return request
    }

    /// The transcript from a `json` response, or nil when the body is not one.
    static func transcript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The transcript with each code from the vocabulary in the vocabulary's own spelling.
    ///
    /// `gpt-transcribe` hears a part number as well as `gpt-4o-transcribe` did but never writes its
    /// hyphen ("XR7720" for "XR-7720", "R454B" for "R-454B"), whatever the prompt says, and the
    /// manual index matches the printed spelling. A transcript word that equals a vocabulary term
    /// once letters and digits are all that is compared takes the term's spelling. Codes only (a
    /// letter and a digit, at least three of them, no spaces), whole words only, and a key two
    /// vocabulary spellings share is left as transcribed.
    static func restoringVocabularySpellings(in text: String, vocabulary: [String]) -> String {
        func key<S: StringProtocol>(_ word: S) -> String { word.uppercased().filter { $0.isLetter || $0.isNumber } }
        var spellings: [String: String] = [:]
        var ambiguous = Set<String>()
        for raw in vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let termKey = key(term)
            guard termKey.count >= 3, termKey != term.uppercased(), !term.contains(where: \.isWhitespace),
                  termKey.contains(where: \.isNumber), termKey.contains(where: \.isLetter) else { continue }
            if let known = spellings[termKey], known != term { ambiguous.insert(termKey) } else { spellings[termKey] = term }
        }
        for termKey in ambiguous { spellings[termKey] = nil }
        guard !spellings.isEmpty else { return text }

        var out = ""
        var word = ""
        func flush() {
            if !word.isEmpty, let spelling = spellings[key(word)] { out += spelling } else { out += word }
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "-" { word.append(character) }
            else { flush(); out.append(character) }
        }
        flush()
        return out
    }
}

/// Why an OpenAI dictation upload did not produce a transcript. Each case names a fixed token for
/// `PrivacyLog`; none carries the response body.
enum OpenAIDictationError: Error, Equatable, LocalizedError {
    case notAllowed
    case noKey
    case noAudio
    case tooLong
    case http(Int)
    case unreadableResponse

    var token: String {
        switch self {
        case .notAllowed: return "notAllowed"
        case .noKey: return "noKey"
        case .noAudio: return "noAudio"
        case .tooLong: return "tooLong"
        case .http(let status): return "http\(status)"
        case .unreadableResponse: return "unreadableResponse"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAllowed: return "Cloud dictation isn't available right now."
        case .noKey: return "No OpenAI API key is saved for dictation."
        case .noAudio: return "There was no audio to transcribe."
        case .tooLong: return "The question was too long to transcribe."
        case .http(let status): return "OpenAI couldn't transcribe the question (HTTP \(status))."
        case .unreadableResponse: return "OpenAI's transcription reply couldn't be read."
        }
    }
}

// MARK: - Transport

/// One upload per dictation turn to OpenAI's transcription endpoint (Plan JM P2). The gate is read
/// immediately before the request is built, so a HIPAA flip or a revoked choice between the end of
/// the question and the upload keeps the audio on the phone. One attempt: a failure is reported,
/// never retried in a loop.
@MainActor
final class OpenAIDictationService {

    var isAllowed: () -> Bool = { CloudDictationGate.live.isConfigured(provider: .openAI) }
    var apiKey: () -> String = { Config.dictationOpenAIKey }
    /// The transport. A seam so tests answer locally.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    func transcribe(samples: [Float], sampleRate: Double, vocabulary: [String]) async throws -> String {
        guard isAllowed() else { throw OpenAIDictationError.notAllowed }
        try MedicalEgressGuard.check(.openAIDictation)
        let key = apiKey()
        guard !key.isEmpty else { throw OpenAIDictationError.noKey }
        guard !samples.isEmpty, sampleRate > 0 else { throw OpenAIDictationError.noAudio }
        guard Double(samples.count) / sampleRate <= OpenAIDictationRequest.maxSeconds else {
            throw OpenAIDictationError.tooLong
        }

        let target = OpenAIDictationRequest.uploadSampleRate
        let resampled = PCMConverter.resample(samples, from: sampleRate, to: Double(target))
        let wav = OpenAIDictationRequest.wav(samples: resampled, sampleRate: target)
        let request = OpenAIDictationRequest.make(wav: wav, apiKey: key, vocabulary: vocabulary)
        PrivacyLog.speech(.cloudDictation, .started, bytes: wav.count, detail: PrivacyToken("openAI"))

        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIDictationError.http(status) }
        guard let text = OpenAIDictationRequest.transcript(from: data) else {
            throw OpenAIDictationError.unreadableResponse
        }
        return OpenAIDictationRequest.restoringVocabularySpellings(in: text, vocabulary: vocabulary)
    }
}
