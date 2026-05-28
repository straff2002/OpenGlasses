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
    artifacts and read aloud), 'simplify' (rewrite at a reading level), 'translate' (into a target \
    language), 'define' (plain-language definition of a term). Use when the user says things like \
    'read this to me', 'simplify this', 'translate this sign', or 'what does this word mean'. \
    Params: mode (required), reading_level (1–5, optional), target_language (e.g. 'es', optional), \
    term (optional, for 'define' when the word was spoken rather than captured).
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "description": "'read', 'simplify', 'translate', or 'define'."
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

    private let cameraService: CameraService
    private let ocr: OCRService

    init(cameraService: CameraService, ocr: OCRService = OCRService()) {
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

        let text = await captureAndRecognize()
        guard let text, !text.isEmpty else {
            return "I couldn't read any text. Try holding steady, moving closer, or improving the lighting."
        }
        return "\(directive)\n\nCAPTURED TEXT:\n\(text)"
    }

    /// Capture the current frame (or take a photo) and OCR it on-device.
    private func captureAndRecognize() async -> String? {
        if let frame = cameraService.latestFrame, let data = frame.jpegData(compressionQuality: 0.9) {
            let result = await ocr.recognizeText(in: data)
            if !result.isEmpty { return result.text }
        }
        guard let data = try? await cameraService.capturePhoto() else { return nil }
        let result = await ocr.recognizeText(in: data)
        return result.isEmpty ? nil : result.text
    }
}
