import CoreGraphics
import Foundation

// Plan KP §6 / P4 — the HUD preview drawn to scale.
//
// Pure and SDK-free (it compiles in the phone-only build): the lens canvases, in their own pixels,
// the fit that turns those pixels into phone points for the space a preview has, and an
// *estimated* size for each text token. DAT styles text by semantic token (heading / body / meta),
// never by size, and the Even panel's font is not documented, so every size here is an estimate
// until P6 photographs a real lens. `HUDTextSizeEstimate.isEstimate` says so in code, and
// `HUDCanvas.accessibilitySummary` says so to VoiceOver.

/// The lens a canvas stands for.
enum HUDCanvasBackend: String, CaseIterable, Sendable {
    /// Meta Ray-Ban Display, through `MWDATDisplay`.
    case metaDisplay
    /// Even G2, through Plan AH's backend.
    case evenG2
}

/// The text tokens the HUD styles by (DAT's `TextStyle`; the Even renderer has one size).
enum HUDTextToken: String, CaseIterable, Sendable {
    case heading
    case body
    case meta
}

/// A text token's size on a lens, in the lens's own pixels.
struct HUDTextSizeEstimate: Equatable, Sendable {
    /// Font size (the em), in lens pixels.
    let pixels: CGFloat
    /// Distance from one baseline to the next, in lens pixels.
    let lineHeightPixels: CGFloat
    /// True while the size is a documented guess rather than a measurement from a lens.
    let isEstimate: Bool
}

/// A lens's drawing surface, measured in the lens's own pixels.
struct HUDCanvas: Equatable, Sendable {
    let backend: HUDCanvasBackend
    let widthPixels: Int
    let heightPixels: Int
    /// The density the pixels are specified at (DAT lays the Display out at 160, so one of its
    /// pixels is one density-independent unit); nil where the backend states none.
    let density: Int?

    /// The Meta Display: a black 600 × 600 square at density 160.
    static let metaDisplay = HUDCanvas(backend: .metaDisplay, widthPixels: 600, heightPixels: 600, density: 160)
    /// The Even G2 panel: monochrome, 576 × 288.
    static let evenG2 = HUDCanvas(backend: .evenG2, widthPixels: 576, heightPixels: 288, density: nil)

    static func canvas(for backend: HUDCanvasBackend) -> HUDCanvas {
        switch backend {
        case .metaDisplay: return .metaDisplay
        case .evenG2: return .evenG2
        }
    }

    /// Width over height.
    var aspectRatio: CGFloat { CGFloat(widthPixels) / CGFloat(heightPixels) }

    /// The estimated size of `token` on this lens.
    ///
    /// **All estimates — P6 calibrates them from a photo of a real lens.**
    /// - Meta Display: heading 34 px, body 28 px, meta 22 px, lines at 1.35 × the size. These are the
    ///   sizes the web mirror's 600 × 600 page uses (`WebHUDRenderer`), inside §6's "body about 24–32
    ///   px", so the two previews of the same lens agree. DAT publishes no point sizes.
    /// - Even G2: one size for every token, since the panel draws plain text lines. The renderer's
    ///   budget assumes a ~12 px character advance (44 of ~48 cells across 576 px) and eight lines
    ///   down 288 px, so a 36 px line pitch; a monospaced face with a 12 px advance is about 20 px.
    func textSize(_ token: HUDTextToken) -> HUDTextSizeEstimate {
        switch backend {
        case .metaDisplay:
            let pixels: CGFloat
            switch token {
            case .heading: pixels = 34
            case .body: pixels = 28
            case .meta: pixels = 22
            }
            return HUDTextSizeEstimate(pixels: pixels, lineHeightPixels: (pixels * 1.35).rounded(),
                                       isEstimate: true)
        case .evenG2:
            return HUDTextSizeEstimate(pixels: Self.evenFontPixels, lineHeightPixels: Self.evenLinePitchPixels,
                                       isEstimate: true)
        }
    }

    /// True when any token's size on this lens is an estimate.
    var sizesAreEstimates: Bool { HUDTextToken.allCases.contains { textSize($0).isEstimate } }

    // MARK: Even G2 cell metrics (estimates, from `EvenScreenRenderer`'s budget)

    /// Estimated character advance on the Even panel.
    static let evenCharAdvancePixels: CGFloat = 12
    /// Estimated line pitch: 288 px over `EvenScreenRenderer.maxLines` (8) lines.
    static let evenLinePitchPixels: CGFloat = 36
    /// Estimated font size for a monospaced face with a 12 px advance.
    static let evenFontPixels: CGFloat = 20

    /// The left margin that centres `EvenScreenRenderer.charBudget` cells on the panel.
    var evenLeftMarginPixels: CGFloat {
        max(0, (CGFloat(widthPixels) - CGFloat(EvenScreenRenderer.charBudget) * Self.evenCharAdvancePixels) / 2)
    }

    // MARK: Words

