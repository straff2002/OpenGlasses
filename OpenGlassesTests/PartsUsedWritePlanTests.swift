import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan MM P0 — a confirmed batch becomes only part lines or only adjustments, never both for a
/// line, never a count, set, sale, price, new item or status; delivered once.
final class PartsUsedWritePlanTests: XCTestCase {

    private typealias S = StockSystemSamples

    private let snapshot = S.snapshot([
        S.row("A", [("L1", "3")]),
        S.row("B", description: "Coolant", unit: "litre", [("L1", "4")]),
    ])

    private func capabilities(hasJobs: Bool, wholeNumbersOnly: Bool = false,
                              reasons: Set<StockAdjustmentReason> = [.internalUse, .waste],
                              chosen: StockAdjustmentReason? = .internalUse,
                              note: Bool = true) -> StockSystemCapabilities {
        StockSystemCapabilities(connectorID: "sample-system", displayName: "Sample System", hasJobs: hasJobs,
                                wholeNumbersOnly: wholeNumbersOnly, adjustmentReasons: reasons,
                                chosenReason: chosen, adjustmentNote: note)
    }

    private func reference(system: String = "sample-system") -> ExternalJobReference {
        ExternalJobReference(system: system, systemName: "Sample System", jobID: "WO-9", jobNumber: "J-9",
                             appointmentID: nil, locationID: nil, customerID: nil, technicianID: nil, equipmentIDs: nil)
    }

    private func batch(_ lines: [StagedStockUse]? = nil) -> ConfirmedStockUseBatch {
        ConfirmedStockUseBatch(
            jobID: "JOB-1", jobNumber: "J-9", locationID: "L1",
            lines: lines ?? [
                StagedStockUse(id: "S1", itemID: "A", part: "ZX-A", description: "Capacitor 45/5",
                               quantity: .whole(1), unit: .each, source: .spoken),
                StagedStockUse(id: "S2", itemID: "B", part: "ZX-B", description: "Coolant",
                               quantity: StockQuantity(scaled: 500), unit: .l, source: .typed),
            ],
            confirmation: .person(.voice))
    }

    func testAJobWithAReferenceGivesJobLinesOnly() {
        let plan = PartsUsedWritePlan(batch: batch(), reference: reference(), capabilities: capabilities(hasJobs: true),
                                      snapshot: snapshot)
        XCTAssertEqual(plan.steps.map(\.kind), [.jobPartLine, .jobPartLine])
        guard case .jobPartLine(let line) = plan.steps[1] else { return XCTFail() }
        XCTAssertEqual(line.externalJobID, "WO-9")
        XCTAssertEqual(line.itemID, "B")
        XCTAssertEqual(line.quantity, "0.5")
        XCTAssertEqual(line.unit, .l)
    }

    func testNoReferenceOrNoJobsGivesAdjustmentsOnly() {
        let cases: [(StockSystemCapabilities, ExternalJobReference?)] = [
            (capabilities(hasJobs: true), nil),                                    // a job with no reference there
            (capabilities(hasJobs: true), reference(system: "another-system")),    // another system's reference
            (capabilities(hasJobs: false), reference()),                           // a system without jobs
        ]
        for (capabilities, reference) in cases {
            let plan = PartsUsedWritePlan(batch: batch(), reference: reference, capabilities: capabilities, snapshot: snapshot)
            XCTAssertEqual(plan.steps.map(\.kind), [.adjustment, .adjustment])
            guard case .adjustment(let adjustment) = plan.steps[0] else { return XCTFail() }
            XCTAssertEqual(adjustment.reason, .internalUse)
            XCTAssertEqual(adjustment.locationID, "L1")
            XCTAssertEqual(adjustment.note, "J-9")
            XCTAssertEqual(adjustment.quantity, "1")
        }
        let noNote = PartsUsedWritePlan(batch: batch(), reference: nil, capabilities: capabilities(hasJobs: false, note: false),
                                        snapshot: snapshot)
        guard case .adjustment(let adjustment) = noNote.steps[0] else { return XCTFail() }
        XCTAssertNil(adjustment.note)
    }

