import Foundation

/// Diarizes a **recorded** audio file by uploading it to Deepgram's prerecorded API and grouping
/// the returned words into per-speaker turns. Used for meeting recordings that weren't streamed
/// live. The parsing/grouping is the unit-tested pure core (`DeepgramResponseParser` +
/// `SpeakerSegmentMerger`); this wraps it in the upload. Device/network-pending.
struct DeepgramBatchService {
    enum BatchError: LocalizedError {
        case notConfigured
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Deepgram diarization is not configured."
            case .http(let code, let body): return "Deepgram batch HTTP \(code): \(body)"
            case .badResponse: return "Deepgram returned an unreadable response."
            }
        }
    }

    /// Upload `fileURL`'s audio and return its diarized speaker turns.
    /// - Parameter mimeType: e.g. `audio/m4a`, `audio/wav` — matches the recording's container.
    func diarize(fileURL: URL, mimeType: String = "audio/m4a") async throws -> [SpeakerTurn] {
        let key = Config.deepgramAPIKey
        guard !key.isEmpty, !Config.hipaaMode, let url = Config.deepgramBatchURL else {
            throw BatchError.notConfigured
        }

        let audio = try Data(contentsOf: fileURL)
        return try await diarize(audioData: audio, mimeType: mimeType, key: key, url: url)
    }

    /// Testable seam: upload raw bytes (lets the upload be exercised without a file on disk).
    func diarize(audioData: Data, mimeType: String, key: String, url: URL) async throws -> [SpeakerTurn] {
        try MedicalEgressGuard.check(.deepgramBatchTranscription)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BatchError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BatchError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BatchError.badResponse
        }
        let words = DeepgramResponseParser.parseBatchWords(json)
        return SpeakerSegmentMerger.groupWords(words)
    }
}
