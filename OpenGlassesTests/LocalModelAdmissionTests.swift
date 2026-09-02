import XCTest
@testable import OpenGlasses

/// Plan DZ P0 item 6 — backend-aware load admission.
///
/// The load-bearing test here is `testAdmissionAgreesWithTheShippedHeadroomRule`: the MLX load path
/// still calls `MemoryHeadroom.canLoad`, and a second differently-tuned gate is exactly how a
/// "no behaviour change" PR starts refusing loads that used to work. So the new vocabulary is
/// pinned to agree with the old rule wherever they overlap.
final class LocalModelAdmissionTests: XCTestCase {

    private let gigabyte: Int64 = 1_073_741_824

    private func inputs(runtime: LocalModelRuntime = .mlx,
                        weights: Int64,
                        available: Int64,
                        context: Int = 0,
                        policyContext: Int = 0,
                        image: Int64 = 0,
                        reserve: Int64 = 0) -> LocalModelBudget.AdmissionInputs {
        LocalModelBudget.AdmissionInputs(runtime: runtime,
                                        declaredWeightsBytes: weights,
                                        configuredContextTokens: context,
                                        policyContextTokens: policyContext,
                                        availableProcessBytes: available,
                                        imageWorkingSetBytes: image,
                                        safetyReserveBytes: reserve)
    }

    // MARK: - Agreement with the shipped rule

    func testAdmissionAgreesWithTheShippedHeadroomRule() {
        let sizes: [Int64] = [0, 1, 512 * 1024 * 1024, 2 * gigabyte, 4 * gigabyte, 6 * gigabyte]
        let budgets: [Int64] = [0, 1, gigabyte, 3 * gigabyte, 5 * gigabyte, 8 * gigabyte]

        for weights in sizes {
            for available in budgets {
                let legacy = MemoryHeadroom.canLoad(modelBytes: weights, availableBytes: available)
                let admission = LocalModelBudget.admit(
                    inputs(weights: weights, available: available))
                XCTAssertEqual(admission.isAllowed, legacy,
                               "weights=\(weights) available=\(available): the new rule must "
                               + "refuse exactly when the shipped one does")
            }
        }
    }

    // MARK: - Unknown values skip the gate

    func testUnknownWeightsOrBudgetAllow() {
        // 0 weights = not downloaded yet; 0 budget = no per-process cap (simulator, Mac). Refusing
        // on unknown would brick exactly the environments that do not need the guard.
        XCTAssertEqual(LocalModelBudget.admit(inputs(weights: 0, available: gigabyte)), .allow)
        XCTAssertEqual(LocalModelBudget.admit(inputs(weights: 8 * gigabyte, available: 0)), .allow)
    }

    // MARK: - Refusal

    func testRefusalCarriesTheNumbersTheUserNeeds() {
        let weights = 4 * gigabyte
        let available = gigabyte
        let verdict = LocalModelBudget.admit(inputs(weights: weights, available: available))
        guard case .refuse(.insufficientHeadroom(let needed, let reported)) = verdict else {
            return XCTFail("expected a refusal, got \(verdict)")
        }
        XCTAssertEqual(needed, weights + MemoryHeadroom.workingOverheadBytes)
        XCTAssertEqual(reported, available)
        XCTAssertFalse(verdict.isAllowed)
    }

    func testImageWorkingSetAndSafetyReserveCountTowardTheRequirement() {
        // Fits comfortably on its own…
        let base = inputs(weights: 2 * gigabyte, available: 4 * gigabyte)
        XCTAssertTrue(LocalModelBudget.admit(base).isAllowed)

        // …and does not once an image turn and a reserve are added on top.
        let loaded = inputs(weights: 2 * gigabyte, available: 4 * gigabyte,
                            image: gigabyte, reserve: gigabyte)
        XCTAssertFalse(LocalModelBudget.admit(loaded).isAllowed)
    }

    // MARK: - Constrained

