import CoreGraphics
import Foundation

// Plan KV §2 / P1 — every pixel decision behind the lens picture, pure and testable. The drawing
// itself (`LensPageRenderer`) only rasterises the crop, runs each pixel through `invertLightness`
// (after `stretch` for a photographed page), and strokes the rectangles this plan has placed.

/// How one lens picture is drawn: the crop it shows, at what size, how its tones are turned for an
/// additive lens, and where the marks and the position frame go — all in output pixels, top down.
struct LensPageRenderPlan: Equatable {

    /// The picture is drawn one lens pixel per image pixel, at the box the frame leaves it
    /// (`LensPageFrame.pictureBox`, through the viewport), so a deeper zoom draws sharper rather
    /// than enlarging a whole-page render. A plan made from a bare crop is this wide.
    static var defaultOutputWidth: CGFloat { LensPageFrame.contentWidthPixels }

    /// How the page's tones are turned (§2, decision 5): always inverted, so the paper goes clear
    /// and the drawing floats. A photographed page's paper is grey, and inverted grey is a dim
    /// haze, so it is stretched to full range first.
    enum Tone: String, Equatable {
        case lineArt
        case photographed
    }

    /// One outline to stroke, in output pixels, with its number when the page carries more than one
    /// cited passage (as on the phone). Picture areas are outlined without a number.
    struct Mark: Equatable {
        let rect: CGRect
        let number: Int?
    }

    /// The small frame in a corner that says where the crop sits on the page (§2), drawn only when
    /// zoomed: the page's outline and, inside it, the crop.
    struct PositionFrame: Equatable {
        let page: CGRect
        let crop: CGRect
    }

    /// Outlines sit this far outside what they mark, in page points, so they never cross the text.
    static let markPaddingPoints: CGFloat = 2
    /// The position frame's longer side, as a share of the output's shorter side.
    static let positionFrameShare: CGFloat = 0.2
    /// Its distance from the output's edges, in pixels.
    static let positionFrameInset: CGFloat = 12

    let pageSize: CGSize
    /// The crop, in top-down page points (the output's shape; may reach past the page on an axis
    /// the page is shorter than, which is drawn black).
    let crop: CGRect
    let outputSize: CGSize
    let tone: Tone
    let marks: [Mark]
    let positionFrame: PositionFrame?

    /// Output pixels per page point.
    var scale: CGFloat { crop.width > 0 ? outputSize.width / crop.width : 0 }

    /// Where the page itself lands in the output. Outside it is black (clear on the lens).
    var pageInOutput: CGRect { toOutput(CGRect(origin: .zero, size: pageSize)) }

    /// `outputSize` defaults to `defaultOutputWidth` across and the crop's shape.
    init(pageSize: CGSize, crop: CGRect, tone: Tone,
         passageMarks: LensPageMarks? = nil, pictureAreas: [CGRect] = [],
         showsPosition: Bool, outputSize: CGSize? = nil) {
        self.pageSize = pageSize
        self.crop = crop.standardized
        let size: CGSize
        if let outputSize {
            size = CGSize(width: outputSize.width.rounded(), height: outputSize.height.rounded())
        } else {
            let width = Self.defaultOutputWidth
            let shape = self.crop.width > 0 ? self.crop.height / self.crop.width : 1
            size = CGSize(width: width, height: (width * shape).rounded())
        }
        self.outputSize = size
        self.tone = tone
        let outputWidth = size.width

        let visible = self.crop
        let showsNumbers = passageMarks?.showsNumbers ?? false
        var placed: [Mark] = []
        for mark in passageMarks?.marks ?? [] {
            let padded = mark.bounds.insetBy(dx: -Self.markPaddingPoints, dy: -Self.markPaddingPoints)
            guard padded.intersects(visible) else { continue }
            placed.append(Mark(rect: Self.toOutput(padded, crop: visible, side: outputWidth),
                               number: showsNumbers ? mark.number : nil))
        }
        for area in pictureAreas {
            let padded = area.standardized.insetBy(dx: -Self.markPaddingPoints, dy: -Self.markPaddingPoints)
            guard padded.intersects(visible) else { continue }
            placed.append(Mark(rect: Self.toOutput(padded, crop: visible, side: outputWidth), number: nil))
        }
        marks = placed
        positionFrame = showsPosition
            ? Self.positionFrame(pageSize: pageSize, crop: visible, output: size)
            : nil
    }

