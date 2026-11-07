import CoreGraphics
import UIKit
@testable import OpenGlasses

/// Invented pages for the Plan KV P1 tests: a letter page drawn with `UIGraphicsPDFRenderer`, with
/// made-up text and shapes. No real manual, caption or page number.
enum LensPageFixtures {

    static let letter = CGSize(width: 612, height: 792)

    /// Where the fixture draws its black block, in top-down page points.
    static let inkBlock = CGRect(x: 100, y: 100, width: 200, height: 200)
    /// …and its red one.
    static let redBlock = CGRect(x: 380, y: 520, width: 120, height: 120)

    /// A one-page PDF in the temporary directory. `paper` is the page's ground (nil leaves the
    /// PDF's own, which the renderer reads as paper white); `text` is drawn near the top.
    static func pdf(named name: String = UUID().uuidString, paper: UIColor? = nil,
                    ink: UIColor = .black, text: String = "Invented relay note 7") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kv-\(name).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            if let paper {
                paper.setFill()
                UIRectFill(CGRect(origin: .zero, size: letter))
            }
            ink.setFill()
            UIRectFill(inkBlock)
            UIColor.red.setFill()
            UIRectFill(redBlock)
            (text as NSString).draw(at: CGPoint(x: 72, y: 40), withAttributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: ink,
            ])
        }
        return url
    }

    /// A small stand-in picture for session tests that don't need a real render.
    static func picture(_ side: CGFloat = 8) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The RGB of one output pixel, top-down.
    static func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The bitmap's first row is the image's top row.
        let index = (y * width + x) * 4
        return (data[index], data[index + 1], data[index + 2])
    }

    static func staged(page: Int = 3, figure: String? = "Figure 9", origin: PageOrigin = .requested,
                       documentId: String = "doc-invented", title: String = "Invented Unit Guide",
                       pictureAreas: [ManualTable.PictureArea] = []) -> FieldSessionService.StagedFigure {
        var staged = FieldSessionService.StagedFigure(documentId: documentId, documentTitle: title, page: page,
                                                      figure: figure, sourceFile: "invented-guide.pdf",
                                                      origin: origin)
        staged.pictureAreas = pictureAreas
        return staged
    }
}