    func testATightFitIsAllowedButFlagged() {
        // Exactly enough for weights + working set, with nothing like the comfort margin spare.
        let weights = 2 * gigabyte
        let available = weights + MemoryHeadroom.workingOverheadBytes + 1
        let verdict = LocalModelBudget.admit(inputs(weights: weights, available: available))
        guard case .allowConstrained(.tightHeadroom(let spare)) = verdict else {
            return XCTFail("expected a constrained allow, got \(verdict)")
        }
        XCTAssertEqual(spare, 1)
        XCTAssertTrue(verdict.isAllowed)
    }

    func testARoomyFitIsAPlainAllow() {
        let verdict = LocalModelBudget.admit(
            inputs(weights: gigabyte, available: 8 * gigabyte))
        XCTAssertEqual(verdict, .allow)
    }

    func testAnOversizedContextIsClamped() {
        let verdict = LocalModelBudget.admit(
            inputs(weights: gigabyte, available: 8 * gigabyte, context: 32_768, policyContext: 4_096))
        XCTAssertEqual(verdict, .allowConstrained(.contextClamped(to: 4_096)))
    }

    func testAContextWithinPolicyIsNotClamped() {
        XCTAssertEqual(
            LocalModelBudget.admit(inputs(weights: gigabyte, available: 8 * gigabyte,
                                          context: 2_048, policyContext: 4_096)),
            .allow)
    }

    func testClampIsReportedEvenWhenTheBudgetIsUnknown() {
        // A simulator has no per-process budget, but the context ceiling still applies.
        XCTAssertEqual(
            LocalModelBudget.admit(inputs(weights: 0, available: 0,
                                          context: 32_768, policyContext: 4_096)),
            .allowConstrained(.contextClamped(to: 4_096)))
    }

    func testRefusalWinsOverAClamp() {
        let verdict = LocalModelBudget.admit(
            inputs(weights: 8 * gigabyte, available: gigabyte,
                   context: 32_768, policyContext: 4_096))
        XCTAssertFalse(verdict.isAllowed, "no context clamp rescues a model that cannot fit")
    }

    // MARK: - Runtime awareness

    func testBothRuntimesShareTodaysWorkingSetEstimate() {
        // They are equal today and the test says so out loud: when the GGUF number diverges, this
        // is the assertion that has to be updated deliberately rather than a silent drift.
        XCTAssertEqual(LocalModelBudget.workingSetBytes(for: .mlx),
                       MemoryHeadroom.workingOverheadBytes)
        XCTAssertEqual(LocalModelBudget.workingSetBytes(for: .llamaCpp),
                       MemoryHeadroom.workingOverheadBytes)
        for runtime in LocalModelRuntime.allCases {
            XCTAssertGreaterThan(LocalModelBudget.workingSetBytes(for: runtime), 0)
        }
    }

    func testAdmissionIsEvaluatedPerRuntime() {
        let weights = 2 * gigabyte
        for runtime in LocalModelRuntime.allCases {
            let needed = weights + LocalModelBudget.workingSetBytes(for: runtime)
            XCTAssertFalse(
                LocalModelBudget.admit(inputs(runtime: runtime, weights: weights,
                                              available: needed - 1)).isAllowed)
            XCTAssertTrue(
                LocalModelBudget.admit(inputs(runtime: runtime, weights: weights,
                                              available: needed)).isAllowed)
        }
    }

    // MARK: - Flags

    func testEveryDZFlagDefaultsOff() {
        // Fail-closed rollout: PR1 lands with the whole plan dark. Read through `Config` so the
        // declared default is what is asserted — a leftover `true` from some other test flipping
        // one and not restoring it is itself a failure worth catching.
        XCTAssertFalse(Config.localRuntimeCoordinatorEnabled)
        XCTAssertFalse(Config.ggufModelsEnabled)
        XCTAssertFalse(Config.durableSchedulerStateEnabled)
        XCTAssertFalse(Config.memoryCurationEnabled)
    }
}
