import Foundation

// Plan NB §3: when a wrist gesture counts, and the press that ends one. Pure and SDK-free,
// compiled and tested in every build; only a flagged (TestFlight-only) build feeds it.

/// The clutch: a wrist turns and an arm moves all the time, so a twist or an arm move counts only
/// inside one. It opens on the band's drag burst at the start of a pinch (`drag(.down)`, source
/// `neuralBandDrag`) and closes at the first of: that pinch's `select`, a `drag(.down)` that starts
/// a new pinch (which opens the next clutch), or `cap` after it opened. Without a burst nothing
/// opens. Pure: the clock is passed in.
struct TwistClutch: Equatable {
    static let cap: Duration = .seconds(3)

    enum CloseReason: String, Equatable {
        case select, newPinch, cap
    }

    enum Change: Equatable {
        case opened
        case closed(CloseReason)
    }

    var cap: Duration = TwistClutch.cap
    private(set) var openedAt: ContinuousClock.Instant?

    var isOpen: Bool { openedAt != nil }

    /// What one input from the band does to the clutch, in order (a new pinch closes the old
    /// clutch, then opens its own).
    mutating func handle(_ input: GlassesInput, at now: ContinuousClock.Instant) -> [Change] {
        var changes: [Change] = expire(at: now).map { [$0] } ?? []
        switch input.kind {
        case .drag(.down) where input.origin == .neuralBandDrag:
            if isOpen { changes.append(.closed(.newPinch)) }
            openedAt = now
            changes.append(.opened)
        case .select where isOpen:
            openedAt = nil
            changes.append(.closed(.select))
        default:
            break
        }
        return changes
    }

    /// Closes a clutch open for longer than `cap`.
    mutating func expire(at now: ContinuousClock.Instant) -> Change? {
        guard let openedAt, now - openedAt >= cap else { return nil }
        self.openedAt = nil
        return .closed(.cap)
    }
}

/// A held pinch ends in a `select`, and Meta presses the focused button with it (in the zoomed
/// view, Back). So a press within `window` of a clutch that sent at least one twist rung or arm
/// move is dropped (`LensPageSession.press(itemID:)`), and counted: a gesture never closes the
/// view it was changing (Plan NB §3, decision 5). The `select` and Meta's press may arrive either
/// way round, so a press while such a clutch is still open is dropped too; one press a clutch,
/// and never past the clutch's cap. Pure: the clock is passed in.
struct ClutchPressGuard: Equatable {
    static let window: Duration = .milliseconds(800)

    var window: Duration = ClutchPressGuard.window
    private(set) var openedAt: ContinuousClock.Instant?
    /// The open clutch sent a rung or a move.
    private(set) var sentInClutch = false
    /// The open clutch's press was already dropped.
    private var swallowedThisClutch = false
    /// When the last clutch that sent closed, until its window passes or a press is dropped.
    private(set) var closedWithSendsAt: ContinuousClock.Instant?

    mutating func clutchOpened(at now: ContinuousClock.Instant) {
        openedAt = now
        sentInClutch = false
        swallowedThisClutch = false
        closedWithSendsAt = nil
    }

    /// A rung or a move was sent (or asked for) in the open clutch.
    mutating func sent() {
        if openedAt != nil { sentInClutch = true }
    }

    mutating func clutchClosed(at now: ContinuousClock.Instant) {
        if openedAt != nil, sentInClutch, !swallowedThisClutch { closedWithSendsAt = now }
        openedAt = nil
        sentInClutch = false
        swallowedThisClutch = false
    }

    /// Whether a press at `now` is the one that ends a gesture: true drops it.
    mutating func swallows(at now: ContinuousClock.Instant) -> Bool {
        if let openedAt, sentInClutch, !swallowedThisClutch, now - openedAt <= TwistClutch.cap + window {
            swallowedThisClutch = true
            return true
        }
        if let closed = closedWithSendsAt, now - closed <= window {
            closedWithSendsAt = nil
            return true
        }
        return false
    }
}

/// The wrist gestures on the page view, from the band's inputs and its motion samples to what the
/// page view is asked for (Plan NB §2–§3; P2's service only hosts it). Pure.
///
/// - **The clutch** (`TwistClutch`) decides when anything counts; each clutch starts the twist and
///   the arm afresh.
/// - **Twist to zoom** (`TwistTracker` → `TwistZoomDetent`) and **pinch and move to pan**
///   (`ArmPan`) are each their own switch, read when a clutch opens.
/// - **They never fight.** With both on, whichever first passes its threshold in a clutch owns it,
///   and the other is ignored until the clutch closes.
struct LensWristGestures: Equatable {

    struct Switches: Equatable {
        var twist: Bool
        var pan: Bool
        var direction: TwistDirection = .clockwiseZoomsIn
    }

    enum Owner: String, Equatable {
        case twist, pan
    }

    enum Output: Equatable {
        case clutchOpened
        case clutchClosed(TwistClutch.CloseReason)
        case rung(TwistRung)
        case pan(LensPageViewport.Step)
    }

    private(set) var clutch = TwistClutch()
    private(set) var owner: Owner?
    private(set) var switches = Switches(twist: false, pan: false)
    private var tracker = TwistTracker()
    private var detent = TwistZoomDetent()
    private var arm = ArmPan()

    init(clutch: TwistClutch = TwistClutch()) {
        self.clutch = clutch
    }

    /// One input from the band. `switches` are read when a clutch opens.
    mutating func input(_ input: GlassesInput, at now: ContinuousClock.Instant, switches: Switches) -> [Output] {
        let changes = clutch.handle(input, at: now)
        var outputs: [Output] = []
        for change in changes {
            switch change {
            case .opened:
                begin(switches)
                outputs.append(.clutchOpened)
            case .closed(let reason):
                owner = nil
                outputs.append(.clutchClosed(reason))
            }
        }
        return outputs
    }

    /// One motion sample from the band.
    mutating func sample(_ sample: WristSample, at now: ContinuousClock.Instant) -> [Output] {
        var outputs: [Output] = []
        if let change = clutch.expire(at: now), case .closed(let reason) = change {
            owner = nil
            outputs.append(.clutchClosed(reason))
        }
        guard clutch.isOpen else { return outputs }
        if switches.twist, owner != .pan, let angle = tracker.add(sample) {
            let rungs = detent.update(angle: angle)
            if !rungs.isEmpty { owner = .twist }
            outputs += rungs.map(Output.rung)
        }
        if switches.pan, owner != .twist, let step = arm.update(sample) {
            owner = .pan
            outputs.append(.pan(step))
        }
        return outputs
    }

    /// Closes a clutch past its cap with no sample to notice it.
    mutating func expire(at now: ContinuousClock.Instant) -> [Output] {
        guard let change = clutch.expire(at: now), case .closed(let reason) = change else { return [] }
        owner = nil
        return [.clutchClosed(reason)]
    }

    private mutating func begin(_ switches: Switches) {
        self.switches = switches
        owner = nil
        tracker = TwistTracker()
        detent = TwistZoomDetent(direction: switches.direction)
        arm = ArmPan()
    }
}

/// What the page view did with one twist rung or arm-pan step (`LensPageSession.handleTwist`,
/// `handleArmPan`).
enum LensTwistOutcome: Equatable {
    /// The page view is not what the lens shows.
    case notOnLens
    /// Nothing to do in this view, or at the cap or an edge.
    case nothingToDo
    /// Part of a burst: a send was still in flight, or the last one was too recent.
    case dropped
    case sent
}
