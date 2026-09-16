import Foundation

/// Plan FF P1/PR8 — "how are my requests processed", answered without looking at a screen.
///
/// The one voice phrase this phase adds. It exists because the question is bare and unambiguous
/// ("how are my requests processed", "where do my requests go") and because the answer is exactly
/// what a wearer wants *before* holding up a letter — at which point reaching Settings, finding
/// Accessibility and finding a row is the wrong shape of task.
///
/// It is reached the same two ways `new_topic` is: the classifier's Tier-0 route, bare-query gated
/// so the phrase inside a longer sentence still reaches the model as content, and ordinary tool
/// calling for phrasings the classifier does not match. **No new router.**
///
/// The readiness walk-through deliberately has *no* voice phrase. It claims the camera and speaks
/// a test line, which a live session is already holding — running it from inside a conversation
/// would fight the session for both, and the check would be measuring the fight.
@MainActor
final class ProcessingSummaryTool: NativeTool {
    let name = "processing_summary"
    let description = """
    Say where each part of a request goes with the current settings: the camera picture, what the \
    user says, the answer, the voice they hear, and any tools running on other machines. Each one \
    is reported as on this device, a named provider, a server the user configured, switched off, \
    or configured for on-device with its files not downloaded. Also says whether the setup as a \
    whole is fully on-device, mixed, or cloud, and names anything that must be downloaded before \
    offline use. Use when the user asks "how are my requests processed", "where do my requests \
    go", "is this running locally", "does my data leave the phone" or similar. Takes no \
    parameters. This describes configured routing, not a record of what was actually sent.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any]
    ]

    /// Injected so the tool can be exercised without the app's real settings.
    private let facts: @MainActor () -> ProcessingFacts

    init(facts: @escaping @MainActor () -> ProcessingFacts = { ProcessingFactsProvider.current() }) {
        self.facts = facts
    }

    func execute(args: [String: Any]) async throws -> String {
        ProcessingSummary.compose(facts: facts()).spoken
    }
}
