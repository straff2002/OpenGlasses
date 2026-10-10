import XCTest
import CoreMedia
import CoreVideo
import UIKit
@testable import OpenGlasses

/// Plan HW P1. A raw frame from the glasses is pixels the SDK's helper turns into a picture on
/// the GPU, and iOS denies the GPU to an app in the background. So with the phone locked the
/// helper returns nothing for a frame that arrived whole. The conversion that saves it has to
/// run on the CPU, has to get the colours right, and has to say which format it was handed when
/// it has no rule for one: nobody has yet seen which format the glasses send as raw.
final class PixelBufferImageConverterTests: XCTestCase {

    private struct RGB: Equatable {
        let red: Int, green: Int, blue: Int
    }

    private let width = 16
    private let height = 8

    // MARK: - 32BGRA, the format the decoder's session asks for

    func testA32BGRABufferConvertsWithItsSizeAndItsPixels() throws {
        let buffer = try makeBGRA { x, y in
            x < 8 ? RGB(red: 200, green: 40, blue: 10) : RGB(red: 5, green: y * 20, blue: 250)
        }
        let image = try convertedImage(buffer)

        XCTAssertEqual(pixelSize(of: image), CGSize(width: width, height: height))
        XCTAssertEqual(try pixel(of: image, x: 2, y: 1), RGB(red: 200, green: 40, blue: 10))
        XCTAssertEqual(try pixel(of: image, x: 12, y: 0), RGB(red: 5, green: 0, blue: 250))
        XCTAssertEqual(try pixel(of: image, x: 15, y: 7), RGB(red: 5, green: 140, blue: 250),
                       "the bottom row is the bottom row: the picture is not flipped")
    }

    // MARK: - Bi-planar 4:2:0

