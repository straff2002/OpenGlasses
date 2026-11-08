import CoreGraphics
import Foundation

/// The page view's frame on the Meta Display (Plan KV §1, measured in P4): how much of the 600 × 600
/// lens the picture may take, from what is actually on the frame, so that the frame's lines, the
/// picture and the button row always fit. Pure geometry, SDK-free.
///
/// **Why.** P4's simulated Display drew a page-view frame whose picture was the full canvas width
/// as a square, and the lens scrolled it. A later frame kept the picture to a square in the space
/// left over, which drew portrait pages and tables with black either side and still scrolled: DAT
/// draws a glow round the focused button that reaches 20 px below the row, and the frame's content
/// sits at the bottom of the lens, so a 12 px bottom margin let the glow push everything up by 20.
/// Now the picture is a rectangle the full content width (`contentWidthPixels`) and as tall as the
/// frame leaves it (`pictureBox`), and the crop takes that shape (`LensPageViewport`); a frame with
/// a button row keeps `buttonRowBottomPaddingPixels` under it, so the glow stays on the lens.
///
/// **The budget.** 600 px tall: the top padding, every child (`metaLinePixels` for a meta line —
/// the citation, a reading page's footer —, `bodyLinePixels` for a body line — the hint, a reading
/// page's text —, the picture, `buttonRowPixels` for the row) with `gapPixels` between children,
/// and the bottom padding. The picture box for each line count (with the row):
///
/// | Lines over the picture | Picture box |
/// |---|---|
/// | none | 576 × 462 |
/// | the citation (meta) | 576 × 426 |
/// | the hint (body) | 576 × 418 |
/// | both | 576 × 382 |
///
/// Reading mode has no picture: its frame is the citation (first page only), the text's body lines,
/// the "1/2" footer and the row, and `readingGeometry` is the most body lines that budget holds.
///
/// The constants are `MetaDisplayBackend`'s own layout (its root `FlexBox` padding and spacing) and
/// what DAT draws, as measured on the simulated Display in P4. P5 checks them on the glasses.
enum LensPageFrame {
    /// The lens.
    static let canvas = HUDCanvas.metaDisplay
    /// `MetaDisplayBackend.makeScreenView`'s root padding at the top and either side.
    static let paddingPixels: CGFloat = 12
    /// …and under a frame with a button row: the focused button's glow reaches 32 px below the row
    /// (measured on the simulated Display), so this keeps it inside the frame.
    static let buttonRowBottomPaddingPixels: CGFloat = 32
    /// …and its spacing between children.
    static let gapPixels: CGFloat = 6
    /// DAT's button row on the Display, its focused button at full size.
    static let buttonRowPixels: CGFloat = 88
    /// A meta line (the citation, a reading page's footer).
    static let metaLinePixels: CGFloat = 30
    /// A body line ("Zoom in for labels", a reading page's text).
    static let bodyLinePixels: CGFloat = 38

    /// The column's width: the canvas less the padding either side. The picture is this wide.
    static var contentWidthPixels: CGFloat { CGFloat(canvas.widthPixels) - 2 * paddingPixels }

    /// What one frame holds, top to bottom.
    struct Content: Hashable {
        var metaLines: Int = 0
        var bodyLines: Int = 0
        var hasPicture: Bool = false
        var hasButtons: Bool = true

        var children: Int { metaLines + bodyLines + (hasPicture ? 1 : 0) + (hasButtons ? 1 : 0) }
    }

    /// The padding under a frame's last child.
    static func bottomPadding(hasButtons: Bool) -> CGFloat {
        hasButtons ? buttonRowBottomPaddingPixels : paddingPixels
    }

    /// The frame's height with everything but the picture: padding, lines, the row and the gaps.
    static func fixedHeight(_ content: Content) -> CGFloat {
        let lines = CGFloat(max(0, content.metaLines)) * metaLinePixels
            + CGFloat(max(0, content.bodyLines)) * bodyLinePixels
        let row = content.hasButtons ? buttonRowPixels : 0
        let gaps = CGFloat(max(0, content.children - 1)) * gapPixels
        return paddingPixels + lines + row + gaps + bottomPadding(hasButtons: content.hasButtons)
    }

    /// The whole frame's height, the picture `pictureHeight` tall when it has one.
    static func height(_ content: Content, pictureHeight: CGFloat = 0) -> CGFloat {
        fixedHeight(content) + (content.hasPicture ? pictureHeight : 0)
    }

    /// The picture's box for a frame with `metaLines` and `bodyLines` over the picture (and a
    /// button row under it): the content width, and every pixel of height the frame leaves.
    static func pictureBox(metaLines: Int, bodyLines: Int, hasButtons: Bool = true) -> CGSize {
        let content = Content(metaLines: metaLines, bodyLines: bodyLines, hasPicture: true, hasButtons: hasButtons)
        let height = CGFloat(canvas.heightPixels) - fixedHeight(content)
        return CGSize(width: contentWidthPixels, height: max(1, height))
    }

    /// The picture box of a page-view frame: the citation line (a meta line, the first frame only)
    /// and the hint (a body line) when shown.
    static func pictureBox(citation: Bool, hint: Bool) -> CGSize {
        pictureBox(metaLines: citation ? 1 : 0, bodyLines: hint ? 1 : 0)
    }

    // MARK: - Reading mode

    /// Reading mode's character advance: the answer card's estimate (Plan KP), 32 characters across
    /// this 576 px column, so 18 px a character at the body token.
    static var readingCharAdvancePixels: CGFloat {
        contentWidthPixels / CGFloat(TeleprompterPaginator.Geometry.raybanDisplay.maxChars)
    }

    /// How many body lines a reading frame holds over the button row (and its glow padding) with
    /// `metaLines` meta lines (the citation, the "1/2" footer): every pixel the frame leaves, one
    /// body line (`bodyLinePixels`, the body token's 1.35× line) and its gap at a time.
    static func readingBodyLines(metaLines: Int) -> Int {
        let fixed = fixedHeight(Content(metaLines: metaLines, bodyLines: 0, hasPicture: false, hasButtons: true))
        let room = CGFloat(canvas.heightPixels) - fixed
        return max(1, Int((room / (bodyLinePixels + gapPixels)).rounded(.down)))
    }

    /// Reading mode's pager geometry on the Display, from this frame's budget rather than the
    /// answer card's 4 × 32 (which left a reading page two lines of text and the top of the lens
    /// empty). `HUDAnswerPager` counts a paged page's "1/2" footer as one of `maxLines` and gives a
    /// single page no footer, so `maxLines` is whichever of the two fits fewer: 10 lines, 9 of text
    /// and the footer. The citation over the first page takes one line of that
    /// (`LensPageReading.pages`): 8 lines of text there. 32 characters a line.
    static var readingGeometry: TeleprompterPaginator.Geometry {
        let paged = readingBodyLines(metaLines: 1) + 1
        let single = readingBodyLines(metaLines: 0)
        return TeleprompterPaginator.Geometry(maxLines: min(paged, single),
                                              maxChars: Int((contentWidthPixels / readingCharAdvancePixels).rounded(.down)))
    }

    /// Reading mode's geometry for `backend`: this frame's on the Display, the Even panel's own
    /// geometry unchanged on Even.
    static func readingGeometry(for backend: HUDCanvasBackend) -> TeleprompterPaginator.Geometry {
        switch backend {
        case .metaDisplay: return readingGeometry
        case .evenG2: return .evenG2
        }
    }
}
