import CoreGraphics
import Foundation
import UIKit

// Plan MG §4 — the page view, quicker: the whole page as tiles to point at, and a zoomed view as a
// strip the lens scrolls. Pure geometry here, and the slicing of a drawn picture into pieces.

/// One tile of the whole page: which ninth of the page it shows, as a crop inside the page, and
/// the size it is drawn at on the lens.
struct LensPageTile: Equatable {
    let area: LensPageViewport.Area
    /// Top-down page points, inside the page.
    let crop: CGRect
    /// Lens pixels: `.fill` draws an image one pixel to one lens pixel and never shares a row, so
    /// a tile is rendered at exactly this size.
    let drawnSize: CGSize

    var center: CGPoint { CGPoint(x: crop.midX, y: crop.midY) }
}

/// The whole page as a 3 × 3 grid of tappable tiles (Plan MG §4, decision 7). Each tile is a card
/// (the only way the lens shows focus on a picture), and a press zooms
/// `LensPageViewport.pointZoomRungs` rungs into its centre. The grid replaces **Zoom in** on the
/// whole page.
///
/// **Sizes.** Three across with `LensPageFrame.tileGapPixels` between them fill the 576 px column:
/// 186 px a tile at most (measured on the simulated Display). Three rows with the frame's gaps
/// between them fit the picture box the frame leaves. A tile keeps its ninth of the page's shape,
/// so the grid is as large as both limits allow.
enum LensPageTileGrid {
    static let rows = 3
    static let columns = 3

    /// The widest a tile can be: three across, two gaps, the column's width.
    static var maxTileWidth: CGFloat {
        ((LensPageFrame.contentWidthPixels - CGFloat(columns - 1) * LensPageFrame.tileGapPixels)
            / CGFloat(columns)).rounded(.down)
    }

    /// The nine tiles, row by row, for a page of `pageSize` in a picture box `box`.
    static func tiles(pageSize: CGSize, box: CGSize) -> [LensPageTile] {
        let page = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        let cell = CGSize(width: page.width / CGFloat(columns), height: page.height / CGFloat(rows))
        let maxHeight = max(1, (box.height - CGFloat(rows - 1) * LensPageFrame.gapPixels) / CGFloat(rows))
        let scale = min(maxTileWidth / cell.width, maxHeight / cell.height)
        let drawn = CGSize(width: max(1, (cell.width * scale).rounded(.down)),
                           height: max(1, (cell.height * scale).rounded(.down)))
        return LensPageViewport.Area.allCases.map { area in
            LensPageTile(area: area, crop: area.rect(in: page), drawnSize: drawn)
        }
    }

    /// The tile at `row`, `column`, if there is one.
    static func tile(row: Int, column: Int, pageSize: CGSize, box: CGSize) -> LensPageTile? {
        guard let area = LensPageViewport.Area(row: row, column: column) else { return nil }
        return tiles(pageSize: pageSize, box: box).first { $0.area == area }
    }
}

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
        let count = max(1, Int((output.height / Self.sliceHeightPixels).rounded(.up)))
        let sliceHeight = (output.height / CGFloat(count)).rounded(.up)
        slices = (0..<count).map { index in
            let top = CGFloat(index) * sliceHeight
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
