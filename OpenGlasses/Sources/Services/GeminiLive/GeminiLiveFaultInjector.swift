import Foundation

/// Plan FF P1/PR5 — the faults a live session has to survive, as values.
///
/// # Why a seam and not a mock socket
///
/// The recovery ladder this plan has to prove — coalesced reconnects, capped backoff, a ten-attempt
/// limit, resumption handles, the server's own rotation — lives entirely inside
/// ``GeminiLiveService``, wired to `URLSessionWebSocketTask` through three delegate closures and one
/// timeout task. Replacing the socket wholesale would mean a second transport implementation whose
/// agreement with the real one is itself unproven, which is how a test suite comes to pass against
/// a ladder the app does not have.
///
/// So the seam is narrower and sits exactly where the real events enter: the close, the error, the
/// connect timeout and the server's `goAway` each became a named method, and injecting a fault
/// calls that same method. Everything downstream — the coalescing, the backoff, the attempt
/// counter, the exhaustion cue, the handle bookkeeping — is the production path, unmodified and
/// unaware it was not a real socket that spoke.
///
/// The two faults that cannot arrive that way, because they are about an attempt that never comes
/// up rather than a connection that dies, are scripted instead through
/// ``GeminiLiveService/ScriptedConnectOutcome``.
enum GeminiLiveFault: Equatable {

    /// The socket dropped — mid-turn, mid-answer, whenever. The ordinary network loss.
    case socketClosed(reason: String)

    /// The transport reported an error rather than a clean close.
    case socketError(reason: String)

    /// The server announced it is rotating the connection and then closed it.
    ///
    /// Not an edge case: Gemini Live sends `goAway` before its session time limit, so **every** long
    /// conversation meets this. It is a fault here only in the sense that it is a thing the session
    /// must survive without the wearer noticing.
    case serverRotation(secondsRemaining: Int)

    /// Setup never completed and the 15-second timer fired. Distinct from a close: no close and no
    /// error event arrives, which is the shape that used to strand the ladder.
    case setupTimedOut
}
