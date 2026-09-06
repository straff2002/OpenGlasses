import XCTest
@testable import OpenGlasses

/// Plan DJ P3 — an action that cannot safely be repeated happens at most once, and what became of
/// it is written down.
///
/// Two properties are pinned here. The first is at-most-once: a second delivery of the same call is
/// answered from the journal instead of being run again, and that holds across a process restart,
/// which is the case an in-memory guard cannot cover. The second is that the record ends up true —
/// including when the truth arrives after the router stopped waiting, and including when the app was
/// killed mid-operation, where the record says "unknown" rather than guessing "no".
@MainActor
final class OperationJournalTests: XCTestCase {

    // MARK: - Fixtures

    /// A one-shot signal with no polling and no sleeping.
    private final class AsyncSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            lock.lock()
            let pending = waiters
            waiters = []
            fired = true
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if fired {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Parks until released, then either returns or throws.
    private struct ParkedTool: NativeTool {
        let name: String
        let description = "parked test fixture"
        let executionSemantics: ToolExecutionSemantics
        let release: AsyncSignal
        var failsAfterRelease = false
        var parametersSchema: [String: Any] { ["type": "object"] }

        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "the late failure" }
        }

        func execute(args: [String: Any]) async throws -> String {
            await release.wait()
            if failsAfterRelease { throw Failure() }
            return "finished"
        }
    }

    /// Counts executions and reports the idempotency key it ran under.
    private final class CountingTool: NativeTool, @unchecked Sendable {
        let name: String
        let description = "counting test fixture"
        let executionSemantics: ToolExecutionSemantics
        private(set) var runs = 0
        private(set) var keysSeen: [String?] = []
        var parametersSchema: [String: Any] { ["type": "object"] }

        init(name: String, semantics: ToolExecutionSemantics) {
            self.name = name
            self.executionSemantics = semantics
        }

        func execute(args: [String: Any]) async throws -> String {
            runs += 1
            keysSeen.append(OperationScope.idempotencyKey)
            return "ran \(runs)"
        }
    }

    /// Parks like `ParkedTool`, and counts how many executions are inside it at once.
    private final class ConcurrencyProbeTool: NativeTool, @unchecked Sendable {
        let name: String
        let description = "concurrency probe fixture"
        let executionSemantics: ToolExecutionSemantics
        let release: AsyncSignal
        private(set) var entries = 0
        private(set) var maxActive = 0
        private var active = 0
        var parametersSchema: [String: Any] { ["type": "object"] }

        init(name: String, semantics: ToolExecutionSemantics, release: AsyncSignal) {
            self.name = name
            self.executionSemantics = semantics
            self.release = release
        }

        func execute(args: [String: Any]) async throws -> String {
            entries += 1
            active += 1
            maxActive = max(maxActive, active)
            await release.wait()
            active -= 1
            return "finished"
        }
    }

    /// A tool that can be asked afterwards what actually happened.
    private struct ReconcilingTool: NativeTool, OperationReconciling {
        let name: String
        let description = "reconcilable test fixture"
        var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) }
        var parametersSchema: [String: Any] { ["type": "object"] }
        let answer: ToolExecutionOutcome?

        func execute(args: [String: Any]) async throws -> String { "ran" }

        func reconcile(operationID: String, idempotencyKey: String) async -> ToolExecutionOutcome? {
            answer
        }
    }

    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("operation-journal-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func router(with tool: any NativeTool, journalDirectory: URL,
                        timeout: TimeInterval = 0.05) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        router.toolTimeoutSeconds = timeout
        router.operationJournal = ProtectedOperationJournal(directory: journalDirectory)
        return router
    }

    private func call(_ name: String, invocationID: String,
                      args: [String: Any] = [:]) -> ResolvedToolCall {
        .root(name: name, arguments: ToolArguments(args), origin: .model, invocationID: invocationID)
    }

    // MARK: - Timer wins, the answer arrives later

    /// The caller is told the outcome is unknown and the turn moves on. When the work finally
    /// succeeds, the record — not the conversation — is what gets updated.
    func testLateSuccessSettlesTheRecordWithoutASecondSuccess() async {
        let release = AsyncSignal()
        let tool = ParkedTool(name: "send_it", executionSemantics: .external(.notCancellable),
                              release: release)
        let router = router(with: tool, journalDirectory: temporaryDirectory())

        var lateRecords: [OperationRecord] = []
        let settled = AsyncSignal()
        router.onOperationStatusChange = { record in
            guard record.resolvedLate else { return }
            lateRecords.append(record)
            settled.fire()
        }

        let outcome = await router.executeRoot(name: "send_it", args: [:])
        guard case .outcomeUnknown(let operationID, _) = outcome else {
            return XCTFail("the timer winning on a send must leave the outcome unknown: \(outcome)")
        }
        XCTAssertEqual(router.operationJournal.records.first?.state, .unknown)

        release.fire()
        await settled.wait()

        XCTAssertEqual(lateRecords.count, 1, "the late answer is one status update, not a retelling")
        let record = try? XCTUnwrap(router.operationJournal.records.first)
        XCTAssertEqual(record?.operationID, operationID)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertTrue(record?.resolvedLate == true)
        // What the caller was told is unchanged: nothing rewrites an answer already given.
        XCTAssertEqual(outcome.retryDisposition, .unsafeToRetry)
    }

    /// The same shape when the late answer is a failure: authoritative, and recorded as such.
    func testLateFailureSettlesTheRecordAsFailed() async {
        let release = AsyncSignal()
        let tool = ParkedTool(name: "send_it", executionSemantics: .external(.notCancellable),
                              release: release, failsAfterRelease: true)
        let router = router(with: tool, journalDirectory: temporaryDirectory())

        let settled = AsyncSignal()
        router.onOperationStatusChange = { record in
            if record.resolvedLate { settled.fire() }
        }

        let outcome = await router.executeRoot(name: "send_it", args: [:])
        guard case .outcomeUnknown = outcome else { return XCTFail("expected unknown: \(outcome)") }

        release.fire()
        await settled.wait()

        XCTAssertEqual(router.operationJournal.records.first?.state, .failed)
        XCTAssertTrue(router.operationJournal.records.first?.resolvedLate == true)
    }

    // MARK: - At most once

    func testASecondDeliveryOfTheSameCallIsAnsweredFromTheRecord() async {
        let tool = CountingTool(name: "send_it", semantics: .external(.cooperative))
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        let first = await router.executeRoot(name: "send_it", args: ["to": "mum"],
                                             invocationID: "call-1")
        let second = await router.executeRoot(name: "send_it", args: ["to": "mum"],
                                             invocationID: "call-1")

        XCTAssertEqual(tool.runs, 1, "a redelivery must not send the message a second time")
        XCTAssertEqual(first, .completed("ran 1"))
        XCTAssertEqual(second, .completed("ran 1"), "the recorded result answers the redelivery")
        XCTAssertEqual(router.operationJournal.records.count, 1)
    }

    /// The property the in-turn guard cannot provide: the record outlives the process.
    func testADuplicateInvocationIdExecutesAtMostOnceAcrossARestart() async {
        let directory = temporaryDirectory()
        let firstTool = CountingTool(name: "send_it", semantics: .external(.cooperative))
        let firstRouter = router(with: firstTool, journalDirectory: directory, timeout: 30)
        _ = await firstRouter.executeRoot(name: "send_it", args: ["to": "mum"],
                                          invocationID: "call-1")
        XCTAssertEqual(firstTool.runs, 1)

        // A new process: new router, new journal, same store.
        let secondTool = CountingTool(name: "send_it", semantics: .external(.cooperative))
        let secondRouter = router(with: secondTool, journalDirectory: directory, timeout: 30)
        let replay = await secondRouter.executeRoot(name: "send_it", args: ["to": "mum"],
                                                    invocationID: "call-1")

        XCTAssertEqual(secondTool.runs, 0, "the same call must not run again after a restart")
        guard case .completed(let text) = replay else {
            return XCTFail("a completed operation replays as completed: \(replay)")
        }
        // The result itself was never persisted, so the replay says so rather than inventing one.
        XCTAssertTrue(text.contains("already"), text)
        XCTAssertFalse(text.contains("ran 1"))
    }

    func testADifferentCallToTheSameToolStillRuns() async {
        let tool = CountingTool(name: "send_it", semantics: .external(.cooperative))
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        _ = await router.executeRoot(name: "send_it", args: ["to": "mum"], invocationID: "call-1")
        _ = await router.executeRoot(name: "send_it", args: ["to": "dad"], invocationID: "call-2")
        // Same arguments, different delivery: a person asking twice is not a redelivery.
        _ = await router.executeRoot(name: "send_it", args: ["to": "mum"], invocationID: "call-3")

        XCTAssertEqual(tool.runs, 3)
    }

    /// Repeating a converging action costs nothing, so it is not journaled and never blocked.
    func testAnIntrinsicallyRepeatableToolIsNeitherJournaledNorDeDuplicated() async {
        let tool = CountingTool(name: "torch", semantics: .actuation(idempotency: .intrinsic))
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        _ = await router.executeRoot(name: "torch", args: ["on": true], invocationID: "call-1")
        _ = await router.executeRoot(name: "torch", args: ["on": true], invocationID: "call-1")

        XCTAssertEqual(tool.runs, 2)
        XCTAssertTrue(router.operationJournal.records.isEmpty,
                      "the journal is for operations that must not repeat, and nothing else")
    }

    // MARK: - Keys reach the adapters

    func testTheSameDeliveryResolvesToTheSameIdempotencyKey() async {
        let tool = CountingTool(name: "torch", semantics: .actuation(idempotency: .intrinsic))
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        _ = await router.executeRoot(name: "torch", args: ["on": true], invocationID: "call-1")
        _ = await router.executeRoot(name: "torch", args: ["on": true], invocationID: "call-1")
        _ = await router.executeRoot(name: "torch", args: ["on": true], invocationID: "call-2")

        XCTAssertEqual(tool.keysSeen.count, 3)
        XCTAssertNotNil(tool.keysSeen[0])
        XCTAssertEqual(tool.keysSeen[0], tool.keysSeen[1], "a redelivery carries the same key")
        XCTAssertNotEqual(tool.keysSeen[0], tool.keysSeen[2], "a different delivery does not")
    }

    func testKeyDerivationIsStableAndPathSensitive() {
        let root = call("send_it", invocationID: "call-1", args: ["to": "mum"])
        XCTAssertEqual(OperationIdempotencyKey.derive(root), OperationIdempotencyKey.derive(root))

        let sameRootDifferentArgs = call("send_it", invocationID: "call-1", args: ["to": "dad"])
        XCTAssertNotEqual(OperationIdempotencyKey.derive(root),
                          OperationIdempotencyKey.derive(sameRootDifferentArgs))

        // A child of the same root is a different operation from the root itself.
        let child = root.child(name: "smart_home", arguments: ToolArguments(["action": "unlock"]),
                               composerID: "pack-1")
        XCTAssertNotEqual(OperationIdempotencyKey.derive(root),
                          OperationIdempotencyKey.derive(child))
        // …and the same child of the same root is the same operation.
        let sameChild = root.child(name: "smart_home",
                                   arguments: ToolArguments(["action": "unlock"]),
                                   composerID: "pack-1")
        XCTAssertEqual(OperationIdempotencyKey.derive(child),
                       OperationIdempotencyKey.derive(sameChild))
    }

    /// The one adapter with somewhere to put a key puts it there; the digest carries no argument
    /// content off the device.
    func testMCPCallPayloadCarriesTheIdempotencyKey() throws {
        let payload = MCPClient.callPayload(toolName: "create_issue",
                                            arguments: ["title": "secret title"],
                                            idempotencyKey: "abc123")
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        let meta = try XCTUnwrap(params["_meta"] as? [String: String])
        XCTAssertEqual(meta[MCPClient.idempotencyMetaKey], "abc123")

        let unkeyed = MCPClient.callPayload(toolName: "create_issue", arguments: [:],
                                            idempotencyKey: nil)
        let unkeyedParams = try XCTUnwrap(unkeyed["params"] as? [String: Any])
        XCTAssertNil(unkeyedParams["_meta"], "no key, no field — the request shape is unchanged")
    }

    // MARK: - Recovery after the process dies

    func testAnInterruptedOperationComesBackAsUnknownNotFailed() {
        let directory = temporaryDirectory()
        let journal = ProtectedOperationJournal(directory: directory)
        let started = journal.admit(call: call("send_it", invocationID: "call-1"),
                                    semantics: .external(.bestEffort),
                                    key: "key-1", at: Date())
        guard case .proceed(let record) = started else { return XCTFail("expected admission") }
        XCTAssertEqual(record.state, .started)

        // The process dies here. A new one opens the same store.
        let recoveredJournal = ProtectedOperationJournal(directory: directory)
        let recovered = recoveredJournal.records.first
        XCTAssertEqual(recovered?.state, .unknown,
                       "a killed process cannot know the send didn't go out")
        XCTAssertTrue(recovered?.recoveredFromRestart == true)
        XCTAssertEqual(recoveredJournal.recoveredOperations.count, 1)
    }

    func testCorruptJournalIsPreservedAndRefusesAdmission() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("operations.json")
        let corrupt = Data("not valid operation json".utf8)
        try corrupt.write(to: store)

        let journal = ProtectedOperationJournal(directory: directory)

        XCTAssertFalse(journal.storageAvailable)
        XCTAssertEqual(journal.admit(call: call("send_it", invocationID: "call-1"),
                                     semantics: .external(.bestEffort), key: "key-1", at: Date()),
                       .storageUnavailable)
        XCTAssertEqual(try Data(contentsOf: store), corrupt,
                       "unreadable evidence must not be overwritten as an empty journal")
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testJournalWriteFailureBlocksConsequentialDispatch() async throws {
        // A regular file cannot contain operations.json, so initialization and admission cannot
        // make a durable record. The router must fail before the tool's external effect starts.
        let blockedDirectory = temporaryDirectory()
        try Data("blocks directory creation".utf8).write(to: blockedDirectory)
        let tool = CountingTool(name: "send_it", semantics: .external(.bestEffort))
        let router = router(with: tool, journalDirectory: blockedDirectory, timeout: 30)

        let outcome = await router.executeRoot(name: "send_it", args: ["to": "mum"],
                                               invocationID: "call-1")

        guard case .failedBeforeExecution(let reason) = outcome else {
            return XCTFail("storage failure must refuse dispatch: \(outcome)")
        }
        XCTAssertTrue(reason.contains("not run"), reason)
        XCTAssertEqual(tool.runs, 0)
        XCTAssertTrue(router.operationJournal.records.isEmpty)
        XCTAssertEqual(outcome.retryDisposition, .safeToRetry)
    }

    func testRecoveredOperationsAreReconciledWhereAToolCanAnswer() async {
        let directory = temporaryDirectory()
        let journal = ProtectedOperationJournal(directory: directory)
        _ = journal.admit(call: call("send_it", invocationID: "call-1"),
                          semantics: .external(.bestEffort), key: "key-1", at: Date())

        let router = router(with: ReconcilingTool(name: "send_it", answer: .completed("it landed")),
                            journalDirectory: directory)
        XCTAssertEqual(router.operationJournal.recoveredOperations.count, 1)

        let settled = await router.reconcileRecoveredOperations()
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(router.operationJournal.records.first?.state, .completed)
    }

    func testAnOperationNothingCanAnswerForStaysUnknown() async {
        let directory = temporaryDirectory()
        let journal = ProtectedOperationJournal(directory: directory)
        _ = journal.admit(call: call("send_it", invocationID: "call-1"),
                          semantics: .external(.bestEffort), key: "key-1", at: Date())

        // The tool exists but cannot tell — and a tool with no status API at all is the same case.
        let router = router(with: ReconcilingTool(name: "send_it", answer: nil),
                            journalDirectory: directory)
        let settled = await router.reconcileRecoveredOperations()

        XCTAssertEqual(settled, 0)
        XCTAssertEqual(router.operationJournal.records.first?.state, .unknown,
                       "unknown is the honest state; failed would be a guess")
    }

    // MARK: - Retry advice

    func testANonIdempotentUnresolvedOperationIsNeverRetriedAutomatically() {
        func record(_ tool: String, _ state: OperationState) -> OperationRecord {
            OperationRecord(
                operationID: "op-1", idempotencyKey: "key-1", toolName: tool,
                effect: .externalMutation, origin: .model, depth: 0, rootFingerprint: "root",
                parentFingerprint: nil, composerFingerprint: nil, startedAt: Date(),
                updatedAt: Date(), state: state)
        }

        let advice = OperationRetryPolicy.advice(for: record("send_message", .unknown),
                                                 semantics: .external(.bestEffort))
        guard case .reconcileFirst(let message) = advice else {
            return XCTFail("a message that may already have been sent is not retryable: \(advice)")
        }
        XCTAssertFalse(advice.allowsAutomaticRetry)
        XCTAssertTrue(message.lowercased().contains("check"), message)

        // A converging action is a different matter.
        XCTAssertEqual(
            OperationRetryPolicy.advice(for: record("flashlight", .unknown),
                                        semantics: .actuation(idempotency: .intrinsic)),
            .safeToRetry)

        // An authoritative failure left nothing behind.
        XCTAssertEqual(
            OperationRetryPolicy.advice(for: record("send_message", .failed),
                                        semantics: .external(.bestEffort)),
            .safeToRetry)

        // A success needs no retry at all.
        XCTAssertFalse(
            OperationRetryPolicy.advice(for: record("send_message", .completed),
                                        semantics: .external(.bestEffort)).allowsAutomaticRetry)
    }

    // MARK: - Cancellation before dispatch

    func testACallCancelledBeforeDispatchNeverReachesTheToolOrTheJournal() async {
        let tool = CountingTool(name: "send_it", semantics: .external(.cooperative))
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        let task = Task { @MainActor in
            await router.executeRoot(name: "send_it", args: [:], invocationID: "call-1")
        }
        task.cancel()
        let outcome = await task.value

        guard case .failedBeforeExecution(let reason) = outcome else {
            return XCTFail("a call stopped before dispatch did not happen: \(outcome)")
        }
        XCTAssertTrue(reason.contains("no effect"), reason)
        XCTAssertEqual(outcome.retryDisposition, .safeToRetry)
        XCTAssertEqual(tool.runs, 0)
        XCTAssertTrue(router.operationJournal.records.isEmpty,
                      "nothing that never ran belongs in the operation journal")
    }

    // MARK: - Retention

    func testRetentionKeepsAShortWindowAndDropsSettledRowsFirst() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let journal = ProtectedOperationJournal(
            directory: temporaryDirectory(),
            retention: OperationJournalRetention(maxRecords: 3, settledMaxAge: 60,
                                                 unresolvedMaxAge: 600))

        func operation(_ index: Int, at when: Date, settle: Bool) {
            let identifier = "op-\(index)"
            _ = journal.admit(call: call("send_it", invocationID: identifier),
                              semantics: .external(.bestEffort), key: "key-\(index)", at: when)
            if settle {
                journal.resolve(operationID: identifier, outcome: .completed("ok"), at: when)
            } else {
                journal.resolve(operationID: identifier,
                                outcome: .outcomeUnknown(operationID: identifier, message: "?"),
                                at: when)
            }
        }

        operation(1, at: start, settle: false)              // unresolved, oldest
        operation(2, at: start.addingTimeInterval(1), settle: true)
        operation(3, at: start.addingTimeInterval(2), settle: true)
        operation(4, at: start.addingTimeInterval(3), settle: true)
        XCTAssertEqual(journal.records.count, 3)
        XCTAssertTrue(journal.records.contains { $0.operationID == "op-1" },
                      "the unresolved row is the one worth keeping")
        XCTAssertFalse(journal.records.contains { $0.operationID == "op-2" })

        // Age: a settled row falls out of the window, the unresolved one does not.
        operation(5, at: start.addingTimeInterval(120), settle: true)
        XCTAssertEqual(journal.records.map(\.operationID).sorted(), ["op-1", "op-5"])

        // …until it too is past its own, longer window.
        operation(6, at: start.addingTimeInterval(1_000), settle: true)
        XCTAssertEqual(journal.records.map(\.operationID), ["op-6"])
    }

    // MARK: - Protection and content-freedom

    func testTheStoreIsProtectedAtRest() throws {
        let directory = temporaryDirectory()
        let journal = ProtectedOperationJournal(directory: directory)
        _ = journal.admit(call: call("send_it", invocationID: "call-1"),
                          semantics: .external(.bestEffort), key: "key-1", at: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.storeURL.path))
        XCTAssertEqual(ProtectedOperationJournal.fileProtection,
                       .completeUntilFirstUserAuthentication)
        XCTAssertTrue(journal.protectionApplied,
                      "the write must have set the protection attribute, not merely intended to")

        // The simulator's filesystem accepts the attribute and then reports none back, so the
        // read-back is asserted only where the platform implements data protection.
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.storeURL.path)
        if let applied = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(applied, ProtectedOperationJournal.fileProtection)
        }
    }

    func testTheJournalNeverWritesArgumentsOrResults() throws {
        let directory = temporaryDirectory()
        let journal = ProtectedOperationJournal(directory: directory)
        let sensitive = call("send_message", invocationID: "call-1",
                             args: ["to": "+64211234567", "body": "meet me at the safehouse"])
        _ = journal.admit(call: sensitive, semantics: .external(.bestEffort),
                          key: OperationIdempotencyKey.derive(sensitive), at: Date())
        journal.resolve(operationID: "call-1", outcome: .completed("Sent to +64211234567"),
                        at: Date())

        let contents = try String(contentsOf: journal.storeURL, encoding: .utf8)
        for secret in ["+64211234567", "safehouse", "Sent to"] {
            XCTAssertFalse(contents.contains(secret), "the journal wrote \(secret) to disk")
        }
        XCTAssertTrue(contents.contains("send_message"),
                      "the tool name is the one readable field, and it is app-defined")
    }

    // MARK: - Serialization by resource

    /// Two different operations on the same resource do not interleave. Without the queue both
    /// would be parked inside the tool at once, which is what the probe counts.
    func testOperationsOnOneResourceRunOneAtATime() async {
        let release = AsyncSignal()
        let tool = ConcurrencyProbeTool(name: "send_it",
                                        semantics: .external(.notCancellable), release: release)
        let router = router(with: tool, journalDirectory: temporaryDirectory(), timeout: 30)

        async let first = router.executeRoot(name: "send_it", args: ["to": "mum"],
                                             invocationID: "call-1")
        await Task.yield()
        async let second = router.executeRoot(name: "send_it", args: ["to": "dad"],
                                              invocationID: "call-2")
        await Task.yield()
        release.fire()

        let outcomes = await (first, second)
        XCTAssertEqual(outcomes.0, .completed("finished"))
        XCTAssertEqual(outcomes.1, .completed("finished"))
        XCTAssertEqual(tool.entries, 2, "both operations must actually have run")
        XCTAssertEqual(tool.maxActive, 1, "one operation at a time on one resource")
        XCTAssertEqual(router.operationJournal.records.count, 2)
        XCTAssertTrue(router.operationJournal.records.allSatisfy { $0.state == .completed })
    }
}
