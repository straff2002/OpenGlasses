import XCTest
@testable import OpenGlasses

/// The model-switch notice plays alongside the request rather than in front of it. A tester's log
/// showed every routed turn waiting out "Switching to … for this." (2 s) — and a photo turn the
/// 5 s vision-hop line — before the request even started. These pin the ordering that replaced it:
/// the request starts while the notice plays, the reply never cuts the notice off, and a barge-in
/// drops the notice's follow-up.
@MainActor
final class TurnAnnouncementTests: XCTestCase {

    /// Holds a fake utterance "playing" until the test lets it finish.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private var log: Box<[String]>!
    private var gates: [String: Gate] = [:]
    private var finishedCount: Box<Int>!

    override func setUp() async throws {
        log = Box([])
        gates = [:]
        finishedCount = Box(0)
    }

    private func makeAnnouncement() -> TurnAnnouncement {
        let log: Box<[String]> = self.log, finishedCount: Box<Int> = self.finishedCount
        return TurnAnnouncement(
            speak: { [unowned self] text, _ in
                log.value.append("start \(text)")
                await self.gate(text).wait()
                log.value.append("end \(text)")
            },
            onFinished: { finishedCount.value += 1 })
    }

    private func gate(_ text: String) -> Gate {
        if let gate = gates[text] { return gate }
        let gate = Gate()
        gates[text] = gate
        return gate
    }

    /// Let main-actor work run until `condition` holds (bounded, so a regression fails, not hangs).
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testAnnounceReturnsBeforeTheNoticeHasPlayed() async {
        let announcement = makeAnnouncement()
        announcement.announce("Switching", source: .switchNotice)
        log.value.append("request started")
        XCTAssertTrue(announcement.isPending)

        await settle { log.value.contains("start Switching") }
        XCTAssertEqual(log.value, ["request started", "start Switching"],
                       "the request must not wait for the notice")

        gate("Switching").open()
        await announcement.waitUntilSpoken()
        XCTAssertEqual(log.value.last, "end Switching")
    }

    func testReplyWaitsForTheNoticeToFinish() async {
        let announcement = makeAnnouncement()
        announcement.announce("Switching", source: .switchNotice)
        await settle { log.value.contains("start Switching") }

        let reply = Task { @MainActor in
            await announcement.waitUntilSpoken()
            self.log.value.append("reply")
        }
        await settle { false }   // give the reply every chance to jump the queue
        XCTAssertFalse(log.value.contains("reply"), "the reply would cut the notice off mid-word")

        gate("Switching").open()
        await reply.value
        XCTAssertEqual(log.value, ["start Switching", "end Switching", "reply"])
        XCTAssertFalse(announcement.isPending)
        XCTAssertEqual(finishedCount.value, 0,
                       "a reply already waiting takes the speaker; no thinking sound in between")
    }

    func testNoticeEndingWithTheTurnStillWorkingRunsOnFinished() async {
        let announcement = makeAnnouncement()
        announcement.announce("Switching", source: .switchNotice)
        await settle { log.value.contains("start Switching") }

        gate("Switching").open()
        await settle { !announcement.isPending }
        XCTAssertEqual(finishedCount.value, 1, "the thinking sound comes back while the model works")
    }

    func testCancelDropsTheNoticesFollowUp() async {
        let announcement = makeAnnouncement()
        announcement.announce("Switching", source: .switchNotice)
        await settle { log.value.contains("start Switching") }

        announcement.cancel()
        XCTAssertFalse(announcement.isPending)
        gate("Switching").open()   // the caller's stopSpeaking() ends the audio
        await settle { log.value.contains("end Switching") }
        await settle { false }
        XCTAssertEqual(finishedCount.value, 0, "a barged-in turn must not restart the thinking sound")
    }

    func testCancelBeforePlaybackStartsSaysNothing() async {
        let announcement = makeAnnouncement()
        announcement.announce("Switching", source: .switchNotice)
        announcement.cancel()
        await settle { false }
        XCTAssertEqual(log.value, [])
        XCTAssertEqual(finishedCount.value, 0)
    }

    func testASecondNoticeQueuesBehindTheFirst() async {
        let announcement = makeAnnouncement()
        announcement.announce("first", source: .switchNotice)
        announcement.announce("second", source: .switchNotice)
        await settle { log.value.contains("start first") }
        await settle { false }
        XCTAssertEqual(log.value, ["start first"], "the second notice must not cut off the first")

        gate("first").open()
        await settle { log.value.contains("start second") }
        gate("second").open()
        await settle { !announcement.isPending }
        XCTAssertEqual(log.value, ["start first", "end first", "start second", "end second"])
        await settle { false }
        XCTAssertEqual(finishedCount.value, 1, "only the last notice hands back to the thinking sound")
    }

    func testWaitingWithNothingPendingReturnsAtOnce() async {
        let announcement = makeAnnouncement()
        await announcement.waitUntilSpoken()
        XCTAssertFalse(announcement.isPending)
        XCTAssertEqual(finishedCount.value, 0)
    }

    /// The turn as the live host runs it: the request is sent while the notice is still playing,
    /// and the reply is spoken only once the notice has finished.
    func testTurnSendsWhileTheNoticePlaysAndSpeaksAfterIt() async {
        let announcement = makeAnnouncement()
        let log: Box<[String]> = self.log
        announcement.announce("Switching", source: .switchNotice)

        let turn = Task { @MainActor in
            await ConversationTurnRunner.run(ConversationTurnRunner.Deps(
                send: {
                    log.value.append("send (notice pending: \(announcement.isPending))")
                    return "answer"
                },
                postProcess: { $0 },
                accept: { _ in log.value.append("accept") },
                speak: { log.value.append("speak \($0)") },
                onCancelled: { log.value.append("onCancelled") },
                onError: { _ in log.value.append("onError") },
                finish: { log.value.append("finish") },
                waitForAnnouncement: { await announcement.waitUntilSpoken() }
            ))
        }
        await settle { log.value.contains("accept") && log.value.contains("start Switching") }
        await settle { false }
        XCTAssertTrue(log.value.contains("send (notice pending: true)"),
                      "the request must start while the notice is still playing")
        XCTAssertFalse(log.value.contains { $0.hasPrefix("speak") }, "the reply waits for the notice")

        gate("Switching").open()
        await turn.value
        XCTAssertEqual(Array(log.value.suffix(3)), ["end Switching", "speak answer", "finish"])
    }
}
