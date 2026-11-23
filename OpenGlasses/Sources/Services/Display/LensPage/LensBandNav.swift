import Foundation

/// A Neural Band swipe the page view may act on (Plan MU §7, P6): left or right, in the app's own
/// words. Only a flagged (TestFlight-only) build hears the band at all: its Inputs wiring lives in
/// `Sources/Glasses/Experimental/` and hands each swipe here. Compiled and tested in every build,
/// so the mapping is ready for the store build if Meta makes Inputs stable.
///
/// **Up and down are never taken**: they stay the lens's own scroll. **Back** is never taken
/// either (the capability is added with Back left to Meta). Every other input is ignored.
enum LensBandNav: String, Equatable, CaseIterable {
    case left, right

    /// The swipe an input is, if it is one the page view maps: a `nav` left or right. Up, down,
    /// select (the pinch, which already presses the focused item through Meta's own focus), back,
    /// drag and the buttons are nil.
    init?(_ kind: GlassesInputKind) {
        switch kind {
        case .nav(.left): self = .left
        case .nav(.right): self = .right
        case .nav(.up), .nav(.down), .select, .back, .actionButton, .capture, .drag, .unknown:
            return nil
        }
    }
}

/// What a band swipe does to the page view: one send each.
enum LensBandPageAction: Equatable {
    /// A close-up cut into halves: only the right half, under its marker.
    case rightHalf
    /// Back to the close-up as it opens: both halves stacked, the left one first, where the
    /// strip starts.
    case leftHalf
    /// Fit width: the page before or after, at fit width from its top.
    case previousPage
    case nextPage
    /// Plan NB §1: a spoken zoom (the zoomed view): the crop half a crop to the left or right
    /// (`LensPageViewport.move`), nothing at the edge.
    case panLeft
    case panRight
}

/// Which page action a swipe asks for, from what the lens shows (Plan MU §7, decision 8). Pure.
///
/// | View | Left | Right |
/// |---|---|---|
/// | close-up with halves, both shown (as it opens) | – (already at the left half) | the right half |
/// | close-up, the right half | both halves, from the left | – (the edge) |
/// | close-up, the left half ("left half" by voice) | – (the edge) | the right half |
/// | close-up of a part in one column | – | – |
/// | fit width | the page before (none on the first) | the page after (none on the last) |
/// | a spoken zoom (Plan NB §1) | half a crop to the left (none at the edge) | half a crop to the right (none at the edge) |
/// | whole page, rows, reading | – | – |
///
/// Nothing wraps. The whole page, the rows and reading mode map nothing: the plan gives the band's
/// left and right only to the close-up's halves, to fit width and to the zoomed view, the whole
/// page's and the close-up's own button rows may need left and right for Meta's focus, and those
/// views already have one press for what a swipe would do (Next page ›, Next ›). The zoomed view
/// has one button (Back), so Meta's focus does not need left and right there; up and down stay
/// the lens's own scroll of its strip.
enum LensBandNavMap {

    /// What the map reads of the view.
    struct Context: Equatable {
        var view: HUDPageViewState.View
        /// The close-up's kind, when one is up.
        var closeUpKind: LensPageCloseUp.Kind?
        /// The close-up is cut into a left and a right half.
        var hasHalves = false
        /// Which half alone is shown ("left half" / "right half" by voice, or a swipe); nil for both.
        var only: LensPageCloseUp.Half?
        /// The open page among the staged ones.
        var pageIndex = 0
        var pageCount = 1
        /// Plan NB §1: in the zoomed view, whether the crop can move half a crop that way (false
        /// against the page's edge).
        var canPanLeft = false
        var canPanRight = false

        init(view: HUDPageViewState.View, closeUpKind: LensPageCloseUp.Kind? = nil, hasHalves: Bool = false,
             only: LensPageCloseUp.Half? = nil, pageIndex: Int = 0, pageCount: Int = 1,
             canPanLeft: Bool = false, canPanRight: Bool = false) {
            self.view = view
            self.closeUpKind = closeUpKind
            self.hasHalves = hasHalves
            self.only = only
            self.pageIndex = pageIndex
            self.pageCount = pageCount
            self.canPanLeft = canPanLeft
            self.canPanRight = canPanRight
        }

