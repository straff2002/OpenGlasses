import XCTest
@testable import OpenGlasses

/// Issue 427 follow-up: a photo returned by a tool must reach the model as pixels.
///
/// `CapturePhotoTool`, `PhotoLogTool` and `MoneyIdentifierTool` emit
/// `"[IMAGE_CAPTURED:<base64>] <text>"`, and until now **nothing parsed it** — every provider's
/// tool loop appended the base64 as the tool message's text. Field trace (build 371):
/// `toolRun succeeded tool=capture_photo characters=134076` followed 3 ms later by
/// `requestSent count=4 bytes=239548 detail=textOnly`.
final class ToolResultImageTests: XCTestCase {

    /// Real JPEG-ish bytes; only the round-trip matters, not the pixels.
    private let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private var base64: String { payload.base64EncodedString() }

    private func marked(_ trailing: String) -> String {
        "[IMAGE_CAPTURED:\(base64)] \(trailing)"
    }

    // MARK: - extract

    func testNoMarkerLeavesTheTextExactlyAsItCame() {
        let result = ToolResultImage.extract(from: "Photo logged to the session (98 KB).")
        XCTAssertEqual(result.text, "Photo logged to the session (98 KB).")
        XCTAssertNil(result.image)
    }

    func testEmptyStringIsUntouched() {
        let result = ToolResultImage.extract(from: "")
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.image)
    }

    func testMarkerAtStartYieldsTheImageAndTheTrailingText() {
        let result = ToolResultImage.extract(from: marked("Photo captured successfully (98 KB). Analyze the image."))
        XCTAssertEqual(result.image, payload)
        XCTAssertEqual(result.text, "Photo captured successfully (98 KB). Analyze the image.")
        XCTAssertFalse(result.text.contains(base64), "the base64 must never survive into the text")
    }

    func testMarkerWithNoTrailingTextYieldsEmptyText() {
        let result = ToolResultImage.extract(from: "[IMAGE_CAPTURED:\(base64)]")
        XCTAssertEqual(result.image, payload)
        XCTAssertEqual(result.text, "")
    }

    func testMarkerInTheMiddleIsStrippedAndTheSurroundingTextIsJoined() {
        let result = ToolResultImage.extract(from: "Before [IMAGE_CAPTURED:\(base64)] after")
        XCTAssertEqual(result.image, payload)
        XCTAssertEqual(result.text, "Before  after".trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(result.text.contains("IMAGE_CAPTURED"))
    }

    /// Only one image can ride a tool result in any of the provider shapes, so the first wins —
    /// but the others must not vanish without a word.
    func testMultipleMarkersTakeTheFirstStripAllAndSaySo() {
        let second = Data([0x01, 0x02, 0x03]).base64EncodedString()
        let result = ToolResultImage.extract(
            from: "[IMAGE_CAPTURED:\(base64)] middle [IMAGE_CAPTURED:\(second)] end")
        XCTAssertEqual(result.image, payload, "the first decodable image is the one attached")
        XCTAssertFalse(result.text.contains("IMAGE_CAPTURED"), "every marker is stripped")
        XCTAssertTrue(result.text.contains(ToolResultImage.extraImagesNote))
        XCTAssertTrue(result.text.contains("middle"))
        XCTAssertTrue(result.text.contains("end"))
    }

    /// A payload that is not base64 is not known to be an image. Mangling the message would lose
    /// whatever the tool actually said, so the text comes back byte-for-byte.
    func testMalformedBase64LeavesTheTextAlone() {
        let original = "[IMAGE_CAPTURED:!!!not base64!!!] Photo captured."
        let result = ToolResultImage.extract(from: original)
        XCTAssertNil(result.image)
        XCTAssertEqual(result.text, original)
    }

    func testUnterminatedMarkerLeavesTheTextAlone() {
        let original = "[IMAGE_CAPTURED:\(base64) never closed"
        let result = ToolResultImage.extract(from: original)
        XCTAssertNil(result.image)
        XCTAssertEqual(result.text, original)
    }

    func testEmptyPayloadIsNotAnImage() {
        let original = "[IMAGE_CAPTURED:] Photo captured."
        let result = ToolResultImage.extract(from: original)
        XCTAssertNil(result.image)
        XCTAssertEqual(result.text, original)
    }

    /// The exact strings the three emitters produce today.
    func testTheShippedEmitterFormatsAllRoundTrip() {
        let cases = [
            "[IMAGE_CAPTURED:\(base64)] Photo captured successfully (98 KB). Analyze the image to respond to the user.",
            "[IMAGE_CAPTURED:\(base64)] Photo logged to the session (98 KB). Analyze the image to read any values, then continue.",
            "[IMAGE_CAPTURED:\(base64)] Identify the denomination of the banknote.",
        ]
        for text in cases {
            let result = ToolResultImage.extract(from: text)
            XCTAssertEqual(result.image, payload, text)
            XCTAssertFalse(result.text.isEmpty, "the instruction text must survive: \(text)")
            XCTAssertFalse(result.text.contains(base64))
        }
    }

    // MARK: - vision disabled

    func testVisionDisabledNoteReplacesTheImageWithoutResendingBase64() {
        let split = ToolResultImage.extract(from: marked("Photo captured successfully (98 KB)."))
        let omitted = ToolResultImage.textWithImageOmitted(split.text)
        XCTAssertTrue(omitted.contains("Photo captured successfully (98 KB)."))
        XCTAssertTrue(omitted.contains(ToolResultImage.visionDisabledNote))
        XCTAssertFalse(omitted.contains(base64), "the whole point: never send the image as text")
    }

    // MARK: - historyCarriesImage

    func testHistoryCarriesImageRecognisesEveryProviderShape() {
        let anthropic: [[String: Any]] = [["role": "user", "content": [
            ["type": "text", "text": "hi"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
        ]]]
        let openAI: [[String: Any]] = [["role": "user", "content": [
            ["type": "text", "text": "hi"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
        ]]]
        let gemini: [[String: Any]] = [["role": "user", "parts": [
            ["text": "hi"],
            ["inlineData": ["mimeType": "image/jpeg", "data": base64]],
        ]]]

        XCTAssertTrue(ToolResultImage.historyCarriesImage(anthropic))
        XCTAssertTrue(ToolResultImage.historyCarriesImage(openAI))
        XCTAssertTrue(ToolResultImage.historyCarriesImage(gemini))
    }

    func testHistoryCarriesImageIsFalseForPlainText() {
        let plain: [[String: Any]] = [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "what am I looking at"],
            ["role": "tool", "tool_call_id": "c1", "content": "Photo captured successfully."],
        ]
        XCTAssertFalse(ToolResultImage.historyCarriesImage(plain))
    }

    /// The bug in one assertion: base64 sitting in a tool message's *text* is not an image, and
    /// must not be reported as one.
    func testBase64InToolTextIsNotCountedAsAnImage() {
        let smuggled: [[String: Any]] = [
            ["role": "tool", "tool_call_id": "c1", "content": marked("Photo captured.")],
        ]
        XCTAssertFalse(ToolResultImage.historyCarriesImage(smuggled))
    }

    // MARK: - pruning compatibility

    /// Tool images must age out of the history exactly like user images, or every later turn
    /// re-uploads the photo. `pruneImages` keys off the same three shapes this attaches.
    func testEveryAttachedShapeIsPrunedByHistoryHygiene() {
        func history(_ imageBlock: [String: Any], key: String) -> [[String: Any]] {
            let older: [String: Any] = ["role": "user", key: [["type": "text", "text": "old"], imageBlock]]
            let newer: [String: Any] = ["role": "user", key: [["type": "text", "text": "new"], imageBlock]]
            return [older, newer]
        }

        let shapes: [(String, [String: Any], String)] = [
            ("anthropic", ["type": "image",
                           "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]], "content"),
            ("openAI", ["type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(base64)"]], "content"),
            ("gemini", ["inlineData": ["mimeType": "image/jpeg", "data": base64]], "parts"),
        ]

        for (label, block, key) in shapes {
            let pruned = HistoryHygiene.pruneImages(history(block, key: key), keepLast: 1)
            XCTAssertFalse(ToolResultImage.historyCarriesImage([pruned[0]]),
                           "\(label): the older image must be pruned")
            XCTAssertTrue(ToolResultImage.historyCarriesImage([pruned[1]]),
                          "\(label): the newest image must be kept")
        }
    }
}
