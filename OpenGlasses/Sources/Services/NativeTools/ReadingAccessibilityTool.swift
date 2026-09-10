import Foundation

/// Reading Accessibility tool (A1): captures text through the glasses camera, OCRs it on-device,
/// and returns a mode-specific directive so the assistant can read, simplify, translate, or define
/// it. The assistant's reply streams to TTS through the normal pipeline.
///
/// Privacy-first: OCR runs locally via `OCRService`; the image never leaves the device.
@MainActor
final class ReadingAccessibilityTool: NativeTool {
    let name = "reading_assist"
    let description = """
    Help the user read text in front of them through the glasses camera. Modes: 'read' (clean OCR \
    artifacts and read aloud), 'ask' (answer a specific question about the visible text — e.g. \
    "what's the total?", "when does this expire?", "what's the phone number?" — grounded ONLY in \
    the captured text), 'simplify' (rewrite at a reading level), 'translate' (into a target \
    language), 'define' (plain-language definition of a term). Use when the user says things like \
    'read this to me', 'what does the receipt say the total is', 'simplify this', 'translate this \
    sign', or 'what does this word mean'. Params: mode (required), question (for 'ask'), \
    reading_level (1–5, optional), target_language (e.g. 'es', optional), term (optional, for \
    'define' when the word was spoken rather than captured).
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "description": "'read', 'ask', 'simplify', 'translate', or 'define'."
            ],
            "question": [
                "type": "string",
                "description": "For 'ask': the user's question about the visible text, verbatim."
            ],
            "reading_level": [
                "type": "integer",
                "description": "For 'simplify': 1 (child) to 5 (professional). Defaults to the user's reading profile."
            ],
            "target_language": [
                "type": "string",
                "description": "For 'translate': target language code (e.g. 'es', 'fr'). Defaults to the user's preferred language."
            ],
            "term": [
                "type": "string",
                "description": "For 'define': the spoken term to define. If omitted, the captured text is used."
            ]
        ],
        "required": ["mode"]
    ]

    private let cameraService: any FilteredStillProviding
    private let ocr: OCRService

    init(cameraService: any FilteredStillProviding, ocr: OCRService = OCRService()) {
        self.cameraService = cameraService
        self.ocr = ocr
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.accessibilityModeEnabled else {
            return "Reading Accessibility is disabled. Enable it in Settings → Accessibility."
        }
        guard let modeRaw = args["mode"] as? String, let mode = ReadingMode(rawValue: modeRaw) else {
            return "Specify a mode: 'read', 'simplify', 'translate', or 'define'."
        }

        let level = (args["reading_level"] as? Int).flatMap(ReadingProfile.Level.init(rawValue:))
        let targetLanguage = (args["target_language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let directive = mode.directive(level: level, targetLanguage: targetLanguage)

        // 'define' can work from a spoken term without capturing anything.
        if mode == .define, let term = (args["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            return "\(directive)\n\nTERM:\n\(term)"
        }

        let (text, capturedImage) = await captureAndRecognize()
        guard let text, !text.isEmpty else {
            // Abstain with guidance tailored by a cheap sharpness check: a blurry frame needs a
            // steadier hold; a sharp frame with no text needs a better position. Never invent.
            if let capturedImage, ImageSharpness.isBlurry(capturedImage) {
                return "I couldn't read any text — it looks a bit blurry. Ask the user to hold steady for a moment and try again."
            }
            return "I couldn't read any text. Ask the user to move a little closer, adjust the angle, or improve the lighting, then try again."
        }

        if mode == .ask {
            let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let questionBlock = question.isEmpty ? "" : "\n\nQUESTION:\n\(question)"
            return "\(directive)\n\nCAPTURED TEXT:\n\(text)\(questionBlock)"
        }
        return "\(directive)\n\nCAPTURED TEXT:\n\(text)"
    }

    /// Capture the current frame (or take a photo) and OCR it on-device. Also returns the raw
    /// image that was tried last, so the caller can tailor guidance when no text was found.
    private func captureAndRecognize() async -> (text: String?, imageData: Data?) {
        // On-device OCR — nothing leaves the process, so the on-device scope passes the pixels
        // through untouched. Requested through the chokepoint anyway: that is where the
        // classification is recorded (W04.1). The cached frame is tried first and a fresh
        // photo only if it read nothing, so the two requests stay separate.
        var lastImage: Data?
        if let data = await cameraService.filteredStill(for: .onDeviceVision)
            .jpegData(compressionQuality: 0.9) {
            lastImage = data
            let result = await ocr.recognizeText(in: data)
            if !result.isEmpty { return (result.text, data) }
        }
        guard let data = await cameraService.filteredStill(for: .onDeviceVision, source: .photoOnly)
            .jpegData(compressionQuality: 0.9) else { return (nil, lastImage) }
        let result = await ocr.recognizeText(in: data)
        return (result.isEmpty ? nil : result.text, data)
    }
}