        init(_ state: HUDPageViewState, pageIndex: Int, pageCount: Int) {
            let zoomed = state.view == .zoomed
            self.init(view: state.view, closeUpKind: state.closeUp?.kind, hasHalves: state.closeUp?.hasHalves ?? false,
                      only: state.closeUp?.only, pageIndex: pageIndex, pageCount: pageCount,
                      canPanLeft: zoomed && state.viewport.canMove(.left),
                      canPanRight: zoomed && state.viewport.canMove(.right))
        }
    }

    static func action(for nav: LensBandNav, in context: Context) -> LensBandPageAction? {
        if context.view == .zoomed {
            switch nav {
            case .left: return context.canPanLeft ? .panLeft : nil
            case .right: return context.canPanRight ? .panRight : nil
            }
        }
        guard context.view == .closeUp, let kind = context.closeUpKind else { return nil }
        switch kind {
        case .part:
            guard context.hasHalves else { return nil }
            switch nav {
            case .right: return context.only == .right ? nil : .rightHalf
            case .left: return context.only == .right ? .leftHalf : nil
            }
        case .fitWidth:
            switch nav {
            case .left: return context.pageIndex > 0 ? .previousPage : nil
            case .right: return context.pageIndex + 1 < context.pageCount ? .nextPage : nil
            }
        }
    }
}

/// One band send in flight at a time (Plan MU §7). A swipe is let through only when the frame the
/// last one asked for has reached the glasses (or failed, or was never drawn), and at least
/// `minimumSpacing` after it; the rest of a burst is dropped, never queued. A send whose word never
/// comes frees the gate after `sendTimeout`. Pure: the clock is passed in.
struct LensBandNavGate: Equatable {
    /// The shortest time between two swipes acted on.
    static let minimumSpacing: Duration = .milliseconds(400)
    /// How long a send may be waited for before the gate frees itself.
    static let sendTimeout: Duration = .seconds(4)

    var minimumSpacing: Duration = LensBandNavGate.minimumSpacing
    var sendTimeout: Duration = LensBandNavGate.sendTimeout

    /// When the send in flight was let through; nil when none is.
    private(set) var inFlightSince: ContinuousClock.Instant?
    /// When the last swipe was let through.
    private(set) var lastAdmitted: ContinuousClock.Instant?

    init(minimumSpacing: Duration = LensBandNavGate.minimumSpacing,
         sendTimeout: Duration = LensBandNavGate.sendTimeout) {
        self.minimumSpacing = minimumSpacing
        self.sendTimeout = sendTimeout
    }

    var isSending: Bool { inFlightSince != nil }

    /// Whether a swipe at `now` may send. True also marks the send in flight.
    mutating func admit(at now: ContinuousClock.Instant) -> Bool {
        if let since = inFlightSince {
            guard now - since >= sendTimeout else { return false }
            inFlightSince = nil
        }
        if let last = lastAdmitted, now - last < minimumSpacing { return false }
        inFlightSince = now
        lastAdmitted = now
        return true
    }

    /// The send in flight reached the glasses, failed, or was never drawn.
    mutating func finished() {
        inFlightSince = nil
    }
}

/// What the page view did with one input from the band (`LensPageSession.handleBand`).
enum LensBandOutcome: Equatable {
    /// Not a left or right swipe (up and down stay the lens's own scroll; select, back, drag and
    /// the buttons are not mapped).
    case notMapped
    /// The page view is not what the lens shows.
    case notOnLens
    /// A left or right swipe with nothing to do in this view, or at an edge.
    case nothingToDo
    /// Part of a burst: a send was still in flight, or the last swipe was too recent.
    case dropped
    case sent(LensBandPageAction)
}

/// What the page view asks the glasses for while it listens to the band (Plan MU §7): the Neural
/// Band's discrete inputs only, its swipes (`nav`) and presses. Never the touchpad, the capture
/// button or the action button, and Back is left to Meta. The SDK-side configuration is built from
/// the same answers, and `DATExperimentalGuardTests` pins both.
///
/// Plan NB §6: while a wrist gesture is switched on (twist to zoom, or pinch and move to pan), the
/// band's drag stream is asked for too (`originsWithDrag`): its burst at the start of a pinch is
/// what opens the clutch (`TwistClutch`). Only then.
enum LensBandNavPolicy {
    static let origins: Set<GlassesInputOrigin> = [.neuralBand]
    static let originsWithDrag: Set<GlassesInputOrigin> = [.neuralBand, .neuralBandDrag]
    static let consumesBack = false
}
