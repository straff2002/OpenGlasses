import CoreGraphics
import UIKit

/// The page view's frame on the Meta Display (Plan KV §1, measured in P4): how much of the 600 × 600
/// lens the picture may take so that the frame's lines, the picture and the button row all fit.
/// Pure geometry, SDK-free.
///
/// **Why.** P4's simulated Display drew a page-view frame whose picture filled the canvas width as a
/// square (576 × 576): with the citation line, the hint and the button row the frame came to about
/// 750 px, the lens scrolled it to the focused button, and the citation and hint were scrolled off
/// the top with part of the picture. A frame never scrolls now: the picture is the square crop
/// drawn into the space left over (`pictureSize`), letterboxed in black, which the lens shows as
/// nothing. The space is reserved for the most lines a page view has (the citation and the hint),
/// so the picture is the same size on every frame of a view and never jumps.
///
/// The constants are `MetaDisplayBackend`'s own layout (its root `FlexBox` padding and spacing) and
/// what DAT draws, as measured on the simulated Display in P4: a 580 px column, a button row 88 px
/// tall, a meta line and a body line. The picture comes to 382 px square. P5 checks them on the
/// glasses.
enum LensPageFrame {
    /// The lens.
    static let canvas = HUDCanvas.metaDisplay
    /// `MetaDisplayBackend.makeScreenView`'s root padding, each side.
    static let paddingPixels: CGFloat = 12
    /// …and its spacing between children.
    static let gapPixels: CGFloat = 6
    /// DAT's button row on the Display.
    static let buttonRowPixels: CGFloat = 88
    /// What DAT keeps of the canvas's height for itself: the simulated Display lays a frame out in
    /// a 580 px column and scrolls anything taller.
    static let reservedHeightPixels: CGFloat = 20
    /// The citation line (meta style) on the first frame.
    static let metaLinePixels: CGFloat = 30
    /// "Zoom in for labels" (body style).
    static let bodyLinePixels: CGFloat = 38

    /// The space the picture may take: the content width, and the height left under the most lines
    /// a page view shows (the citation and the hint) and above the button row.
    static var pictureSize: CGSize {
        let width = CGFloat(canvas.widthPixels) - 2 * paddingPixels
        // Four children (two lines, the picture, the row), so three gaps.
        let height = CGFloat(canvas.heightPixels) - reservedHeightPixels - 2 * paddingPixels
            - metaLinePixels - bodyLinePixels - 3 * gapPixels - buttonRowPixels
        return CGSize(width: width, height: max(1, min(width, height)))
    }

    /// The side of the square crop as drawn on the lens: what `LensLegibility` scales text by.
    static var pictureSidePixels: CGFloat { min(pictureSize.width, pictureSize.height) }

    /// Where the square crop sits inside `pictureSize`: centred, as large as fits.
    static var squareRect: CGRect {
        let size = pictureSize
        let side = pictureSidePixels
        return CGRect(x: ((size.width - side) / 2).rounded(), y: ((size.height - side) / 2).rounded(),
                      width: side, height: side)
    }

    /// The page view's square picture fitted into `pictureSize`, on black (the lens shows black as
    /// nothing). One lens pixel per image pixel.
    static func fitted(_ picture: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pictureSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: pictureSize))
            picture.draw(in: squareRect)
        }
    }
}
