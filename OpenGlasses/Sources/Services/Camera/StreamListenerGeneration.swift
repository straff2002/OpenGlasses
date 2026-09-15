import Foundation

/// Which set of stream listeners a callback belongs to, so that a callback from a stream that has
/// been torn down cannot act on the one that replaced it.
///
/// The SDK's listener tokens are cancelled through `ListenerTokenBag.cancelAll()`, which is
/// **async**: between asking for the cancel and its completion, a frame, a state change or an error
/// from the old stream can still arrive. Those callbacks hop to the main actor and then touch state
/// — `isStreaming`, the frame clock, the wait reason, the reconnect ladder — that by then belongs
/// to a different camera. A stale `.stopped` arriving just after a rebuild is enough to schedule a
/// reconnect for a stream that is already coming up.
///
/// The fix is the same shape as `StreamStartGeneration`, one axis over: a start is superseded by a
/// stop, and a *listener* is superseded by the next attach. Each attach takes the next generation
/// and every closure it installs carries that value; `accepts(_:)` is the whole test.
///
/// Pure value type — the owner does the dropping.
struct StreamListenerGeneration: Equatable {

    /// The generation callbacks must carry to be acted on.
    private(set) var current = 0

    init() {}

    /// Begin a new set of listeners. Everything installed before this moment is now stale.
    mutating func rotate() -> Int {
        current += 1
        return current
    }

    /// Whether a callback carrying `generation` describes the stream we are listening to now.
    func accepts(_ generation: Int) -> Bool { generation == current }
}