    /// Video range, the Rec. 709 numbers for a mid grey, a full red and a full blue. With no
    /// matrix named on the buffer, 709 is what is assumed.
    func testAVideoRangeBiPlanarBufferConvertsWithPlausibleColour() throws {
        let buffer = try makeBiPlanar(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { x, y in
            if y >= 4 { return (126, 128, 128) }          // grey
            return x < 8 ? (63, 102, 240) : (32, 240, 118) // red, blue
        }
        let image = try convertedImage(buffer)

        XCTAssertEqual(pixelSize(of: image), CGSize(width: width, height: height))
        assertClose(try pixel(of: image, x: 3, y: 1), RGB(red: 255, green: 0, blue: 0))
        assertClose(try pixel(of: image, x: 12, y: 2), RGB(red: 0, green: 0, blue: 255))
        assertClose(try pixel(of: image, x: 8, y: 6), RGB(red: 128, green: 128, blue: 128))
    }

    /// Full range uses all eight bits, so the same colours are different numbers. Reading these
    /// as video range would stretch them: the grey would come out near 130 and still pass, but
    /// black at 0 would be pushed below zero and white past 255, so both ends are checked.
    func testAFullRangeBiPlanarBufferConvertsWithPlausibleColour() throws {
        let buffer = try makeBiPlanar(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { x, y in
            if y >= 4 { return x < 8 ? (128, 128, 128) : (235, 128, 128) }  // grey, light grey
            return x < 8 ? (54, 99, 255) : (16, 128, 128)                   // red, near black
        }
        let image = try convertedImage(buffer)

        XCTAssertEqual(pixelSize(of: image), CGSize(width: width, height: height))
        assertClose(try pixel(of: image, x: 3, y: 1), RGB(red: 255, green: 0, blue: 0))
        assertClose(try pixel(of: image, x: 2, y: 6), RGB(red: 128, green: 128, blue: 128))
        // Full range keeps 16 as 16 and 235 as 235. Video range would have made them 0 and 255.
        assertClose(try pixel(of: image, x: 12, y: 1), RGB(red: 16, green: 16, blue: 16),
                    tolerance: 3)
        assertClose(try pixel(of: image, x: 12, y: 6), RGB(red: 235, green: 235, blue: 235),
                    tolerance: 3)
    }

    /// The buffer says which arithmetic it wants. Rec. 601's red is not 709's red: the same
    /// bytes read with the wrong matrix come out a different colour.
    func testTheMatrixNamedOnTheBufferIsTheOneUsed() throws {
        let rec601Red: (UInt8, UInt8, UInt8) = (82, 90, 240)
        let named = try makeBiPlanar(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _, _ in
            rec601Red
        }
        CVBufferSetAttachment(named, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        XCTAssertTrue(PixelBufferImageConverter.usesRec601(named))
        assertClose(try pixel(of: try convertedImage(named), x: 4, y: 4),
                    RGB(red: 255, green: 0, blue: 0))

        let unnamed = try makeBiPlanar(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _, _ in
            rec601Red
        }
        XCTAssertFalse(PixelBufferImageConverter.usesRec601(unnamed),
                       "a buffer that names no matrix is read as Rec. 709")
        let as709 = try pixel(of: try convertedImage(unnamed), x: 4, y: 4)
        XCTAssertGreaterThan(as709.green, 15, "601 bytes through the 709 matrix are not pure red")
    }

    // MARK: - What it will not convert

    func testAnUnsupportedFormatIsReportedByItsFourCharacterCode() throws {
        let buffer = try makeBuffer(kCVPixelFormatType_OneComponent8)
        guard case .unsupportedFormat(let format) = PixelBufferImageConverter.convert(buffer) else {
            return XCTFail("a one-channel buffer has no rule and must not become a picture")
        }
        XCTAssertEqual(format, kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(PixelBufferImageConverter.name(ofFormat: format), "L008")
    }

    /// 32ARGB is the same bytes as 32BGRA in another order. Treating it as BGRA would produce a
    /// picture with the channels swapped, which is worse than no picture.
    func testAFormatThatLooksCloseIsStillUnsupported() throws {
        let buffer = try makeBuffer(kCVPixelFormatType_32ARGB)
        guard case .unsupportedFormat(let format) = PixelBufferImageConverter.convert(buffer) else {
            return XCTFail("32ARGB must not be read as 32BGRA")
        }
        XCTAssertEqual(format, kCVPixelFormatType_32ARGB)
    }

    /// The name goes into a log token, which admits letters, digits and `_ . -` and nothing
    /// else. Several formats are small integers, not text, and those are written in hex.
    func testAFormatNameAlwaysFitsALogToken() {
        let names = [
            PixelBufferImageConverter.name(ofFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            PixelBufferImageConverter.name(ofFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            PixelBufferImageConverter.name(ofFormat: kCVPixelFormatType_32BGRA),
            PixelBufferImageConverter.name(ofFormat: kCVPixelFormatType_32ARGB),
            PixelBufferImageConverter.name(ofFormat: 0x2D2D2D2D),   // "----": not letters or digits
            PixelBufferImageConverter.name(ofFormat: 0),
        ]
        XCTAssertEqual(names, ["420v", "420f", "BGRA", "0x00000020", "0x2D2D2D2D", "0x00000000"])
        for name in names {
            XCTAssertEqual(PrivacyToken(name).description, name,
                           "\(name) would be logged as a placeholder")
        }
    }

    // MARK: - Fixtures

    private func convertedImage(_ buffer: CVPixelBuffer,
                                file: StaticString = #filePath, line: UInt = #line) throws -> UIImage {
        guard case .image(let image) = PixelBufferImageConverter.convert(buffer) else {
            XCTFail("the buffer did not convert", file: file, line: line)
            throw XCTSkip("no picture to inspect")
        }
        return image
    }

    private func makeBuffer(_ format: OSType) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                         attributes as CFDictionary, &buffer)
        return try XCTUnwrap(buffer, "CVPixelBufferCreate failed (\(status))")
    }

    private func makeBGRA(_ colour: (Int, Int) -> RGB) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let value = colour(x, y)
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8(value.blue)
                pixels[offset + 1] = UInt8(value.green)
                pixels[offset + 2] = UInt8(value.red)
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    /// `colour` returns luma, Cb and Cr for a pixel. Chroma is shared by each 2×2 block, so the
    /// fixtures keep a colour constant across whole blocks.
    private func makeBiPlanar(_ format: OSType,
                              _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(format)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRow + x] = colour(x, y).0 }
        }

        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let value = colour(x * 2, y * 2)
                chroma[y * chromaRow + x * 2] = value.1
                chroma[y * chromaRow + x * 2 + 1] = value.2
            }
        }
        return buffer
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.cgImage?.width ?? 0, height: image.cgImage?.height ?? 0)
    }

    /// Draws the picture into a plain RGBA bitmap and reads one pixel back, `y` counted from the
    /// top.
    private func pixel(of image: UIImage, x: Int, y: Int) throws -> RGB {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width,
                                             height: cgImage.height))
            return true
        }
        XCTAssertTrue(drawn)
        let offset = (y * cgImage.width + x) * 4
        return RGB(red: Int(bytes[offset]), green: Int(bytes[offset + 1]),
                   blue: Int(bytes[offset + 2]))
    }

    private func assertClose(_ actual: RGB, _ expected: RGB, tolerance: Int = 8,
                             file: StaticString = #filePath, line: UInt = #line) {
        let close = abs(actual.red - expected.red) <= tolerance
            && abs(actual.green - expected.green) <= tolerance
            && abs(actual.blue - expected.blue) <= tolerance
        XCTAssertTrue(close, "\(actual) is not within \(tolerance) of \(expected)",
                      file: file, line: line)
    }
}