    /// The plan for one viewport of a laid-out page: drawn at the viewport's picture box.
    init(layout: LensPageLayout, viewport: LensPageViewport) {
        self.init(pageSize: layout.pageSize, crop: viewport.cropRect, tone: layout.tone,
                  passageMarks: layout.marks, pictureAreas: layout.pictureAreas,
                  showsPosition: !viewport.isWholePage, outputSize: viewport.box)
    }

    /// A rectangle in top-down page points, in output pixels.
    func toOutput(_ rect: CGRect) -> CGRect {
        Self.toOutput(rect, crop: crop, side: outputSize.width)
    }

    static func toOutput(_ rect: CGRect, crop: CGRect, side: CGFloat) -> CGRect {
        guard crop.width > 0 else { return .zero }
        let scale = side / crop.width
        return CGRect(x: (rect.minX - crop.minX) * scale, y: (rect.minY - crop.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// The position frame in the bottom-right corner: the page scaled so its longer side is
    /// `positionFrameShare` of the output's shorter side, and the crop inside it, clipped to the page.
    static func positionFrame(pageSize: CGSize, crop: CGRect, output: CGSize) -> PositionFrame? {
        let longer = max(pageSize.width, pageSize.height)
        guard longer > 0 else { return nil }
        let factor = min(output.width, output.height) * positionFrameShare / longer
        let size = CGSize(width: pageSize.width * factor, height: pageSize.height * factor)
        let page = CGRect(x: output.width - positionFrameInset - size.width,
                          y: output.height - positionFrameInset - size.height,
                          width: size.width, height: size.height)
        let inPage = crop.intersection(CGRect(origin: .zero, size: pageSize))
        guard !inPage.isNull else { return PositionFrame(page: page, crop: .zero) }
        let mapped = CGRect(x: page.minX + inPage.minX * factor, y: page.minY + inPage.minY * factor,
                            width: inPage.width * factor, height: inPage.height * factor)
        return PositionFrame(page: page, crop: mapped)
    }

    // MARK: - Tones

    /// Inverted lightness, hue kept: in HSL, L → 1 − L with H and S unchanged is each channel
    /// shifted by `1 − max − min`. White paper goes black (clear on an additive lens), black ink
    /// goes white, and a red wire stays red rather than turning cyan as a plain negative would.
    static func invertLightness(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let high = Int(max(r, g, b))
        let low = Int(min(r, g, b))
        let shift = 255 - high - low
        func clamp(_ value: Int) -> UInt8 { UInt8(min(max(value, 0), 255)) }
        return (clamp(Int(r) + shift), clamp(Int(g) + shift), clamp(Int(b) + shift))
    }

    /// The black and white points for a photographed page's stretch: the luminance below which
    /// `lowShare` of the pixels lie, and above which `1 − highShare` do. From a 256-bin histogram.
    /// A flat or empty histogram stretches nothing (0, 255).
    static func stretchLevels(histogram: [Int], lowShare: Double = 0.02,
                              highShare: Double = 0.98) -> (black: UInt8, white: UInt8) {
        let total = histogram.reduce(0, +)
        guard histogram.count == 256, total > 0 else { return (0, 255) }
        func level(at share: Double) -> Int {
            let target = Double(total) * share
            var running = 0
            for (value, count) in histogram.enumerated() {
                running += count
                if Double(running) >= target { return value }
            }
            return 255
        }
        let black = level(at: lowShare)
        let white = level(at: highShare)
        // Too narrow to stretch safely (a blank page): leave it as it is.
        guard white - black >= 16 else { return (0, 255) }
        return (UInt8(black), UInt8(white))
    }

    /// One channel stretched so `black` maps to 0 and `white` to 255.
    static func stretch(_ value: UInt8, black: UInt8, white: UInt8) -> UInt8 {
        guard white > black else { return value }
        let above: Int = Int(value) - Int(black)
        let range: Int = Int(white) - Int(black)
        let scaled: Int = above * 255 / range
        return UInt8(min(max(scaled, 0), 255))
    }

    /// Rec. 601 luma, for the histogram.
    static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        // Split into typed steps: one chained expression timed out CI's type-checker.
        let red: Int = 299 * Int(r)
        let green: Int = 587 * Int(g)
        let blue: Int = 114 * Int(b)
        let sum: Int = red + green + blue
        return UInt8(sum / 1000)
    }
}
