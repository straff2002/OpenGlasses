import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// The picture behind a vision answer (Plan LC §5): a small thumbnail of the camera frame the model
/// analysed, on the answer card's first page, through KV's `HUDPicture` path. SDK-free; the
/// geometry, the key, the tone lift and the budget check are pure, and `picture(fromImageData:)`
/// draws on whatever thread calls it (the caller keeps it off the main actor).
///
/// **The strip.** The bitmap is always `stripWidth` (552 px) wide and at most `maxHeight` (200 px)
/// tall; the frame is drawn aspect-fit and centred in it, and the rest is black. Black is clear on
/// the additive lens, so the wearer sees only the frame. A fixed-width strip rather than a bitmap
/// the frame's own shape, because DAT's only non-icon image preset is `.fill` (`MetaDisplayBackend`
/// draws a screen's picture with it), which sizes the image to the column: a portrait 150 × 200
/// thumbnail could come back drawn 576 px wide and 768 tall, past the lens. A strip whose width is
/// fixed draws at most `drawnHeight` (209 px for a 200 px strip in the 576 px column), whatever the
/// frame's aspect. The strip is as tall as the fitted frame, so a panorama gets a shorter strip.
///
/// **The tone lift.** On an additive display dark pixels are transparent, so a dim frame all but
/// vanishes. Every channel goes through a gamma of `liftGamma` (0.8): shadows come up, black stays
/// black (the pillars stay clear) and white stays white. Modest on purpose — it is a thumbnail to
/// recognise, not a picture to inspect.
///
/// **The budget (why page 1, not a page of its own).** The answer card's Display geometry is 4 × 32
/// (`TeleprompterPaginator.Geometry.raybanDisplay`). On `LensPageFrame`'s measured budget the
/// fullest first page — four body lines, or the question, three body lines, or the question, two
/// lines and the "1/3" footer — leaves at least 286 px over the button row, so the strip (≤ 209 px
/// drawn) fits beside the text without the pager moving a word: the page count the wearer turns
/// through, and the prefix-stable pages a streaming answer relies on, are unchanged. `fits(_:)` is
/// the guard: a first page it does not fit (a future geometry, a second button row) is drawn without
/// the picture rather than scrolled. The backend draws a picture after a screen's lines, so the
/// thumbnail sits under the text and over the buttons.
///
/// **The key.** `contentKey` names the frame without its pixels: when it was captured, how many
/// bytes it was and its size. The render queue's de-duplication compares it; it never carries what
/// the frame shows.
enum HUDAnswerThumbnail {
    /// The strip's width: the Display survey's measured 552 px picture (Plan LC §2.4's send cost).
    static let stripWidth: CGFloat = 552
    /// The tallest strip (Plan LC §5).
    static let maxHeight: CGFloat = 200
    /// The tone lift's gamma (out = in^γ): under 1 lifts the shadows.
    static let liftGamma: Double = 0.8

    /// Where the frame goes: the strip's size and the frame's aspect-fit rectangle in it (top-down
    /// pixels, centred). Nil for a frame with no size.
    static func layout(source: CGSize) -> (canvas: CGSize, image: CGRect)? {
        guard source.width > 0, source.height > 0, source.width.isFinite, source.height.isFinite else { return nil }
        let scale = min(stripWidth / source.width, maxHeight / source.height)
        let width = max(1, (source.width * scale).rounded())
        let height = max(1, (source.height * scale).rounded())
        let canvas = CGSize(width: stripWidth, height: min(maxHeight, height))
        let image = CGRect(x: ((stripWidth - width) / 2).rounded(.down), y: 0,
                           width: min(width, stripWidth), height: canvas.height)
        return (canvas, image)
    }

    /// The content key for a frame captured at `capturedAt`, `byteCount` bytes, `pixelSize` big.
    static func contentKey(capturedAt: Date, byteCount: Int, pixelSize: CGSize) -> String {
        let millis = Int((capturedAt.timeIntervalSince1970 * 1000).rounded())
        return "lc.answer.frame:\(millis):\(byteCount):\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }

    /// One channel through the lift. 0 stays 0 and 255 stays 255.
    static func lift(_ value: UInt8) -> UInt8 { liftTable[Int(value)] }

    private static let liftTable: [UInt8] = (0...255).map { value in
        UInt8((pow(Double(value) / 255, liftGamma) * 255).rounded())
    }

    // MARK: - The budget

    /// How tall the lens draws `picture`: `.fill` across the column (`LensPageFrame.contentWidthPixels`).
    static func drawnHeight(of picture: HUDPicture) -> CGFloat {
        guard picture.pixelSize.width > 0 else { return 0 }
        return (picture.pixelSize.height * LensPageFrame.contentWidthPixels / picture.pixelSize.width).rounded(.up)
    }

    /// What `screen` holds, in `LensPageFrame`'s terms, with a picture: a meta line is one line, a
    /// body line counts the display lines it wraps to at the answer card's width.
    static func frameContent(of screen: HUDScreen,
                             maxChars: Int = TeleprompterPaginator.Geometry.raybanDisplay.maxChars) -> LensPageFrame.Content {
        var content = LensPageFrame.Content(hasPicture: true, hasButtons: !screen.items.isEmpty)
        if let title = screen.title, !title.isEmpty { content.bodyLines += 1 }
        for line in screen.lines {
            if line.emphasis == .meta {
                content.metaLines += 1
            } else {
                content.bodyLines += max(1, HUDAnswerPager.displayLines(for: HUDTextShaper.condense(line.text),
                                                                         maxChars: maxChars).count)
            }
        }
        return content
    }

    /// Whether `screen` and `picture` together fit the 600 × 600 lens on `LensPageFrame`'s budget.
    static func fits(_ screen: HUDScreen, picture: HUDPicture) -> Bool {
        let height = LensPageFrame.height(frameContent(of: screen), pictureHeight: drawnHeight(of: picture))
        return height <= CGFloat(LensPageFrame.canvas.heightPixels)
    }

    // MARK: - Drawing

    /// The thumbnail of an encoded camera frame (JPEG or HEIC), or nil when it does not decode.
    /// Decodes straight to a small image (ImageIO's thumbnail, orientation applied), so a 12 MP
    /// photo is never held at full size. Call it off the main actor.
    static func picture(fromImageData data: Data, capturedAt: Date) -> HUDPicture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(stripWidth),
        ]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let image = strip(from: frame) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        return HUDPicture(image: UIImage(cgImage: image, scale: 1, orientation: .up), pixelSize: size,
                          contentKey: contentKey(capturedAt: capturedAt, byteCount: data.count,
                                                 pixelSize: CGSize(width: frame.width, height: frame.height)))
    }

    /// `frame` drawn into its strip, lifted.
    static func strip(from frame: CGImage) -> CGImage? {
        guard let plan = layout(source: CGSize(width: frame.width, height: frame.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Int(plan.canvas.width), height = Int(plan.canvas.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // Core Graphics is y-up; the strip is one row of content, so only x needs placing.
        context.draw(frame, in: CGRect(x: plan.image.minX, y: 0, width: plan.image.width, height: plan.image.height))
        if let base = context.data {
            let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for index in 0..<(width * height) {
                let p = index * 4
                pixels[p] = lift(pixels[p])
                pixels[p + 1] = lift(pixels[p + 1])
                pixels[p + 2] = lift(pixels[p + 2])
                pixels[p + 3] = 255
            }
        }
        return context.makeImage()
    }
}
