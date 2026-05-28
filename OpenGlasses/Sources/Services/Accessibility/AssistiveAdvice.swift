import Foundation

/// Structured output of an Assistive Mode (A3) analysis: one calm, concise piece of advice with an
/// urgency level (which drives A2 TTS rate/prefix) and an optional follow-up question.
///
/// The model is asked for strict JSON, but real responses sometimes wrap it in prose or code
/// fences, so `parse` is lenient — it extracts the first JSON object it finds.
struct AssistiveAdvice: Codable, Equatable {
    let advice: String
    let urgency: Urgency
    let followup: String?

    enum Urgency: String, Codable {
        case low, medium, high

        /// Bridge to A2 TTS urgency so distress/unease speaks faster with a cue.
        var speechUrgency: TextToSpeechService.SpeechUrgency {
            switch self {
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            }
        }
    }

    /// Parse advice from a raw model response, tolerating code fences and surrounding prose.
    static func parse(_ raw: String) -> AssistiveAdvice? {
        guard let jsonData = extractJSONObject(from: raw) else { return nil }
        let decoder = JSONDecoder()
        if let advice = try? decoder.decode(AssistiveAdvice.self, from: jsonData) {
            return advice
        }
        // Fallback: urgency may be missing/invalid — try a lenient manual decode.
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let adviceText = obj["advice"] as? String, !adviceText.isEmpty else { return nil }
        let urgency = (obj["urgency"] as? String).flatMap(Urgency.init(rawValue:)) ?? .low
        let followup = (obj["followup"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AssistiveAdvice(advice: adviceText, urgency: urgency, followup: followup)
    }

    /// Extract the first balanced `{...}` JSON object from arbitrary text.
    private static func extractJSONObject(from raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < raw.endIndex {
            let ch = raw[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(raw[start...index]).data(using: .utf8)
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }
}
