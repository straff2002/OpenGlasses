import Foundation
import CallKit

/// One call as the system reports it: the fields of `CXCall` this app reads, and no more.
struct ObservedCall: Equatable, Sendable {
    let id: UUID
    let isOutgoing: Bool
    let hasConnected: Bool
    let hasEnded: Bool
}

/// The seam over `CXCallObserver` (Plan KM P0): what calls the phone has, as they change. A real
/// adapter for the app, a fake for tests.
@MainActor
protocol CallObserving: AnyObject {
    /// Called on the main actor with each call that changed.
    var onChange: ((ObservedCall) -> Void)? { get set }
}

/// The real adapter. `CXCallObserver` needs no permission and sees calls in progress on the phone:
/// whether a call this app's URL started connected, and when it ended. It never sees who was
/// called or hears anything. Whether a FaceTime call placed by URL appears here is a device check
/// (Plan KM P5).
@MainActor
final class SystemCallObserver: NSObject, CallObserving, CXCallObserverDelegate {
    var onChange: ((ObservedCall) -> Void)?
    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let observed = ObservedCall(id: call.uuid, isOutgoing: call.isOutgoing,
                                    hasConnected: call.hasConnected, hasEnded: call.hasEnded)
        // The delegate queue is main; hop explicitly so the isolation is stated, not assumed.
        Task { @MainActor [weak self] in self?.onChange?(observed) }
    }
}

/// Which call is the one placed to an expert, and what was seen of it. Pure.
///
/// The app opens a URL and iOS asks the technician to tap Call, so the call it started is the first
/// **outgoing** call that appears within `window` of the placement. Anything else — an incoming
/// call, an outgoing call long after, a second call while the first is bound — is not this one.
struct ExpertCallWatch: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case started(Date)
        case connected(Date)
        /// The call ended; `connected` says whether it ever had.
        case ended(Date, connected: Bool)
    }

    static let window: TimeInterval = 120

    let expertId: String
    let placedAt: Date
    private(set) var callId: UUID?
    private(set) var connectedAt: Date?
    private(set) var endedAt: Date?

    init(expertId: String, placedAt: Date) {
        self.expertId = expertId
        self.placedAt = placedAt
    }

    /// Nothing more will be seen: the call ended, or none appeared in the window.
    func isFinished(at now: Date) -> Bool {
        endedAt != nil || (callId == nil && now.timeIntervalSince(placedAt) > Self.window)
    }

    /// Fold one observation in, returning what it changed.
    mutating func observe(_ call: ObservedCall, at now: Date) -> [Change] {
        guard endedAt == nil else { return [] }
        var changes: [Change] = []
        if callId == nil {
            // A call first seen already ended (tapped Cancel at once) is still this one, ending.
            guard call.isOutgoing, now >= placedAt,
                  now.timeIntervalSince(placedAt) <= Self.window else { return [] }
            callId = call.id
            changes.append(.started(now))
        }
        guard call.id == callId else { return changes }
        if call.hasConnected, connectedAt == nil {
            connectedAt = now
            changes.append(.connected(now))
        }
        if call.hasEnded {
            endedAt = now
            changes.append(.ended(now, connected: connectedAt != nil))
        }
        return changes
    }
}

/// Watches the call placed to an expert and writes what it saw on the escalation record (Plan KM
/// P0). While the call is up the voice loop is paused through `ExpertCallAudioCoordinator`, as a
/// live expert call already does, and resumed when it ends. A call that ends without connecting
/// leaves one offer: "Sam didn't answer. Try Priya?".
@MainActor
final class ExpertCallMonitor {
    struct Seen: Equatable {
        let expertId: String
        let change: ExpertCallWatch.Change
    }

    /// Created on the first call placed, so a phone that never calls an expert never observes.
    var makeObserver: () -> CallObserving = { SystemCallObserver() }
    var now: () -> Date = Date.init
    /// Where what was seen goes: the escalation record, by default.
    var record: (Seen) -> Void
    var audio: ExpertCallAudioCoordinator

    private var observer: CallObserving?
    private(set) var watch: ExpertCallWatch?
    private var pausedVoice = false
    /// The pick the call came from, in order, for the no-answer offer.
    private var order: [EscalationContact] = []
    private var called: EscalationContact?
    /// The offer left by a call that ended without connecting, until something is said or done.
    private(set) var noAnswerOffer: String?
    /// The expert that offer names.
    private(set) var noAnswerNext: EscalationContact?

    /// `audio` defaults to the shared coordinator (a default argument can't name a main-actor value).
    init(record: @escaping (Seen) -> Void, audio: ExpertCallAudioCoordinator? = nil) {
        self.record = record
        self.audio = audio ?? .shared
    }

    /// A call to `expert` was just placed; `order` is the pick it came from (just the expert for a
    /// call by name).
    func expect(_ expert: EscalationContact, order: [EscalationContact]) {
        if observer == nil {
            let made = makeObserver()
            made.onChange = { [weak self] call in self?.handle(call) }
            observer = made
        }
        endVoicePause()
        watch = ExpertCallWatch(expertId: expert.id, placedAt: now())
        called = expert
        self.order = order
        noAnswerOffer = nil
        noAnswerNext = nil
    }

    func clearOffer() {
        noAnswerOffer = nil
        noAnswerNext = nil
    }

    func handle(_ call: ObservedCall) {
        guard var current = watch else { return }
        let at = now()
        if current.isFinished(at: at) { watch = nil; return }
        let changes = current.observe(call, at: at)
        watch = current
        for change in changes {
            record(Seen(expertId: current.expertId, change: change))
            switch change {
            case .started:
                if audio.beginCall() == .started { pausedVoice = true }
            case .connected:
                break
            case .ended(_, let connected):
                endVoicePause()
                if !connected, let called {
                    let next = NoAnswerOffer.next(after: called, in: order)
                    noAnswerNext = next
                    noAnswerOffer = NoAnswerOffer.sentence(missed: called, next: next)
                }
                watch = nil
            }
        }
    }

    private func endVoicePause() {
        guard pausedVoice else { return }
        pausedVoice = false
        audio.endCall()
    }
}
