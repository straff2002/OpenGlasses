import Accelerate
import CoreVideo
import UIKit

/// Plan HW P1 — a pixel buffer turned into a picture without the GPU.
///
/// Two callers need this and for the same reason. `VideoDecoder` hands over what VideoToolbox
/// decoded, and `GlassesFramePipeline` hands over a raw frame the SDK's own helper could not
/// draw. Both have to work with the phone locked.
///
/// Deliberately **not** Core Image. A `CIContext` renders through Metal, and iOS denies GPU
/// access to a backgrounded app ("GPU access is denied while the app is in the background") —
/// so with the screen locked every decode would succeed and every `createCGImage` return nil.
/// The app would see only the held last-good frame and the stall detector would rebuild, every
/// 1.5 s, a decoder that is not broken. Decoding with the screen locked is the whole reason
/// the decoder asks for the software specification, so the conversion has to be free of the
/// same gate. The SDK's `makeUIImage()` is behind that gate too, which is how a raw frame comes
/// to need this.
///
/// Three formats are handled, all on the CPU. 32BGRA is what the decoder's session asks for, and
/// needs no arithmetic. The two bi-planar 4:2:0 formats (`420v`, video range, and `420f`, full
/// range) are what a camera pipeline most often hands over when it is not asked for anything in
/// particular; nobody has yet seen which of the three the glasses send as raw, so all of them
/// are covered and anything else is reported by name rather than guessed at.
enum PixelBufferImageConverter {

    enum Outcome {
        case image(UIImage)
        /// A pixel format this converter has no rule for. Carries the format so the caller can
        /// say which.
        case unsupportedFormat(OSType)
        /// A format it does handle, and the conversion still produced nothing: the buffer would
        /// not lock, had no base address, or was a shape the arithmetic refused.
        case failed(OSType)
    }

    static func convert(_ pixelBuffer: CVPixelBuffer) -> Outcome {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let image: UIImage?
        switch format {
        case kCVPixelFormatType_32BGRA:
            image = bgraImage(from: pixelBuffer)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            image = biPlanarImage(from: pixelBuffer, fullRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            image = biPlanarImage(from: pixelBuffer, fullRange: true)
        default:
            return .unsupportedFormat(format)
        }
        return image.map(Outcome.image) ?? .failed(format)
    }

    /// A pixel format as something a log line can carry: its four characters (`420v`, `BGRA`)
    /// when they are all letters and digits, and the number in hex when they are not. Several
    /// formats are small integers rather than text (`32ARGB` is 32), and a log token admits
    /// only letters, digits and `_ . -`.
    static func name(ofFormat format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
        let readable = bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
        }
        return readable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", format)
    }

    // MARK: - 32BGRA

    /// The decoder's session asks for 32BGRA, IOSurface-backed buffers, so a `CGContext` laid
    /// straight over the locked base address is a pure-CPU conversion. `makeImage()` copies the
    /// pixels out, which is what lets the buffer go back to its pool the moment we unlock.
    private static func bgraImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return image(overBGRA: baseAddress,
                     width: CVPixelBufferGetWidth(pixelBuffer),
                     height: CVPixelBufferGetHeight(pixelBuffer),
                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
    }

    private static func image(overBGRA pixels: UnsafeMutableRawPointer, width: Int, height: Int,
                              bytesPerRow: Int) -> UIImage? {
        // BGRA in memory is little-endian 32-bit ARGB, and the alpha byte of a video frame is
        // opaque, so premultiplied is the honest description of it.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(data: pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let cgImage = context.makeImage() else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Bi-planar 4:2:0

    /// Which arithmetic turns this buffer's luma and chroma into red, green and blue. The buffer
    /// says so itself in its matrix attachment. Rec. 601 is honoured when it is named; anything
    /// else, and a buffer that names nothing, is read as Rec. 709, which is what high-definition
    /// video uses and the nearest of the two for the wider-gamut matrices vImage has no constant
    /// for.
    static func usesRec601(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
              let name = matrix as? String else {
            return false
        }
        return name == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    }

    /// vImage does the arithmetic on the CPU: one pass over the two planes into a BGRA buffer of
    /// our own, which then becomes a picture the same way a 32BGRA buffer does.
    private static func biPlanarImage(from pixelBuffer: CVPixelBuffer, fullRange: Bool) -> UIImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var luma = vImage_Buffer(
            data: lumaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        var chroma = vImage_Buffer(
            data: chromaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))

        // Video range keeps luma in 16...235 and chroma in 16...240; full range uses all eight
        // bits. Reading one as the other is a washed-out or a crushed picture, not an error.
        var range = fullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255,
                                      CbCrRangeMax: 255, YpMax: 255, YpMin: 0,
                                      CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235,
                                      CbCrRangeMax: 240, YpMax: 235, YpMin: 16,
                                      CbCrMax: 240, CbCrMin: 16)
        guard let matrix = usesRec601(pixelBuffer)
            ? kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
            : kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 else {
            return nil
        }
        var conversion = vImage_YpCbCrToARGB()
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
            matrix, &range, &conversion, kvImage420Yp8_CbCr8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }

        let bytesPerRow = width * 4
        guard let pixels = malloc(bytesPerRow * height) else { return nil }
        defer { free(pixels) }
        var destination = vImage_Buffer(data: pixels, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: bytesPerRow)

        // vImage writes A, R, G, B; this order of them is B, G, R, A in memory, which is the
        // layout the 32BGRA path already knows how to make a picture from.
        let bgraOrder: [UInt8] = [3, 2, 1, 0]
        guard vImageConvert_420Yp8_CbCr8ToARGB8888(
            &luma, &chroma, &destination, &conversion, bgraOrder, 255,
            vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }

        // `makeImage()` copies, so the picture does not outlive the memory it was drawn in.
        return image(overBGRA: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}
