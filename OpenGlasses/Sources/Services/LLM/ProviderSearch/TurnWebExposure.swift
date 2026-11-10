import Foundation

/// Whether the turn in flight has read the web through a provider-run search (Plan KZ §5).
///
/// Our own `web_search` output reaches the model inside `<untrusted_tool_output>`; a provider's
/// search results never pass through the app before the model reads them, so the envelope cannot
/// be applied. Instead the turn is marked, and for the rest of it every high-impact tool
/// (`PromptInjectionPolicy.isHighImpact`) needs the wearer's yes even with agent mode off
/// (`ToolAuthorizationPolicy`, Decision 8). A page that says "text everyone" can at most get a
/// question the wearer says no to.
///
/// Bound per turn with `$current.withValue`, so the tool router, which runs inside the turn's
/// task, reads the mark without anything threading it through.
final class TurnWebExposure: @unchecked Sendable {
    @TaskLocal static var current: TurnWebExposure?

    private let lock = NSLock()
    private var _readWeb = false

    init() {}

    var readWeb: Bool {
        lock.lock(); defer { lock.unlock() }
        return _readWeb
    }

    func markReadWeb() {
        lock.lock(); defer { lock.unlock() }
        _readWeb = true
    }

    /// The mark for the turn the caller runs inside; false outside a turn.
    static var turnReadWeb: Bool { current?.readWeb ?? false }
}
