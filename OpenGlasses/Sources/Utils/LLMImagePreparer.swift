import UIKit

enum LLMImagePreparer {
    static let maxLongEdge: CGFloat = 2576
    static let maxBytes = 4_500_000
    static let minLongEdge = 32

    struct Limits {
        let maxLongEdge: CGFloat
        let maxBytes: Int
        let qualitySteps: [CGFloat]
        let compressEnabled: Bool
    }

    static var limits: Limits {
        switch Config.llmImagePreset {
        case "off":
            return Limits(
                maxLongEdge: .greatestFiniteMagnitude,
                maxBytes: Int.max,
                qualitySteps: [1.0],
                compressEnabled: false
            )
        case "balanced":
            return Limits(
                maxLongEdge: 1568,
                maxBytes: 1_500_000,
                qualitySteps: [0.75, 0.6, 0.5, 0.4, 0.3, 0.2],
                compressEnabled: true
            )
        case "compact":
            return Limits(
                maxLongEdge: 1024,
                maxBytes: 800_000,
                qualitySteps: [0.65, 0.5, 0.4, 0.3, 0.25, 0.2],
                compressEnabled: true
            )
        case "custom":
            return Limits(
                maxLongEdge: CGFloat(Config.llmImageCustomMaxLongEdge),
                maxBytes: Config.llmImageCustomMaxBytes,
                qualitySteps: qualityLadder(from: Config.llmImageCustomJPEGQuality),
                compressEnabled: true
            )
        default:
            return Limits(
                maxLongEdge: maxLongEdge,
                maxBytes: maxBytes,
                qualitySteps: [0.8, 0.65, 0.5, 0.35, 0.25, 0.2],
                compressEnabled: true
            )
        }
    }

    static func isDegenerate(_ data: Data) -> Bool {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return true }
        return max(cg.width, cg.height) < minLongEdge
    }

    static func prepared(_ data: Data) -> Data {
        let limits = Self.limits
        guard limits.compressEnabled else { return data }
        guard let image = UIImage(data: data), let cg = image.cgImage else { return data }
        let pxLongEdge = CGFloat(max(cg.width, cg.height))
        let edgeCap = limits.maxLongEdge
        let byteCap = limits.maxBytes

        if data.count <= byteCap && pxLongEdge <= edgeCap { return data }

        let resized = pxLongEdge > edgeCap ? downscale(cg, toLongEdge: edgeCap) : image

        for quality in limits.qualitySteps {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= byteCap {
                return jpeg
            }
        }
        return resized.jpegData(compressionQuality: 0.2) ?? data
    }

    private static func qualityLadder(from initial: CGFloat) -> [CGFloat] {
        var steps: [CGFloat] = []
        var quality = min(1.0, max(0.2, initial))
        while quality >= 0.2 {
            steps.append(quality)
            quality = (quality - 0.15).rounded(toPlaces: 2)
        }
        if steps.last != 0.2 { steps.append(0.2) }
        return steps
    }

    private static func downscale(_ cg: CGImage, toLongEdge longEdge: CGFloat) -> UIImage {
        let pxLongEdge = CGFloat(max(cg.width, cg.height))
        let scale = longEdge / pxLongEdge
        let target = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let source = UIImage(cgImage: cg)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let divisor = pow(10.0, CGFloat(places))
        return (self * divisor).rounded() / divisor
    }
}
