import XCTest
import UIKit
@testable import OpenGlasses

/// Tests OCRService end-to-end by rendering known text into an image and recognizing it.
/// Apple Vision runs in the simulator, so this exercises the real recognition path.
@MainActor
final class OCRServiceTests: XCTestCase {

    /// Render large, high-contrast text into an image for reliable OCR.
    private func image(text: String, size: CGSize = CGSize(width: 700, height: 220)) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 96),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 24, y: 50), withAttributes: attrs)
        }
        return uiImage.cgImage!
    }

    func testRecognizesRenderedText() async {
        let result = await OCRService().recognizeText(in: image(text: "INVOICE"))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.text.uppercased().contains("INVOICE"), "Got: \(result.text)")
        XCTAssertFalse(result.blocks.isEmpty)
    }

    func testReturnsEmptyForBlankImage() async {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
        let blank = renderer.image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let result = await OCRService().recognizeText(in: blank.cgImage!)
        XCTAssertTrue(result.isEmpty)
    }

    func testRecognizesFromJPEGData() async {
        let cg = image(text: "E5")
        let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)!
        let result = await OCRService().recognizeText(in: data)
        XCTAssertTrue(result.text.uppercased().contains("E5"), "Got: \(result.text)")
    }
}
