import Foundation
import Vision
import CoreGraphics
import UIKit

/// Reusable on-device OCR over Apple Vision. Privacy-first: images never leave the device.
///
/// Shared by the Reading Accessibility feature (A1) and Field Assist's `equipment_lookup` (reading
/// nameplates/error displays). Returns text in reading order plus per-block bounding boxes.
struct OCRService {

    struct Block: Equatable {
        let text: String
        let confidence: Float
        /// Vision-normalized bounding box (origin bottom-left, 0–1).
        let boundingBox: CGRect
    }

    struct Result: Equatable {
        let text: String
        let blocks: [Block]
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Minimum per-observation confidence to keep (0–1).
    var minimumConfidence: Float = 0.3

    init(minimumConfidence: Float = 0.3) {
        self.minimumConfidence = minimumConfidence
    }

    /// Recognize text in image data (e.g. a captured JPEG). Returns an empty result on failure.
    func recognizeText(in data: Data) async -> Result {
        guard let cgImage = UIImage(data: data)?.cgImage else { return Result(text: "", blocks: []) }
        return await recognizeText(in: cgImage)
    }

    /// Recognize text in a CGImage, sorted top-to-bottom then left-to-right (natural reading order).
    func recognizeText(in cgImage: CGImage) async -> Result {
        await withCheckedContinuation { continuation in
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    NSLog("[OCRService] OCR error: %@", error.localizedDescription)
                    return continuation.resume(returning: Result(text: "", blocks: []))
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return continuation.resume(returning: Result(text: "", blocks: []))
                }

                var blocks: [Block] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= self.minimumConfidence else { continue }
                    blocks.append(Block(text: candidate.string,
                                        confidence: candidate.confidence,
                                        boundingBox: observation.boundingBox))
                }

                // Reading order: Vision origin is bottom-left, so higher y = higher on the page.
                blocks.sort { a, b in
                    if abs(a.boundingBox.maxY - b.boundingBox.maxY) < 0.02 {
                        return a.boundingBox.minX < b.boundingBox.minX
                    }
                    return a.boundingBox.maxY > b.boundingBox.maxY
                }

                let text = blocks.map(\.text).joined(separator: "\n")
                continuation.resume(returning: Result(text: text, blocks: blocks))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try handler.perform([request])
            } catch {
                NSLog("[OCRService] VNImageRequestHandler error: %@", error.localizedDescription)
                continuation.resume(returning: Result(text: "", blocks: []))
            }
        }
    }
}
