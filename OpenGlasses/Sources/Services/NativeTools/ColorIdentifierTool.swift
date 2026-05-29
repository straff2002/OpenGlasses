import Foundation
import UIKit

/// Names the dominant color in the glasses view (accessibility — colorblind / low-vision). Computes
/// the average color on-device (no LLM) and maps it to a human name via `ColorNamer`.
@MainActor
final class ColorIdentifierTool: NativeTool {
    let name = "identify_color"
    let description = """
    Name the dominant color of what the user is looking at, using the glasses camera. On-device, no \
    network. Use for "what color is this?", "what colour am I holding?". For colorblind / low-vision support.
    """
    let parametersSchema: [String: Any] = [
        "type": "object", "properties": [:], "required": [] as [String]
    ]

    private let cameraService: CameraService
    init(cameraService: CameraService) { self.cameraService = cameraService }

    func execute(args: [String: Any]) async throws -> String {
        let frame: UIImage?
        if let latest = cameraService.latestFrame {
            frame = latest
        } else {
            frame = (try? await cameraService.capturePhoto()).flatMap { UIImage(data: $0) }
        }
        guard let cg = frame?.cgImage, let color = Self.averageColor(cg) else {
            return "I couldn't read a color. Hold steady on the object and try again."
        }
        return "That looks \(ColorNamer.name(r: color.r, g: color.g, b: color.b))."
    }

    /// Average color of a CGImage by drawing into a 1×1 RGBA context. Returns 0–1 components.
    static func averageColor(_ cgImage: CGImage) -> (r: Double, g: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }
}
