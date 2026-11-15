import Foundation

/// Why a private conversation ended (Plan LU §8). Content-free by construction, so it can be the
/// payload of the one `PrivacyLog` line a private conversation leaves.
enum PrivateEndReason: String, Equatable, Sendable, CaseIterable {
    /// "End private", "stop private", "back on the record".
    case endPhrase
    /// End, tapped on the conversation page's Private badge.
    case endButton
    /// End, from the watch.
    case watch
    case glassesDisconnected
    /// 30 minutes without a turn (`JobThreadPolicy.conversationIdleGap`).
    case idle
    /// New conversation (`ConversationContinuity.startFresh`).
    case startFresh
    /// Another stored conversation was opened.
    case otherConversationOpened
    /// `conversationReset.requestReset`.
    case conversationReset
    /// A Field Assist job started: its record has to be complete.
    case jobStarted
    /// The organisation's profile switched private conversations off.
    case organisationSwitchedOff
    /// A Live session that was started private stopped.
    case liveStopped
    case appQuit
}

/// Something that happened while a private conversation might be open (Plan LU §8).
enum PrivateEndEvent: Equatable, Sendable {
    case endPhrase
    case endButton
    case endOnWatch
    case glassesDisconnected
    /// A turn is about to start; `quietFor` is the time since the private conversation's last turn.
    case turnStarting(quietFor: TimeInterval)
    /// The quiet-gap timer fired; `quietFor` is the time since the last turn.
    case idleTimerFired(quietFor: TimeInterval)
    case startFresh
    case otherConversationOpened
    case conversationReset
    case jobStarted
    case organisationSwitchedOff
    /// A Live session stopped. Ends a private conversation only when that session was the private
    /// one; an ordinary Live session ending leaves a phone-side private conversation alone.
    case liveStopped(sessionWasPrivate: Bool)
    /// The app went to the background. Never an end: the wearer may be using the glasses with the
    /// phone locked.
    case appBackgrounded
    case appQuit
}

/// Whether an event ends the private conversation (Plan LU §8). Pure: `(state, event) → decision`.
///
/// A private conversation that has ended cannot be reopened; the next turn after any end is an
/// ordinary one.
enum PrivateEndPolicy {

    enum Decision: Equatable, Sendable {
        case stay
        case end(PrivateEndReason)
    }

    /// The quiet gap after which a private conversation ends: the same gap after which an ordinary
    /// conversation is left behind, so the two never disagree.
    static var idleGap: TimeInterval { JobThreadPolicy.conversationIdleGap }

    static func decide(_ state: PrivateConversationState, _ event: PrivateEndEvent) -> Decision {
        guard state.isActive else { return .stay }
        switch event {
        case .endPhrase: return .end(.endPhrase)
        case .endButton: return .end(.endButton)
        case .endOnWatch: return .end(.watch)
        case .glassesDisconnected: return .end(.glassesDisconnected)
        case .turnStarting(let quietFor), .idleTimerFired(let quietFor):
            return quietFor >= idleGap ? .end(.idle) : .stay
        case .startFresh: return .end(.startFresh)
        case .otherConversationOpened: return .end(.otherConversationOpened)
        case .conversationReset: return .end(.conversationReset)
        case .jobStarted: return .end(.jobStarted)
        case .organisationSwitchedOff: return .end(.organisationSwitchedOff)
        case .liveStopped(let sessionWasPrivate): return sessionWasPrivate ? .end(.liveStopped) : .stay
        case .appBackgrounded: return .stay
        case .appQuit: return .end(.appQuit)
        }
    }
}
