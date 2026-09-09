import XCTest
@testable import OpenGlasses

/// W05.5 — the operation journal's durability edge, and the surface a recovery UI would read.
///
/// `OperationJournalTests` covers at-most-once behaviour with a working filesystem. These are the
/// cases that decide whether a consequential tool call may run at all when the filesystem is not
/// working: a full disk, protected data still locked, and a process killed between records.
@MainActor
final class OperationJournalDurabilityTests: XCTestCase {

    // MARK: - Doubles

    /// A storage double whose failures can be aimed. `save` is all-or-nothing by default, matching
    /// the production contract; `tornWriteByteLimit` deliberately breaks that contract so a torn
    /// file can be produced without killing a process.
    private final class FaultyOperationJournalStorage: OperationJournalStorage {
        var stored: Data?
        private(set) var quarantined: Data?
        private(set) var quarantineCount = 0
        var loadError: Error?
        var saveError: Error?
        /// Commit only this many bytes and then fail — the writer production must never be.
        var tornWriteByteLimit: Int?
        private(set) var protectionApplied = false

        struct ProtectedDataUnavailable: Error {}
        struct OutOfSpace: Error {}

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-double-\(UUID().uuidString).json")

        func load() throws -> Data? {
            if let loadError { throw loadError }
            return stored
        }

        func save(_ data: Data) throws {
            if let limit = tornWriteByteLimit {
                stored = data.prefix(limit)
                throw OutOfSpace()
            }
            if let saveError { throw saveError }
            stored = data
            protectionApplied = true
        }

        func quarantineDamaged() throws {
            quarantineCount += 1
            quarantined = stored
            stored = nil
        }
    }

    private func call(_ name: String, invocationID: String,
                      args: [String: Any] = [:]) -> ResolvedToolCall {
        .root(name: name, arguments: ToolArguments(args), origin: .model, invocationID: invocationID)
    }

    private func journal(_ storage: OperationJournalStorage,
                         now: Date = Date()) -> ProtectedOperationJournal {
        ProtectedOperationJournal(storage: storage, now: now)
    }

    /// A journal holding one admitted, still-open operation.
    @discardableResult
    private func admitOne(_ journal: ProtectedOperationJournal, tool: String = "send_it",
                          invocation: String = "call-1", key: String = "key-1",
                          at now: Date = Date()) -> OperationAdmission {
        journal.admit(call: call(tool, invocationID: invocation),
                      semantics: .external(.bestEffort), key: key, at: now)
    }

    // MARK: - Disk full

    func testAFullDiskLeavesThePreviousJournalIntactAndRefusesAdmission() throws {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        guard case .proceed = admitOne(journal) else { return XCTFail("first admission must proceed") }
        let bytesBefore = try XCTUnwrap(storage.stored)

        storage.saveError = FaultyOperationJournalStorage.OutOfSpace()
        let admission = journal.admit(call: call("send_it", invocationID: "call-2"),
                                      semantics: .external(.bestEffort), key: "key-2", at: Date())

        XCTAssertEqual(admission, .storageUnavailable,
                       "an operation whose pre-dispatch record cannot be made durable must not run")
        XCTAssertEqual(storage.stored, bytesBefore,
                       "a refused write must leave the previous journal byte-identical")
        XCTAssertEqual(journal.records.map(\.idempotencyKey), ["key-1"],
                       "the in-memory view must not keep a row that never reached storage")
    }

    func testOnceStorageHasFailedEveryLaterAdmissionIsRefusedToo() {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        storage.saveError = FaultyOperationJournalStorage.OutOfSpace()
        _ = admitOne(journal, invocation: "call-1", key: "key-1")

        storage.saveError = nil
        XCTAssertEqual(admitOne(journal, invocation: "call-2", key: "key-2"), .storageUnavailable,
                       "recovery is explicit: a fresh journal has to load durable state first")
    }

    // MARK: - Protected data locked

    func testALockedStoreIsNeverReadAsAnEmptyHistory() {
        let storage = FaultyOperationJournalStorage()
        storage.stored = Data("[]".utf8)
        storage.loadError = FaultyOperationJournalStorage.ProtectedDataUnavailable()

        let journal = journal(storage)

        XCTAssertFalse(journal.storageAvailable)
        XCTAssertEqual(admitOne(journal), .storageUnavailable)
        XCTAssertEqual(storage.stored, Data("[]".utf8),
                       "a store that could not be read must not be overwritten")
        XCTAssertEqual(storage.quarantineCount, 0,
                       "a locked store is not a damaged one and must not be quarantined")
    }

    func testAJournalRecoversOnceProtectedDataBecomesAvailable() throws {
        let storage = FaultyOperationJournalStorage()
        let first = journal(storage)
        guard case .proceed = admitOne(first) else { return XCTFail("first admission must proceed") }

        storage.loadError = FaultyOperationJournalStorage.ProtectedDataUnavailable()
        XCTAssertFalse(journal(storage).storageAvailable)

        storage.loadError = nil
        let recovered = journal(storage)
        XCTAssertTrue(recovered.storageAvailable)
        XCTAssertEqual(recovered.records.map(\.idempotencyKey), ["key-1"])
        XCTAssertEqual(recovered.unresolvedOperations.count, 1)
    }