    /// One entry per staged line, so no line is ever a part line and an adjustment.
    func testNeverBothForOneLine() {
        for hasJobs in [true, false] {
            for reference in [nil, reference()] {
                let plan = PartsUsedWritePlan(batch: batch(), reference: reference,
                                              capabilities: capabilities(hasJobs: hasJobs), snapshot: snapshot)
                XCTAssertEqual(plan.entries.map(\.stagedLineID), ["S1", "S2"])
                XCTAssertEqual(Set(plan.steps.map(\.kind)).count, 1, "one route per batch")
            }
        }
        // A line staged twice is planned once.
        let twice = batch([batch().lines[0], batch().lines[0]])
        XCTAssertEqual(PartsUsedWritePlan(batch: twice, reference: nil, capabilities: capabilities(hasJobs: false),
                                          snapshot: snapshot).entries.count, 1)
    }

    /// The closed list of writes: a part line and an adjustment, and nothing for a count, a set
    /// level, a sale, a price, a new catalogue item or a job's status. The switch has no default,
    /// so a new step kind fails to compile here until it is argued for.
    func testNeverACountSetSalePriceNewItemOrStatus() throws {
        XCTAssertEqual(PartsUsedWritePlan.Kind.allCases.map(\.rawValue), ["job_part_line", "adjustment"])
        XCTAssertEqual(StockAdjustmentReason.allCases.map(\.rawValue), ["internal_use", "waste", "damage"])
        let plan = PartsUsedWritePlan(batch: batch(), reference: reference(), capabilities: capabilities(hasJobs: true),
                                      snapshot: snapshot)
        for step in plan.steps {
            switch step {
            case .jobPartLine, .adjustment: break
            }
        }
        // Neither the plan nor its writes carry anything a count, a price or a status could ride in.
        let object = try S.object(S.encodeSorted(plan))
        let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? ""
        for word in ["count", "price", "status", "sale", "level", "onHand"] {
            XCTAssertFalse(text.lowercased().contains(word.lowercased()), "the plan says \(word): \(text)")
        }
        // A stored plan holding any other kind is refused, not read.
        var stored = try XCTUnwrap(object.mutableCopy() as? NSMutableDictionary)
        stored["entries"] = [["kind": "physical_count", "stagedLineID": "S1"]]
        XCTAssertThrowsError(try JSONDecoder().decode(PartsUsedWritePlan.self,
                                                      from: JSONSerialization.data(withJSONObject: stored)))
        stored = try XCTUnwrap(object.mutableCopy() as? NSMutableDictionary)
        XCTAssertEqual(try JSONDecoder().decode(PartsUsedWritePlan.self, from: JSONSerialization.data(withJSONObject: stored)), plan)
    }

