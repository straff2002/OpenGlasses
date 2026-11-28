import Foundation

/// Lightweight, local detector that determines if a user query is vision-related
/// (needs camera input) or text-only (no camera needed).
///
/// Used by Smart Camera Activation to auto-activate the glasses camera only when
/// the query would benefit from visual input, saving battery and improving privacy.
///
/// This is purely keyword/pattern-based — no API calls, no latency.
struct VisionIntentDetector {

    enum CameraIntent {
        case vision      // Query needs camera input
        case textOnly    // Query can be answered without vision
    }

    /// Determine if a transcript needs camera input.
    /// Errs on the side of activation — false negatives (missing a vision query)
    /// are worse than false positives (unnecessarily activating the camera).
    static func classify(_ transcript: String) -> CameraIntent {
        let lower = transcript.lowercased()

        // A meter's reading said aloud ("the voltage show me 125 V", build 799) asks for no look:
        // its "show me" is not a trigger, though any other phrase in it still is.
        let readout = ShowMeReadout.isReadout(transcript)

        // Direct vision trigger phrases
        for phrase in visionPhrases {
            if readout, phrase == "show me" { continue }
            if lower.contains(phrase) { return .vision }
        }

        // Deictic references to something visual ("this", "that", "these", "those" + visual context)
        for deictic in deicticPatterns {
            if lower.contains(deictic) { return .vision }
        }

        // Single-word queries that are almost always visual
        let words = lower.split(separator: " ")
        if words.count <= 3 {
            for trigger in shortVisionTriggers {
                if lower.contains(trigger) { return .vision }
            }
        }

        return .textOnly
    }

    // MARK: - Keyword Lists

    /// Phrases that strongly indicate a vision-related query.
    private static let visionPhrases: [String] = [
        // Direct camera/vision requests
        "look at", "looking at", "what do you see", "what can you see",
        "what am i looking at", "what is this", "what's this", "what is that", "what's that",
        "what are these", "what are those",
        "show me", "describe what", "tell me what you see",
        "in front of me", "ahead of me", "around me",

        // Reading/text recognition
        "read this", "read that", "read the", "what does it say", "what does this say",
        "what does that say", "read the sign", "read the menu", "read the label",
        "what's written", "what is written",

        // Object/scene identification
        "identify this", "identify that", "recognize this", "recognize that",
        "what kind of", "what type of", "what brand", "what model",
        "what plant", "what flower", "what bird", "what animal", "what bug", "what insect",
        "what painting", "what artwork", "who painted", "who made",

        // Spatial/navigation
        "where am i", "what building", "what street", "what store",
        "which way", "how far", "how do i get",

        // Food/product
        "what food", "what dish", "how many calories", "what ingredients",
        "how much does", "what's the price", "what's it cost",

        // QR/barcode
        "scan this", "scan that", "scan the code", "scan the barcode", "scan the qr",

        // Translation of visible text
        "translate this", "translate that", "translate the sign", "translate the menu",
        "what language is",

        // Color/appearance
        "what color", "what colour",

        // Explicit camera
        "take a look", "check this out", "see this", "see that",
        "can you see", "do you see",
    ]

    /// Deictic references combined with action words that suggest visual context.
    private static let deicticPatterns: [String] = [
        "this is", "that is", "these are", "those are",
        "is this", "is that", "are these", "are those",
        "about this", "about that",
        "here is", "over here", "over there", "right here", "right there",
    ]

    /// Short queries (1-3 words) that are almost always visual.
    private static let shortVisionTriggers: [String] = [
        "this", "that", "what's this", "what's that",
        "read", "scan", "look", "see", "describe",
    ]
}
