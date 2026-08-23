import Foundation

/// The Live API `setup` message body.
///
/// Extracted from `GeminiLiveService` so the payload's **shape** can be pinned by a test. Device-
/// traced 2026-08-23: `contextWindowCompression` was nested inside `realtimeInputConfig`, where the
/// field does not exist. The endpoint rejects a malformed payload wholesale — the socket closed
/// with 1007 before it ever looked at the model or the key — so every Live session failed
/// identically regardless of configuration, and it read as "the API key doesn't work". A key that
/// worked perfectly in Direct mode made that reading very convincing.
///
/// Pure and synchronous: no socket, no `Config` reads, nothing to stub. Everything the shape
/// depends on is a parameter, so a test can assert where each field sits.
enum GeminiLiveSetup {

    /// Sliding-window target for the server-side context compression.
    static let contextTargetTokens = 80_000

    static func body(model: String,
                     responseModalities: [String],
                     systemInstruction: String,
                     tools: [[String: Any]],
                     sessionResumption: [String: Any]) -> [String: Any] {
        var generationConfig: [String: Any] = ["responseModalities": responseModalities]
        // Family-specific, and omitted when unknown — see `GeminiLiveThinkingConfig`. A guessed
        // field here closes the socket rather than being ignored.
        if let thinking = GeminiLiveThinkingConfig.forModel(model) {
            generationConfig["thinkingConfig"] = thinking
        }

        return [
            "model": model,
            "generationConfig": generationConfig,
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "tools": tools,
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": false,
                    "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "silenceDurationMs": 500,
                    "prefixPaddingMs": 40
                ],
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
            ],
            // A sibling of `realtimeInputConfig`, never a member of it. See the type comment.
            "contextWindowCompression": [
                "slidingWindow": ["targetTokens": contextTargetTokens]
            ],
            "inputAudioTranscription": [:] as [String: Any],
            // Plan CJ item 7: always request resumption updates; with a stored handle this
            // resumes the prior session (goAway rotation / network drop) instead of cold-starting.
            "sessionResumption": sessionResumption
        ]
    }
}