    func testAnUncarriedPartIsNamedAndNotSent() {
        let lines = batch().lines + [
            StagedStockUse(id: "S3", itemID: nil, part: "ZX-404", description: "Relay", quantity: .whole(1), unit: .each,
                           source: .spoken),
            StagedStockUse(id: "S4", itemID: "GONE", part: "ZX-405", description: "Fuse", quantity: .whole(1), unit: .each,
                           source: .scanned),
        ]
        let plan = PartsUsedWritePlan(batch: batch(lines), reference: reference(), capabilities: capabilities(hasJobs: true),
                                      snapshot: snapshot)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.notSent.map(\.stagedLineID), ["S3", "S4"])
        XCTAssertEqual(plan.notSent.map(\.reason), [.notCarried, .notCarried])
        XCTAssertEqual(plan.notSent[0].sentence, "Relay (ZX-404): not in Sample System's catalogue, so not sent.")
    }

    func testAQuantityTheSystemCannotTakeAndAMissingReasonAreNotSent() {
        let whole = PartsUsedWritePlan(batch: batch(), reference: nil,
                                       capabilities: capabilities(hasJobs: false, wholeNumbersOnly: true), snapshot: snapshot)
        XCTAssertEqual(whole.steps.map(\.stagedLineID), ["S1"])
        XCTAssertEqual(whole.notSent.map(\.reason), [.quantity(.fractional)])

        let wrongUnit = batch([StagedStockUse(id: "S5", itemID: "B", part: "ZX-B", description: "Coolant",
                                              quantity: .whole(1), unit: .m, source: .typed)])
        XCTAssertEqual(PartsUsedWritePlan(batch: wrongUnit, reference: nil, capabilities: capabilities(hasJobs: false),
                                          snapshot: snapshot).notSent.map(\.reason), [.quantity(.unitNotKept)])

        for capabilities in [capabilities(hasJobs: false, chosen: nil), capabilities(hasJobs: false, chosen: .damage)] {
            let plan = PartsUsedWritePlan(batch: batch(), reference: nil, capabilities: capabilities, snapshot: snapshot)
            XCTAssertEqual(plan.steps, [])
            XCTAssertEqual(plan.notSent.map(\.reason), [.noReason, .noReason])
        }
    }

    func testIdempotencyKeysAreStableAcrossARebuild() {
        let first = PartsUsedWritePlan(batch: batch(), reference: reference(), capabilities: capabilities(hasJobs: true),
                                       snapshot: snapshot)
        let again = PartsUsedWritePlan(batch: batch(), reference: reference(), capabilities: capabilities(hasJobs: true),
                                       snapshot: snapshot)
        XCTAssertEqual(first.steps.map(\.idempotencyKey), again.steps.map(\.idempotencyKey))
        XCTAssertEqual(Set(first.steps.map(\.idempotencyKey)).count, 2)

        // SHA-256 hex over job id, staged line id and kind, each followed by a zero byte.
        let expected = SHA256.hash(data: Data("JOB-1\u{0}S1\u{0}job_part_line\u{0}".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first.steps[0].idempotencyKey, expected)
        XCTAssertEqual(expected.count, 64)
        // The kind is part of the key, so the same line as an adjustment is a different write.
        XCTAssertNotEqual(PartsUsedWritePlan.idempotencyKey(jobID: "JOB-1", stagedLineID: "S1", kind: .adjustment), expected)
    }

    /// Read back before retry: after an uncertain send, only what the system does not show is sent
    /// again, and every write lands once.
    /// Plan MM P1: a quantity finer than the item's decimal places is not sent, never rounded, and
    /// the stored plan keeps the reason.
    func testAQuantityFinerThanTheItemKeepsIsNotSent() throws {
        let rows = [S.row("B", description: "Coolant", unit: "litre", [("L1", "4")])]
        var raw = rows[0]
        raw = StockSystemRawRow(itemID: raw.itemID, part: raw.part, description: raw.description, unit: raw.unit,
                                levels: raw.levels, decimalPlaces: 1)
        let snapshot = S.snapshot([S.row("A", [("L1", "3")]), raw])
        let plan = PartsUsedWritePlan(batch: batch(), reference: nil, capabilities: capabilities(hasJobs: false),
                                      snapshot: snapshot)
        XCTAssertEqual(plan.steps.map(\.stagedLineID), ["S1", "S2"], "0.5 litres fits one decimal place")
        let finer = PartsUsedWritePlan(batch: batch([
            StagedStockUse(id: "S2", itemID: "B", part: "ZX-B", description: "Coolant",
                           quantity: StockQuantity(scaled: 250), unit: .l, source: .typed),
        ]), reference: nil, capabilities: capabilities(hasJobs: false), snapshot: snapshot)
        XCTAssertEqual(finer.steps, [])
        XCTAssertEqual(finer.notSent.map(\.reason), [.quantity(.tooManyDecimals)])
        XCTAssertEqual(finer.notSent.first?.reason.code, "too_many_decimals")
        XCTAssertEqual(finer.notSent.first?.sentence,
                       "Coolant (ZX-B): Sample System keeps that item to 1 decimal place, so 0.25 litres can't be sent.")
        XCTAssertEqual(try JSONDecoder().decode(PartsUsedWritePlan.self, from: JSONEncoder().encode(finer)), finer)
    }

    func testReadBackBeforeRetryWithAFakeConnector() async throws {
        let plan = PartsUsedWritePlan(batch: batch(), reference: reference(), capabilities: capabilities(hasJobs: true),
                                      snapshot: snapshot)
        let connector = FakeStockSystemConnector(capabilities: capabilities(hasJobs: true), failAfter: 1, snapshot: snapshot)

        do {
            _ = try await connector.apply(plan.steps, confirmedAt: S.pulledAt)
            XCTFail("the first send should be uncertain")
        } catch {}
        let readBack = try await connector.readBack(plan, queuedAt: S.pulledAt)
        let remaining = plan.remaining(after: readBack)
        XCTAssertEqual(remaining.map(\.stagedLineID), ["S2"])
        _ = try await connector.apply(remaining, confirmedAt: S.pulledAt)

        let writes = await connector.writes
        XCTAssertEqual(writes.sorted(), plan.steps.map(\.idempotencyKey).sorted())
        let settled = try await connector.readBack(plan, queuedAt: S.pulledAt)
        XCTAssertEqual(plan.remaining(after: settled), [])

        let pulled = try await connector.pullSnapshot(locationIDs: ["L1"], pulledAt: S.pulledAt)
        XCTAssertEqual(pulled, snapshot)
        let locations = try await connector.locations()
        XCTAssertEqual(locations.map(\.id), ["L1", "L2"])
    }

    // MARK: - The reason sent

    func testTheReasonSentIsTheChosenOneTheSystemsOnlyOneOrNone() {
        typealias R = StockAdjustmentReason
        // The system keeps one reason and none is chosen: that one.
        XCTAssertEqual(R.effective(chosen: nil, kept: [.waste], locked: false), .waste)
        // Chosen and kept: the chosen one, whatever else is kept.
        XCTAssertEqual(R.effective(chosen: .internalUse, kept: [.internalUse, .waste], locked: false), .internalUse)
        // Chosen and not kept: the system's only reason, else none.
        XCTAssertEqual(R.effective(chosen: .damage, kept: [.waste], locked: false), .waste)
        XCTAssertNil(R.effective(chosen: .damage, kept: [.internalUse, .waste], locked: false))
        // Several kept and none chosen: none.
        XCTAssertNil(R.effective(chosen: nil, kept: [.internalUse, .waste], locked: false))
        // Keeps none: none.
        XCTAssertNil(R.effective(chosen: .waste, kept: [], locked: false))
        // Locked: a kept reason is used; one the system does not keep is never replaced.
        XCTAssertEqual(R.effective(chosen: .waste, kept: [.waste], locked: true), .waste)
        XCTAssertNil(R.effective(chosen: .damage, kept: [.waste], locked: true))
        XCTAssertNil(R.effective(chosen: nil, kept: [.waste], locked: true))
        XCTAssertEqual(R.ordered([.damage, .internalUse]), [.internalUse, .damage])
    }

    func testAOneReasonSystemWithTheEffectiveReasonSendsAdjustmentsNotNoReason() {
        let caps = capabilities(hasJobs: false, reasons: [.waste],
                                chosen: StockAdjustmentReason.effective(chosen: nil, kept: [.waste], locked: false))
        let plan = PartsUsedWritePlan(batch: batch(), reference: nil, capabilities: caps, snapshot: snapshot)
        XCTAssertTrue(plan.notSent.isEmpty, "\(plan.notSent)")
        XCTAssertFalse(plan.steps.isEmpty)
        for step in plan.steps {
            guard case .adjustment(let adjustment) = step else { return XCTFail("only adjustments") }
            XCTAssertEqual(adjustment.reason, .waste)
        }
    }
}