    // MARK: - Killed mid-write

    func testACrashMidWriteKeepsTheCompleteRecordsAndQuarantinesTheTail() throws {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        admitOne(journal, invocation: "call-1", key: "key-1")
        journal.resolve(operationID: "call-1", outcome: .completed("done"), at: Date())
        admitOne(journal, invocation: "call-2", key: "key-2")
        let whole = try XCTUnwrap(storage.stored)

        // Cut the file between records, which is what a kill during a non-atomic write leaves:
        // a whole first record, then a fragment of the second.
        let boundary = try XCTUnwrap(whole.range(of: Data("},{".utf8)))
        storage.stored = Data(whole[whole.startIndex..<(boundary.lowerBound + 6)])

        let restarted = self.journal(storage)

        XCTAssertTrue(restarted.storageAvailable,
                      "the records that landed are recoverable; refusing everything loses them")
        XCTAssertTrue(restarted.quarantinedDamagedTail)
        XCTAssertEqual(restarted.records.count, 1, "only the complete record survives")
        XCTAssertEqual(storage.quarantineCount, 1)
        XCTAssertNotNil(storage.quarantined, "the damaged bytes are kept, not overwritten")
    }

    func testAFileWithNothingWholeInItIsPreservedRatherThanSalvaged() {
        let storage = FaultyOperationJournalStorage()
        storage.stored = Data("not valid operation json".utf8)

        let journal = journal(storage)

        XCTAssertFalse(journal.storageAvailable)
        XCTAssertEqual(admitOne(journal), .storageUnavailable)
        XCTAssertEqual(storage.stored, Data("not valid operation json".utf8))
        XCTAssertEqual(storage.quarantineCount, 0)
    }

    func testSalvageRecognisesACompleteFileAndDeclinesToTouchIt() {
        let complete = Data(#"[{"a":1},{"b":"}"}]"#.utf8)
        XCTAssertNil(OperationJournalSalvage.completeRecordPrefix(of: complete),
                     "a file that closes properly is not a truncated one")
    }

    func testSalvageIsNotFooledByABraceInsideAString() throws {
        let torn = Data(#"[{"a":"},{"},{"b":"#.utf8)
        let prefix = try XCTUnwrap(OperationJournalSalvage.completeRecordPrefix(of: torn))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: prefix) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["a"] as? String, "},{")
    }

    func testATornWriteLeavesTheJournalRefusingUntilItIsReloaded() throws {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        admitOne(journal, invocation: "call-1", key: "key-1")

        storage.tornWriteByteLimit = 20
        XCTAssertEqual(admitOne(journal, invocation: "call-2", key: "key-2"), .storageUnavailable)
        XCTAssertEqual(journal.records.map(\.idempotencyKey), ["key-1"],
                       "a row whose write tore must not be presented as journaled")
    }

    // MARK: - Unknown-outcome reconciliation

    func testUnresolvedOperationsAreExposedForARecoverySurface() {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        admitOne(journal, invocation: "call-1", key: "key-1")
        admitOne(journal, tool: "send_it", invocation: "call-2", key: "key-2")
        journal.resolve(operationID: "call-2", outcome: .completed("done"), at: Date())

        XCTAssertEqual(journal.unresolvedOperations.map(\.operationID), ["call-1"])
        XCTAssertEqual(journal.unresolvedOperations.first?.toolName, "send_it")
    }

    func testAnInterruptedOperationIsUnresolvedAndReconcilableAfterARestart() throws {
        let storage = FaultyOperationJournalStorage()
        admitOne(journal(storage), invocation: "call-1", key: "key-1")

        let restarted = journal(storage)
        let unresolved = try XCTUnwrap(restarted.unresolvedOperations.first)
        XCTAssertEqual(unresolved.state, .unknown)
        XCTAssertTrue(unresolved.recoveredFromRestart)

        // The answer arrives later — from a tool that grew a status endpoint, or from a person who
        // checked. The row settles; the conversation is long over, so it settles as `late`.
        let resolution = restarted.reconcile(operationID: "call-1",
                                             outcome: .completed("it did land"), at: Date())
        guard case .late(let record) = resolution else {
            return XCTFail("a reconciled unknown must settle late, got \(resolution)")
        }
        XCTAssertEqual(record.state, .completed)
        XCTAssertTrue(restarted.unresolvedOperations.isEmpty)
    }

    func testReconcilingAnAlreadySettledOperationIsRefused() {
        let storage = FaultyOperationJournalStorage()
        let journal = journal(storage)
        admitOne(journal, invocation: "call-1", key: "key-1")
        journal.resolve(operationID: "call-1", outcome: .completed("done"), at: Date())

        XCTAssertEqual(journal.reconcile(operationID: "call-1", outcome: .failedBeforeExecution(reason: "no"),
                                         at: Date()),
                       .unknownOperation,
                       "a settled operation is not re-decided by someone looking at it later")
    }

    func testReconcilingSomethingThatWasNeverJournaledIsRefused() {
        let journal = journal(FaultyOperationJournalStorage())
        XCTAssertEqual(journal.reconcile(operationID: "never-existed",
                                         outcome: .completed("x"), at: Date()),
                       .unknownOperation)
    }
}
