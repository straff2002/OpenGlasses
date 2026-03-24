import Foundation
import Vision
import UIKit
import CoreImage
import NaturalLanguage

/// Captures a photo from the glasses camera, performs OCR using Vision framework,
/// and returns the extracted text with detected language. If the text is not in the
/// user's device language, includes a note so the LLM can auto-translate.
final class DocumentScanTool: NativeTool, @unchecked Sendable {
    let name = "scan_document"
    let description = "Scan a document or text visible through the glasses camera. Captures a photo, extracts text via OCR, detects the language, and returns it. Auto-flags foreign text for translation. Use when the user says 'read this', 'scan this document', 'what does this say', or 'extract text'."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "enhance": [
                "type": "boolean",
                "description": "Apply image enhancement for distant or low-contrast text. Default true."
            ],
            "translate": [
                "type": "boolean",
                "description": "Auto-translate if text is in a foreign language. Default true."
            ]
        ],
        "required": [] as [String]
    ]

    private let cameraService: CameraService

    init(cameraService: CameraService) {
        self.cameraService = cameraService
    }

    func execute(args: [String: Any]) async throws -> String {
        let enhance = (args["enhance"] as? Bool) ?? true
        let autoTranslate = (args["translate"] as? Bool) ?? true

        // Capture photo from glasses
        let photoData: Data
        do {
            photoData = try await cameraService.capturePhoto()
        } catch {
            return "Could not capture photo from glasses camera: \(error.localizedDescription). Make sure glasses are connected."
        }

        guard let uiImage = UIImage(data: photoData), let cgImage = uiImage.cgImage else {
            return "Failed to process the captured image."
        }

        // Optionally enhance for better OCR
        let finalCGImage: CGImage
        if enhance {
            finalCGImage = enhanceForOCR(cgImage) ?? cgImage
        } else {
            finalCGImage = cgImage
        }

        // Perform OCR
        let extractedText = await performOCR(on: finalCGImage)

        if extractedText.isEmpty {
            return "No text detected in the image. Try holding the document closer or in better lighting."
        }

        let charCount = extractedText.count
        let lineCount = extractedText.components(separatedBy: "\n").count

        // Detect language
        let detectedLanguage = detectLanguage(extractedText)
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let isForeign = detectedLanguage != nil && detectedLanguage != deviceLanguage

        var result = "Scanned \(lineCount) lines (\(charCount) characters)"
        if let lang = detectedLanguage {
            let langName = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            result += ", language: \(langName)"
        }
        result += ":\n\n\(extractedText)"

        if isForeign && autoTranslate {
            let targetLang = Locale.current.localizedString(forLanguageCode: deviceLanguage) ?? "English"
            result += "\n\n[The text appears to be in a foreign language. Please translate it to \(targetLang) for the user.]"
        }

        return result
    }

    // MARK: - Language Detection

    private func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    // MARK: - OCR

    private func performOCR(on cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    NSLog("[DocumentScan] OCR error: %@", error.localizedDescription)
                    continuation.resume(returning: "")
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                // Filter by confidence and sort in reading order (top-to-bottom, left-to-right)
                var blocks: [(text: String, y: CGFloat, x: CGFloat)] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.3 else { continue }
                    let box = observation.boundingBox
                    blocks.append((
                        text: candidate.string,
                        y: box.origin.y + box.height,
                        x: box.origin.x
                    ))
                }

                // Sort: higher y first (Vision origin is bottom-left), then left-to-right
                blocks.sort { a, b in
                    if abs(a.y - b.y) < 0.02 {
                        return a.x < b.x
                    }
                    return a.y > b.y
                }

                let fullText = blocks.map(\.text).joined(separator: "\n")
                NSLog("[DocumentScan] OCR extracted %d blocks, %d chars", blocks.count, fullText.count)
                continuation.resume(returning: fullText)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try handler.perform([request])
            } catch {
                NSLog("[DocumentScan] VNImageRequestHandler error: %@", error.localizedDescription)
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Image Enhancement

    private func enhanceForOCR(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        var processed = ciImage

        // Increase contrast
        if let contrast = CIFilter(name: "CIColorControls") {
            contrast.setValue(processed, forKey: kCIInputImageKey)
            contrast.setValue(1.3, forKey: kCIInputContrastKey)
            contrast.setValue(1.0, forKey: kCIInputSaturationKey)
            contrast.setValue(0.0, forKey: kCIInputBrightnessKey)
            if let output = contrast.outputImage {
                processed = output
            }
        }

        // Sharpen text edges
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(processed, forKey: kCIInputImageKey)
            unsharp.setValue(1.5, forKey: kCIInputRadiusKey)
            unsharp.setValue(1.0, forKey: kCIInputIntensityKey)
            if let output = unsharp.outputImage {
                processed = output
            }
        }

        let context = CIContext()
        return context.createCGImage(processed, from: processed.extent)
    }
}
