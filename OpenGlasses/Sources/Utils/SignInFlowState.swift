import Foundation

/// The lifecycle of one account sign-in attempt (Plan DD P1) — pure, so the rules about what may
/// follow what are testable without a sheet, a socket, or a network.
///
/// The shape is `idle → presenting → captured → exchanging → connected | failed | cancelled`,
/// with two ways in to `exchanging`: a code the loopback listener caught, or one the user pasted.
/// Every unhappy ending keeps the paste fallback on screen, so a failure is never a dead end.
enum SignInFlowState: Equatable {
    case idle
    /// The sign-in sheet is up. `listening` is true when the provider's redirect is one we can
    /// answer ourselves, so a loopback listener is running for the sheet's lifetime.
    case presenting(listening: Bool)
    /// The listener caught a valid, state-matched callback.
    case captured
    /// Trading the authorization code for tokens.
    case exchanging
    case connected
    case failed(reason: String)
    case cancelled

    enum Event: Equatable {
        case present(listening: Bool)
        /// The loopback listener caught the callback.
        case capture
        /// Start the token exchange (from a capture, or from a pasted code).
        case beginExchange
        case succeed
        case fail(reason: String)
        /// The sheet went away without a result.
        case cancel
        /// Back to the start — retry, or sign out.
        case reset
    }

    /// The state this event leads to, or nil when the transition isn't legal from here.
    func applying(_ event: Event) -> SignInFlowState? {
        switch (self, event) {
        case (_, .reset):
            return .idle

        case (.idle, .present(let listening)),
             (.failed, .present(let listening)),
             (.cancelled, .present(let listening)):
            return .presenting(listening: listening)

        case (.presenting(let listening), .capture):
            // Only a flow that is actually listening can capture.
            return listening ? .captured : nil

        case (.captured, .beginExchange),
             // The paste fallback: the sheet may still be up, or may already have been
             // dismissed or failed — pasting a code picks up from any of them.
             (.presenting, .beginExchange),
             (.cancelled, .beginExchange),
             (.failed, .beginExchange):
            return .exchanging

        case (.exchanging, .succeed):
            return .connected

        case (.presenting, .fail(let reason)),
             (.captured, .fail(let reason)),
             (.exchanging, .fail(let reason)):
            return .failed(reason: reason)

        case (.presenting, .cancel),
             (.captured, .cancel):
            return .cancelled

        default:
            return nil
        }
    }

    /// Apply an event in place. Returns false (leaving the state untouched) for an illegal move.
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        guard let next = applying(event) else { return false }
        self = next
        return true
    }

    /// Whether the loopback listener should be running right now.
    var isListening: Bool {
        if case .presenting(let listening) = self { return listening }
        return false
    }

    /// Whether the sign-in sheet should be on screen.
    var isPresenting: Bool {
        switch self {
        case .presenting, .captured: return true
        default: return false
        }
    }

    /// Whether work is in flight the UI should show a spinner for.
    var isBusy: Bool {
        switch self {
        case .captured, .exchanging: return true
        default: return false
        }
    }

    /// Nothing more will happen without the user acting again.
    var isTerminal: Bool {
        switch self {
        case .connected, .failed, .cancelled: return true
        default: return false
        }
    }

    /// The message to surface, if any.
    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
