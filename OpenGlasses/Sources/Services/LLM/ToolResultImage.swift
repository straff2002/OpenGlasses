import Foundation

/// Pulls a captured photo back out of a tool's text result so it can be sent to the model as
/// **pixels** rather than as a wall of base64.
///
/// Issue 427 follow-up. `CapturePhotoTool`, `PhotoLogTool` and `MoneyIdentifierTool` all return
/// `"[IMAGE_CAPTURED:<base64>] <text>"`, and nothing in the app ever parsed that marker — so every
/// provider's tool loop appended ~134k characters of base64 as the tool message's *text*. The model
/// was handed a transcript of an image it could not see, the turn logged `textOnly`, and a
/// vision-capable model answered a photo question from nothing. Field trace (build 371):
/// `toolRun succeeded characters=134076` immediately followed by `requestSent bytes=239548
/// detail=textOnly`.
///
/// Pure and headless on purpose: the marker grammar is the contract between the three emitters and
/// the four provider loops, and it is the kind of thing that only ever breaks silently.
enum ToolResultImage {

    /// Opening delimiter written by the emitting tools. The payload runs to the next `]`, which is
    /// unambiguous because `]` is not in the base64 alphabet.
    static let marker = "[IMAGE_CAPTURED:"

    /// Appended when a single result carried more than one image. Only the first is attached —
    /// the provider shapes below all model "one image per tool result" — so say so rather than
    /// dropping the others silently.
    static let extraImagesNote = "(note: this result carried more than one image; only the first is attached.)"

    /// Split a tool result into the text the model should read and the image it should see.
    ///
    /// - Returns: the result text with every marker removed and trimmed, plus the first image that
    ///   decoded. When no marker is present — or when nothing in it decodes as base64 — the text is
    ///   returned **exactly as it came in** and `image` is `nil`: an undecodable payload is not
    ///   known to be an image, and silently eating it would lose whatever the tool actually said.
    static func extract(from text: String) -> (text: String, image: Data?) {
        guard text.contains(marker) else { return (text, nil) }

        var remaining = text
        var firstImage: Data?
        var markersFound = 0

        while let start = remaining.range(of: marker) {
            guard let close = remaining[start.upperBound...].firstIndex(of: "]") else {
                // An unterminated marker is malformed; leave the rest of the string alone.
                break
            }
            markersFound += 1
            let payload = String(remaining[start.upperBound..<close])
            if firstImage == nil, let decoded = Data(base64Encoded: payload), !decoded.isEmpty {
                firstImage = decoded
            }
            remaining.removeSubrange(start.lowerBound...close)
        }

        // Nothing usable came out: hand back the original, untouched.
        guard firstImage != nil else { return (text, nil) }

        var cleaned = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if markersFound > 1 {
            cleaned = cleaned.isEmpty ? extraImagesNote : cleaned + " " + extraImagesNote
        }
        return (cleaned, firstImage)
    }

    /// The line substituted for the image when the model configuration cannot accept one.
    ///
    /// The base64 must never be sent as text in this case either — that is the whole bug. The
    /// model is told plainly that there was an image and that it cannot see it, which is what
    /// stops it from inventing a description.
    static let visionDisabledNote = "(image omitted: vision is disabled for this model)"

    /// The tool result text to send when an image was extracted but the model cannot receive it.
    static func textWithImageOmitted(_ text: String) -> String {
        text.isEmpty ? visionDisabledNote : text + "\n" + visionDisabledNote
    }

    /// The one-line user-turn caption that carries a tool's image on the chat-shaped providers
    /// (OpenAI-compatible and ChatGPT), whose `tool` messages cannot hold image parts.
    static func attachmentCaption(toolName: String) -> String {
        "[Attached: the photo returned by \(toolName).]"
    }

    /// Whether an already-built message array carries an image part in any provider shape.
    ///
    /// Used to keep the `requestSent` log honest: before this, a request was reported `withImage`
    /// only when the *user turn* carried a photo, so a tool-returned image — the entire point of
    /// `capture_photo` — was logged as `textOnly` even once it was being sent correctly.
    static func historyCarriesImage(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            let blocks = (message["content"] as? [[String: Any]])
                ?? (message["parts"] as? [[String: Any]])
                ?? []
            return blocks.contains(where: isImageBlock)
        }
    }

    /// An image block in any of the shapes the shared history holds: Anthropic (`type: image`),
    /// OpenAI-compatible / ChatGPT (`type: image_url`), Gemini (`inlineData`). Deliberately the
    /// same three-shape rule `HistoryHygiene.isImageBlock` prunes on — a shape one of them
    /// recognised and the other did not would either re-upload forever or report dishonestly.
    private static func isImageBlock(_ block: [String: Any]) -> Bool {
        if let type = block["type"] as? String, type == "image" || type == "image_url" { return true }
        return block["inlineData"] != nil
    }
}
