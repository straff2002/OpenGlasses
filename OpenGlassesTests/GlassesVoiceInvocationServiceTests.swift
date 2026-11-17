#if DAT_EXPERIMENTAL
import XCTest
@testable import OpenGlasses

/// "Hey Meta, open Avenkin" end to end, with a fake stream behind `VoiceInvocationSource` (Plan JV
/// P1). Compiled only in a flagged project: the ordinary suite has no experimental code to test.
/// Never touches `Wearables.shared`.
@MainActor
final class GlassesVoiceInvocationServiceTests: XCTestCase {

    // MARK: - Fakes

    private struct Opened: Error {}

    @MainActor
    private final class FakeChannel: VoiceInvocationChannel {
        let deviceId: String
        let onRequest: @MainActor @Sendable (VoiceInvocationRequest) -> Void
        let onFailure: @MainActor @Sendable (VoiceInvocationFailure) -> Void
        var started = false
        var stopped = false
        var startError: Error?

        init(deviceId: String,
             onRequest: @escaping @MainActor @Sendable (VoiceInvocationRequest) -> Void,
             onFailure: @escaping @MainActor @Sendable (VoiceInvocationFailure) -> Void) {
            self.deviceId = deviceId
            self.onRequest = onRequest
            self.onFailure = onFailure
        }

        func start() throws {
            if let startError { throw startError }
            started = true
        }

        func stop() { stopped = true }
    }

    @MainActor
    private final class FakeSource: VoiceInvocationSource {
        var opened: [FakeChannel] = []
        var failStartFor: Set<String> = []

        func openChannel(deviceId: String,
                         onRequest: @escaping @MainActor @Sendable (VoiceInvocationRequest) -> Void,
                         onFailure: @escaping @MainActor @Sendable (VoiceInvocationFailure) -> Void) throws
            -> VoiceInvocationChannel {
            let channel = FakeChannel(deviceId: deviceId, onRequest: onRequest, onFailure: onFailure)
            if failStartFor.contains(deviceId) { channel.startError = Opened() }
            opened.append(channel)
            return channel
        }

        func failure(for error: Error) -> VoiceInvocationFailure { .channelError }

        func live(_ id: String) -> FakeChannel? {
            opened.last { $0.deviceId == id && $0.started && !$0.stopped }
        }
    }

    @MainActor
    private final class FakePerformer: VoiceInvocationPerforming {
        var context = VoiceInvocationContext(temple: TempleContext(activity: .standby))
        var listensAfter = true
        var actions: [VoiceInvocationAction] = []
        /// When set, the action waits on it, so a test can let the deadline pass first.
        var hold: CheckedContinuation<Void, Never>?
        var holds = false

        func voiceInvocationContext() -> VoiceInvocationContext { context }

        func performVoiceInvocation(_ action: VoiceInvocationAction) async -> Bool {
            actions.append(action)
            if holds { await withCheckedContinuation { hold = $0 } }
            return listensAfter
        }
    }

