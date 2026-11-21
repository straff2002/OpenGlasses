import CoreGraphics
import Foundation
import UIKit

// Plan MG §4 — a zoomed view as a strip the lens scrolls, and the slicing of a drawn picture into
// pieces. Plan MU §0 dropped MG's 3 × 3 tile grid of the whole page: the glasses drew a row of
// pictures as its first picture across the whole view (decision 5), and MU §6's close-up replaced
// pointing at a ninth of the page. The strip and its slices are what the close-up is drawn with.

/// A zoomed view's strip (Plan MG §4): the crop's column of the page from the crop's top down, at
/// the view's magnification, up to `maxHeightPixels`, cut into `sliceHeightPixels` slices. The
/// slices are plain tappable boxes, so the strip stays seamless and the lens steps from one to the
/// next and scrolls with it (measured on the simulated Display: about one slice per move, no
/// send). Panning down the page needs no new frame; only left, right and zoom do.
struct LensPageStrip: Equatable {
    /// Two lens heights (decision pending the glasses' send times; three measured 166 KB a frame).
    static let maxHeightPixels: CGFloat = 2 * CGFloat(HUDCanvas.metaDisplay.heightPixels)
    /// About one band move each (measured: 206 px a move, a slice and its gap).
    static let sliceHeightPixels: CGFloat = 200

    /// The strip on the page, in top-down page points.
    let rect: CGRect
    /// The strip's whole picture, in lens pixels: the box's width, and its height at this zoom.
    let outputSize: CGSize
    /// Each slice's rectangle in the strip's picture, top to bottom, in lens pixels.
    let slices: [CGRect]

    init(viewport: LensPageViewport) {
        let crop = viewport.cropRect
        let ppp = max(viewport.pixelsPerPoint, 1e-6)
        let pageHeight = viewport.pageSize.height
        let rect: CGRect
        if crop.height >= pageHeight - LensPageViewport.tolerance || crop.minY < 0 {
            rect = crop   // the page is no taller than the crop: nothing more to scroll to
        } else {
            let bottom = min(pageHeight, crop.minY + Self.maxHeightPixels / ppp)
            rect = CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: max(crop.height, bottom - crop.minY))
        }
        self.rect = rect
        let height = min(Self.maxHeightPixels, (rect.height * ppp).rounded())
        let output = CGSize(width: viewport.box.width.rounded(), height: max(1, height))
        outputSize = output
        slices = Self.slices(of: output)
    }

    /// A picture `output` in size cut into slices about `sliceHeightPixels` tall, top to bottom,
    /// in its own pixels (Plan MU §6: each close-up column is cut the same way).
    static func slices(of output: CGSize) -> [CGRect] {
        let count = max(1, Int((output.height / sliceHeightPixels).rounded(.up)))
        let sliceHeight = (output.height / CGFloat(count)).rounded(.up)
        return (0..<count).compactMap { index in
            let top = CGFloat(index) * sliceHeight
            guard top < output.height else { return nil }
            return CGRect(x: 0, y: top, width: output.width,
                          height: max(1, min(sliceHeight, output.height - top)))
        }
    }

    /// The point on the page at the middle of slice `index`.
    func center(ofSlice index: Int) -> CGPoint? {
        guard slices.indices.contains(index), outputSize.height > 0 else { return nil }
        let slice = slices[index]
        let fraction = slice.midY / outputSize.height
        return CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction)
    }
}

/// Cuts a drawn picture into pieces (a page's tiles, a strip's slices). The source rectangle is in
/// the picture's own pixels as planned (`plannedSize`); a picture drawn at another size is scaled
/// to match. Off the main actor.
enum LensPageSlicer {
    nonisolated static func slice(_ image: UIImage, plannedSize: CGSize,
                                  pieces: [(source: CGRect, size: CGSize)]) -> [UIImage] {
        guard let cg = image.cgImage, plannedSize.width > 0, plannedSize.height > 0 else { return [] }
        let sx = CGFloat(cg.width) / plannedSize.width
        let sy = CGFloat(cg.height) / plannedSize.height
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return pieces.map { piece in
            let source = CGRect(x: piece.source.minX * sx, y: piece.source.minY * sy,
                                width: piece.source.width * sx, height: piece.source.height * sy).integral
            let size = CGSize(width: max(1, piece.size.width.rounded()), height: max(1, piece.size.height.rounded()))
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                guard let cropped = cg.cropping(to: source) else { return }
                UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