    /// The lens's name as the phone shows it.
    var displayName: String {
        switch backend {
        case .metaDisplay: return "Ray-Ban Display"
        case .evenG2: return "EVEN G2"
        }
    }

    /// What VoiceOver says for the preview: whose shape it is, its size, and that text sizes are
    /// estimates while they are.
    var accessibilitySummary: String {
        let shape = String(localized: "Lens preview at the \(displayName)'s shape, \(widthPixels) by \(heightPixels) pixels.")
        guard sizesAreEstimates else { return shape }
        return shape + " " + String(localized: "Text sizes are estimates.")
    }
}

/// A canvas fitted into the space a preview has.
///
/// The fit keeps the lens's aspect, letterboxes it (centred) in the space, maps it onto **whole
/// device pixels** (its size and origin both land on the phone's pixel grid, so its edges are sharp
/// and both axes scale by exactly the same factor), and never scales past `maxPointsPerPixel`.
struct HUDCanvasScale: Equatable, Sendable {
    /// The largest scale a preview gets: one phone point per lens pixel. A Display pixel is a
    /// density-independent unit at 160, close to a phone point, so this is roughly true size;
    /// drawing larger would only magnify the estimates.
    static let maxPointsPerPixel: CGFloat = 1

    let canvas: HUDCanvas
    /// Phone points per lens pixel.
    let pointsPerPixel: CGFloat
    /// The fitted canvas, in points.
    let size: CGSize
    /// Where the fitted canvas sits inside the available space, in points (the letterbox).
    let origin: CGPoint
    /// The space it was fitted into, in points.
    let available: CGSize
    /// Device pixels per point the fit was snapped to.
    let displayScale: CGFloat

    /// Fit `canvas` into `available` points on a screen with `displayScale` pixels per point.
    /// A non-finite side (a scroll view's unbounded height) does not constrain the fit; a space with
    /// no finite side fits at `maxPointsPerPixel`. A space smaller than the lens's aspect unit gives
    /// an empty canvas.
    static func fit(_ canvas: HUDCanvas, in available: CGSize, displayScale: CGFloat = 1,
                    maxPointsPerPixel: CGFloat = HUDCanvasScale.maxPointsPerPixel) -> HUDCanvasScale {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let limit = maxPointsPerPixel.isFinite && maxPointsPerPixel > 0 ? maxPointsPerPixel : 1

        // The smallest whole-pixel rectangle with the lens's aspect (600 × 600 → 1 × 1, 576 × 288 → 2 × 1).
        let divisor = gcd(canvas.widthPixels, canvas.heightPixels)
        let unitWidth = CGFloat(canvas.widthPixels / divisor)
        let unitHeight = CGFloat(canvas.heightPixels / divisor)

        func devicePixels(_ points: CGFloat) -> CGFloat? {
            points.isFinite ? max(0, (points * scale).rounded(.down)) : nil
        }
        let availableWidth = devicePixels(available.width)
        let availableHeight = devicePixels(available.height)
        let capWidth = (CGFloat(canvas.widthPixels) * limit * scale).rounded(.down)

        var units = capWidth / unitWidth
        if let availableWidth { units = min(units, availableWidth / unitWidth) }
        if let availableHeight { units = min(units, availableHeight / unitHeight) }
        units = max(0, units.rounded(.down))

        let deviceWidth = units * unitWidth
        let deviceHeight = units * unitHeight
        let originX = availableWidth.map { (($0 - deviceWidth) / 2).rounded(.down) } ?? 0
        let originY = availableHeight.map { (($0 - deviceHeight) / 2).rounded(.down) } ?? 0

        return HUDCanvasScale(
            canvas: canvas,
            pointsPerPixel: deviceWidth / scale / CGFloat(canvas.widthPixels),
            size: CGSize(width: deviceWidth / scale, height: deviceHeight / scale),
            origin: CGPoint(x: originX / scale, y: originY / scale),
            available: available,
            displayScale: scale
        )
    }

    /// `pixels` lens pixels in phone points.
    func points(_ pixels: CGFloat) -> CGFloat { pixels * pointsPerPixel }

    /// The estimated font size of `token`, in phone points.
    func fontPoints(_ token: HUDTextToken) -> CGFloat { points(canvas.textSize(token).pixels) }

    /// True when the fitted canvas leaves bars of the available space on either axis.
    var isLetterboxed: Bool {
        let slack = 0.5 / displayScale  // under half a device pixel is rounding, not a bar
        return (available.width.isFinite && size.width < available.width - slack)
            || (available.height.isFinite && size.height < available.height - slack)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}

#if !AVENKIN_PHONE_ONLY
extension HUDCanvas {
    /// The canvas of the display backend chosen in Settings.
    static func canvas(for choice: DisplayBackendChoice) -> HUDCanvas {
        switch choice {
        case .metaRayBan: return .metaDisplay
        case .evenG2: return .evenG2
        }
    }
}
#endif
