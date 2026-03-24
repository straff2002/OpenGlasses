import Foundation
import Vision
import UIKit
import CoreImage
import Combine

/// Automatically detects and blurs bystander faces in video frames.
/// Can be applied to recorded/streamed video for privacy compliance in public spaces.
@MainActor
class PrivacyFilterService: ObservableObject {
    @Published var isEnabled = false
    @Published var facesBlurredCount: Int = 0

    /// Blur radius for face anonymization
    var blurRadius: Double = 20.0

    /// Known face IDs to NOT blur (the user's saved faces)
    var exemptFaceprints: [[Float]] = []

    private let ciContext = CIContext()

    // MARK: - Public API

    /// Process a UIImage and return it with bystander faces blurred.
    /// Returns the original image if no faces detected or filtering is disabled.
    func processFrame(_ image: UIImage) -> UIImage {
        guard isEnabled else { return image }
        guard let cgImage = image.cgImage else { return image }

        // Detect faces
        let faceRects = detectFaces(in: cgImage)
        guard !faceRects.isEmpty else { return image }

        // Apply blur to each face region
        guard let blurred = blurFaces(in: image, faceRects: faceRects) else { return image }
        facesBlurredCount += faceRects.count
        return blurred
    }

    /// Process a frame from the publisher pipeline (for recording/streaming).
    /// Returns a new publisher that applies the privacy filter.
    func filteredPublisher(from source: PassthroughSubject<UIImage, Never>) -> AnyPublisher<UIImage, Never> {
        if isEnabled {
            return source
                .receive(on: DispatchQueue.global(qos: .userInitiated))
                .map { [weak self] image -> UIImage in
                    // Can't access @MainActor self from background, so do sync processing
                    guard let cgImage = image.cgImage else { return image }
                    let service = self
                    let faceRects = service?.detectFacesSync(in: cgImage) ?? []
                    guard !faceRects.isEmpty else { return image }
                    return service?.blurFaces(in: image, faceRects: faceRects) ?? image
                }
                .eraseToAnyPublisher()
        } else {
            return source.eraseToAnyPublisher()
        }
    }

    // MARK: - Face Detection

    private func detectFaces(in cgImage: CGImage) -> [CGRect] {
        return detectFacesSync(in: cgImage)
    }

    private nonisolated func detectFacesSync(in cgImage: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let results = request.results else { return [] }

            // Convert normalized rects to image coordinates
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)

            return results.map { face in
                let box = face.boundingBox
                // Vision uses bottom-left origin, flip to top-left
                return CGRect(
                    x: box.origin.x * imageWidth,
                    y: (1 - box.origin.y - box.height) * imageHeight,
                    width: box.width * imageWidth,
                    height: box.height * imageHeight
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Face Blurring

    private nonisolated func blurFaces(in image: UIImage, faceRects: [CGRect]) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let imageSize = ciImage.extent.size

        // Create a blurred version of the entire image
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(20.0, forKey: kCIInputRadiusKey)

        guard let blurredImage = blurFilter.outputImage else { return nil }

        // Crop blurred image to original bounds (blur expands edges)
        let croppedBlurred = blurredImage.cropped(to: ciImage.extent)

        // Create a composite: original image with blurred face regions
        var result = ciImage
        let ciContext = CIContext()

        for faceRect in faceRects {
            // Expand face rect slightly for better coverage
            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)

            // Convert to CIImage coordinates (flip Y)
            let ciRect = CGRect(
                x: expanded.origin.x,
                y: imageSize.height - expanded.origin.y - expanded.height,
                width: expanded.width,
                height: expanded.height
            )

            // Create an oval mask for natural face shape
            _ = CIVector(x: ciRect.origin.x, y: ciRect.origin.y,
                         z: ciRect.width, w: ciRect.height)

            // Use a radial gradient as an elliptical mask
            guard let radialGradient = CIFilter(name: "CIRadialGradient") else { continue }
            let center = CIVector(x: ciRect.midX, y: ciRect.midY)
            radialGradient.setValue(center, forKey: "inputCenter")
            radialGradient.setValue(min(ciRect.width, ciRect.height) * 0.4, forKey: "inputRadius0")
            radialGradient.setValue(max(ciRect.width, ciRect.height) * 0.55, forKey: "inputRadius1")
            radialGradient.setValue(CIColor.white, forKey: "inputColor0")
            radialGradient.setValue(CIColor.clear, forKey: "inputColor1")

            guard let maskImage = radialGradient.outputImage else { continue }

            // Blend blurred face region with original using mask
            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { continue }
            blendFilter.setValue(croppedBlurred, forKey: kCIInputImageKey)
            blendFilter.setValue(result, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

            if let blended = blendFilter.outputImage {
                result = blended.cropped(to: ciImage.extent)
            }
        }

        // Render final image
        guard let outputCGImage = ciContext.createCGImage(result, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