    /// The answers a request got. Exactly one is the contract.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(Bool, String?)] = []
        var all: [(Bool, String?)] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ answer: (Bool, String?)) { lock.lock(); list.append(answer); lock.unlock() }
    }

    private var source: FakeSource!
    private var performer: FakePerformer!
    private var ledger: VoiceInvocationLedger!
    private var enabled = true

    override func setUp() async throws {
        source = FakeSource()
        performer = FakePerformer()
        ledger = VoiceInvocationLedger()
        enabled = true
    }

    private func makeService(deadline: Duration = .seconds(2)) -> GlassesVoiceInvocationService {
        let service = GlassesVoiceInvocationService(
            source: source, ledger: ledger, deadline: deadline,
            isEnabled: { [unowned self] in self.enabled },
            arrival: { VoiceInvocationArrival(runState: .background, protectedDataAvailable: false) })
        service.performer = performer
        return service
    }

    /// Sends one request on the device's live channel and waits for its first answer.
    @discardableResult
    private func ask(_ id: String, answers: Answers = Answers(), timeout: TimeInterval = 3) async -> Answers {
        let answered = expectation(description: "answered")
        let request = VoiceInvocationRequest(deviceId: id) { success, output in
            answers.add((success, output))
            answered.fulfill()
            return true
        }
        guard let channel = source.live(id) else { XCTFail("no live channel for \(id)"); return answers }
        channel.onRequest(request)
        await fulfillment(of: [answered], timeout: timeout)
        return answers
    }

    // MARK: - Streams follow the link

    func testOneStreamPerConnectedDeviceStartedAndStoppedWithTheLink() {
        let service = makeService()
        service.update(connectedDeviceIds: ["a", "b"])
        XCTAssertEqual(Set(service.channels.keys), ["a", "b"])
        XCTAssertNotNil(source.live("a"))
        XCTAssertNotNil(source.live("b"))

        // b's link drops.
        service.update(connectedDeviceIds: ["a"])
        XCTAssertEqual(Set(service.channels.keys), ["a"])
        XCTAssertTrue(source.opened.first { $0.deviceId == "b" }!.stopped)
        XCTAssertEqual(ledger.entries["b"]?.last?.event, .streamStopped(.linkDown, secondsSinceLastInvocation: nil))

        // The same device again is not a second stream.
        service.update(connectedDeviceIds: ["a"])
        XCTAssertEqual(source.opened.filter { $0.deviceId == "a" }.count, 1)

        service.shutdown()
        XCTAssertTrue(service.channels.isEmpty)
        XCTAssertEqual(ledger.entries["a"]?.last?.event, .streamStopped(.shutdown, secondsSinceLastInvocation: nil))
    }

    func testTheSwitchOffStopsEveryStreamAndOnStartsThemAgain() {
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        enabled = false
        service.refresh()
        XCTAssertTrue(service.channels.isEmpty)
        XCTAssertEqual(ledger.entries["a"]?.last?.event, .streamStopped(.switchedOff, secondsSinceLastInvocation: nil))
        // Off, a link coming up starts nothing.
        service.update(connectedDeviceIds: ["a", "b"])
        XCTAssertTrue(service.channels.isEmpty)
        enabled = true
        service.refresh()
        XCTAssertEqual(Set(service.channels.keys), ["a", "b"])
    }

    func testAStreamThatFailsToStartIsRecordedAndNotKept() {
        source.failStartFor = ["a"]
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        XCTAssertTrue(service.channels.isEmpty)
        XCTAssertTrue(source.opened.first!.stopped, "a channel that failed to start is stopped")
        XCTAssertEqual(ledger.entries["a"]?.last?.event, .streamStartFailed(.channelError))
    }

    // MARK: - Every request gets exactly one answer

    func testInStandbyItStartsListeningAndAnswersSuccess() async throws {
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(performer.actions, [.startListening])
        XCTAssertEqual(answers.all.count, 1)
        XCTAssertEqual(answers.all.first?.0, true)
        XCTAssertNil(answers.all.first?.1)
        let events = ledger.entries["a"]!.map(\.event)
        XCTAssertEqual(events.first, .streamStarted)
        XCTAssertEqual(events[1], .received(.init(runState: .background, protectedDataAvailable: false)))
        guard case .answered(let outcome, let answer, _, let delivered) = events[2] else {
            return XCTFail("no answer recorded: \(events)")
        }
        XCTAssertEqual(outcome, "startListening")
        XCTAssertEqual(answer, .success)
        XCTAssertTrue(delivered)
    }

    func testWhileSpeakingItInterruptsAndListens() async {
        performer.context.temple.activity = .speaking
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(performer.actions, [.interruptAndListen])
        XCTAssertEqual(answers.all.first?.0, true)
    }

    func testAlreadyListeningIsASuccessThatDoesNothing() async {
        performer.context.temple.activity = .listening
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(performer.actions, [])
        XCTAssertEqual(answers.all.first?.0, true)
    }

    func testAMutedMicIsAFailureWithItsSentence() async {
        performer.context.temple.micMuted = true
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(performer.actions, [])
        XCTAssertEqual(answers.all.first?.0, false)
        XCTAssertEqual(answers.all.first?.1, VoiceInvocationRefusal.micMuted.actionOutput)
    }

    func testACallWithAnotherPersonIsAFailure() async {
        performer.context.otherPartyOnLine = true
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(performer.actions, [])
        XCTAssertEqual(answers.all.first?.1, VoiceInvocationRefusal.otherParty.actionOutput)
    }

    func testAnActionThatLeavesNothingListeningIsAFailure() async {
        performer.listensAfter = false
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(answers.all.first?.0, false)
        XCTAssertEqual(answers.all.first?.1, VoiceInvocationRefusal.didNotStart.actionOutput)
    }

    func testTheDeadlineAnswersFailureOnceAndALateResultIsOnlyRecorded() async throws {
        performer.holds = true
        let service = makeService(deadline: .milliseconds(100))
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        XCTAssertEqual(answers.all.count, 1)
        XCTAssertEqual(answers.all.first?.0, false)
        XCTAssertEqual(answers.all.first?.1, VoiceInvocationRefusal.timedOut.actionOutput)

        // The action finishes after the deadline: no second answer, a late record.
        performer.hold?.resume()
        performer.hold = nil
        func recordedLate() -> Bool {
            ledger.entries["a"]?.contains(where: { entry in
                if case .lateOutcome = entry.event { return true }
                return false
            }) ?? false
        }
        for _ in 0..<50 where !recordedLate() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(answers.all.count, 1, "a request is answered exactly once")
        let late = ledger.entries["a"]!.compactMap { entry -> (String, Bool)? in
            if case .lateOutcome(let outcome, let success, _) = entry.event { return (outcome, success) }
            return nil
        }
        XCTAssertEqual(late.first?.0, "startListening")
        XCTAssertEqual(late.first?.1, true)
    }

    func testAPromptAnswerIsNotFollowedByTheDeadlines() async throws {
        let service = makeService(deadline: .milliseconds(150))
        service.update(connectedDeviceIds: ["a"])
        let answers = await ask("a")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(answers.all.count, 1)
        XCTAssertEqual(answers.all.first?.0, true)
    }

    // MARK: - Errors and the HFP field report

    func testAStreamErrorAndALinkDropAfterARequestAreRecordedWithIt() async {
        let service = makeService()
        service.update(connectedDeviceIds: ["a"])
        await ask("a")
        source.live("a")!.onFailure(.channelNotConnected)
        service.update(connectedDeviceIds: [])
        let events = ledger.entries["a"]!.map(\.event)
        XCTAssertTrue(events.contains(.error(.channelNotConnected, secondsSinceLastInvocation: 0)), "\(events)")
        XCTAssertEqual(events.last, .streamStopped(.linkDown, secondsSinceLastInvocation: 0))
        XCTAssertTrue(ledger.reportLines.contains { $0.hasSuffix("stream stopped (linkDown, 0 s after the last invocation)") })
    }
}
#endif
