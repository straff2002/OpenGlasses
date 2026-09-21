import XCTest
@testable import OpenGlasses

/// A model calling `new_topic` is not on its own enough to wipe the conversation.
///
/// Field build 407, Direct mode: the technician said *"start a new field service session as
/// signed job 1005"*, the model called `new_topic`, and the reset stopped the reply a second into
/// playback and opened a fresh saved thread. The words "start a new" are in the sentence; the
/// request is to start a job.
final class NewTopicRequestGateTests: XCTestCase {

    // MARK: - What must still reset

    func testTheBareResetCommandsStillReset() {
        for utterance in ["new topic", "new conversation", "start over", "start fresh",
                          "let's start a new topic", "okay new topic", "can we start over",
                          "clear the conversation", "forget this conversation", "fresh start"] {
            XCTAssertTrue(NewTopicRequestGate.isResetRequest(utterance), utterance)
        }
    }

    /// The phrasings the tool exists for — the ones the deterministic tier-0 route deliberately
    /// does not carry, because they are fragments and a model has to read the whole sentence first.
    func testTheToolOnlyPhrasingsReset() {
        for utterance in ["forget everything we just talked about",
                          "forget everything we discussed",
                          "wipe the conversation",
                          "erase this conversation"] {
            XCTAssertTrue(NewTopicRequestGate.isResetRequest(utterance), utterance)
        }
    }

    func testCaseAndPunctuationDoNotMatter() {
        XCTAssertTrue(NewTopicRequestGate.isResetRequest("  New Topic.  "))
    }

    // MARK: - What must not

    /// The reported utterance, verbatim.
    func testStartingAJobIsNotAReset() {
        XCTAssertFalse(NewTopicRequestGate.isResetRequest(
            "start a new field service session as signed job 1005"))
    }

    func testStartingAnythingElseIsNotAReset() {
        for utterance in ["start a new session",
                          "start a new job",
                          "start a new note",
                          "start a new timer",
                          "start a new recording",
                          "start a new workout",
                          "begin a new inspection for the chiller"] {
            XCTAssertFalse(NewTopicRequestGate.isResetRequest(utterance), utterance)
        }
    }

    /// "Forget everything" about a *subject* is a question, not a command to the app.
    func testForgettingSomethingSpecificIsNotAReset() {
        for utterance in ["forget everything i told you about the boiler",
                          "forget everything you know about r410a",
                          "start over from the second step"] {
            XCTAssertFalse(NewTopicRequestGate.isResetRequest(utterance), utterance)
        }
    }

    /// The reset words inside a longer request are content — the same rule tier-0 already applies.
    func testTheWordsInsideALongerRequestAreContent() {
        XCTAssertFalse(NewTopicRequestGate.isResetRequest(
            "write an essay about a new topic for my class"))
    }

    func testNoUtteranceIsNotAResetRequest() {
        XCTAssertFalse(NewTopicRequestGate.isResetRequest(""))
        XCTAssertFalse(NewTopicRequestGate.isResetRequest("   "))
    }

    // MARK: - The refusal itself

    /// It has to be readable by a model as "this did not happen", because the failure it replaces
    /// is the assistant announcing a reset that never occurred.
    func testTheRefusalSaysNothingWasCleared() {
        let refusal = NewTopicRequestGate.refusal.lowercased()
        XCTAssertTrue(refusal.contains("no reset happened"))
        XCTAssertTrue(refusal.contains("nothing was cleared"))
    }
}

/// The tool wrapper: a refused call must be inert — no notification, so no stopped speech and no
/// new thread.
@MainActor
final class NewTopicToolRefusalTests: XCTestCase {

    private func fired(_ body: () async throws -> String) async rethrows -> (String, Bool) {
        var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: .ogNewTopicRequested, object: nil, queue: nil) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(token) }
        let result = try await body()
        return (result, posted)
    }

    func testARealResetRequestGoesThrough() async throws {
        let tool = NewTopicTool(currentUtterance: { "new topic" })
        let (result, posted) = try await fired { try await tool.execute(args: [:]) }
        XCTAssertTrue(posted, "a genuine reset must still reach the coordinator")
        XCTAssertFalse(result.contains("No reset happened"))
    }

    func testTheFieldUtteranceIsRefusedWithoutTouchingAnything() async throws {
        let tool = NewTopicTool(currentUtterance: {
            "start a new field service session as signed job 1005"
        })
        let (result, posted) = try await fired { try await tool.execute(args: [:]) }
        XCTAssertFalse(posted, "a refused call must not stop speech or open a thread")
        XCTAssertEqual(result, NewTopicRequestGate.refusal)
    }

    /// No captured utterance (a typed turn) leaves the gate out of the way: the failure being
    /// guarded against is a spoken request being over-read.
    func testAnUncapturedUtteranceDoesNotBlockTheReset() async throws {
        for utterance in [nil, "", "   "] as [String?] {
            let tool = NewTopicTool(currentUtterance: { utterance })
            let (_, posted) = try await fired { try await tool.execute(args: [:]) }
            XCTAssertTrue(posted, "utterance \(String(describing: utterance))")
        }
    }
}