/// A connector that keeps its writes in memory and can fail part-way through a send, leaving the
/// outcome uncertain as a dropped connection would.
actor FakeStockSystemConnector: StockSystemConnector {

    struct Uncertain: Error {}

    nonisolated let capabilities: StockSystemCapabilities
    private var failAfter: Int?
    private let snapshot: StockSystemSnapshot
    private(set) var writes: [String] = []

    init(capabilities: StockSystemCapabilities, failAfter: Int? = nil, snapshot: StockSystemSnapshot) {
        self.capabilities = capabilities
        self.failAfter = failAfter
        self.snapshot = snapshot
    }

    func locations() async throws -> [StockSystemLocation] { snapshot.locations }

    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot { snapshot }

    func probe() async throws -> StockSystemProbe {
        StockSystemProbe(locations: snapshot.locations, checks: [.init(purpose: .stock, missingScope: nil)])
    }

    func apply(_ steps: [PartsUsedWritePlan.Step], confirmedAt: Date) async throws -> StockSystemReadBack {
        for step in steps {
            if let limit = failAfter, writes.count >= limit {
                failAfter = nil
                throw Uncertain()
            }
            // A system with an idempotency field ignores a key it has already applied.
            if !writes.contains(step.idempotencyKey) { writes.append(step.idempotencyKey) }
        }
        return StockSystemReadBack(applied: Set(writes))
    }

    func readBack(_ plan: PartsUsedWritePlan, queuedAt: Date) async throws -> StockSystemReadBack {
        StockSystemReadBack(applied: Set(writes).intersection(plan.steps.map(\.idempotencyKey)))
    }
}
