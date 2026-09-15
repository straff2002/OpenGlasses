import Combine
import XCTest
@testable import OpenGlasses

/// Plan FC P2 — what a download and the preparation that follows it are allowed to say.
///
/// Two defects are pinned here rather than looked for on screen:
///
/// 1. A finished download could read **"Downloading 99%"** for as long as the transfer took to
///    settle, because the byte estimate was capped at 0.99 and nothing else moved the state on.
/// 2. The load that followed wrote the model factory's fraction into the *download's* progress
///    variable, so a load was drawn as a download.
///
/// Both are now impossible by construction: one phase value, written only by the attempt that owns
/// it. The service half is driven entirely through the injected `downloadFunction` / `loadFunction`
/// seams — no network, and no MLX, which needs Metal the simulator does not have.
@MainActor
final class LocalModelPreparationPhaseTests: XCTestCase {

    /// A catalog model, so `expectedDownloadBytes` returns a measured total and the download can
    /// honestly show a percentage.
    private let measuredModelID = "mlx-community/gemma-4-e2b-it-4bit"
    /// An id the catalog has never heard of: no denominator, so no percentage.
    private let unmeasuredModelID = "someone/a-model-we-do-not-ship"

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Record every phase the service publishes, in order.
    private func recordPhases(of service: LocalLLMService) -> PhaseLog {
        let log = PhaseLog()
        service.$preparation.sink { log.phases.append($0) }.store(in: &cancellables)
        return log
    }

    // MARK: - The pure phase

    func testOnlyAMeasurableDownloadOffersAPercentage() {
        XCTAssertEqual(LocalModelPreparationPhase.downloading(fraction: 0.5).accessibilityPercent, 50)
        XCTAssertNil(LocalModelPreparationPhase.downloading(fraction: nil).accessibilityPercent,
                     "an unknown total has no percentage to read")
        XCTAssertNil(LocalModelPreparationPhase.verifying.accessibilityPercent)
        XCTAssertNil(LocalModelPreparationPhase.installing.accessibilityPercent)
        XCTAssertNil(LocalModelPreparationPhase.loading(fraction: 0.9).accessibilityPercent,
                     "a load's fraction is not a download percentage and must never read as one")
    }

    func testAnIndeterminatePhaseHasNoBarValue() {
        XCTAssertNil(LocalModelPreparationPhase.downloading(fraction: nil).determinateFraction)
        XCTAssertNil(LocalModelPreparationPhase.verifying.determinateFraction)
        XCTAssertNil(LocalModelPreparationPhase.installing.determinateFraction)
        XCTAssertNil(LocalModelPreparationPhase.loading(fraction: nil).determinateFraction)
        XCTAssertNil(LocalModelPreparationPhase.cancelling.determinateFraction)
        XCTAssertEqual(LocalModelPreparationPhase.ready.determinateFraction, 1)
        XCTAssertEqual(LocalModelPreparationPhase.downloading(fraction: 2).determinateFraction, 1,
                       "a fraction out of range is clamped, never drawn past the end of the bar")
    }

    func testNoSpokenPhaseNameCarriesAPercentage() {
        // The phase name is the accessibility *label*; the number is the *value*. A number in the
        // label is what makes VoiceOver re-announce a download dozens of times, so no phase name
        // may contain one. (Saying a step *has* no percentage is fine — that is the honest part.)
        for phase in Self.everyPhase {
            let spoken = phase.spokenLabel
            XCTAssertFalse(spoken.isEmpty, "\(phase) says nothing")
            XCTAssertFalse(spoken.contains("%"), "\(phase) puts a percent sign in its label")
            XCTAssertNil(spoken.rangeOfCharacter(from: .decimalDigits),
                         "\(phase) puts a number in its label: \(spoken)")
        }
    }

    func testAPendingStopSaysTheStopIsPendingAndThatNothingWillBeActivated() {
        let spoken = LocalModelPreparationPhase.cancelling.spokenLabel
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("stopping"), spoken)
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("won't be activated"), spoken)
        XCTAssertFalse(LocalModelPreparationPhase.cancelling.isCancellable,
                       "a stop already asked for is not offered again")
    }

    // MARK: - The acquisition pipeline's phases, in the same vocabulary

    func testTheAcquisitionPipelineChecksAndInstallsWithoutShowingDownloadBytes() throws {
        for state in [LocalModelDownloadPlan.State.validating(fileIndex: 0), .installing] {
            let staging = try XCTUnwrap(LocalModelStagingSummary(plan: plan(state: state),
                                                                 completedBytes: 500_000_000))
            let phase = LocalModelPreparationPhase(staging: staging)
            XCTAssertTrue(phase == .verifying || phase == .installing, "\(state) → \(phase)")
            XCTAssertNil(phase.determinateFraction,
                         "checking and installing have no byte denominator of their own")
            XCTAssertNil(phase.accessibilityPercent,
                         "a finished transfer must not keep reading as bytes still arriving")
            // The summary still knows the bytes — the row simply stops presenting them as progress.
            XCTAssertEqual(staging.completedBytes, 500_000_000)
        }
    }

    func testTheAcquisitionPipelineShowsBytesWhileBytesAreMoving() throws {
        var moving = plan(state: .downloading(fileIndex: 0))
        moving.recordProgress(fileIndex: 0, completedBytes: 0)
        let staging = try XCTUnwrap(LocalModelStagingSummary(plan: moving,
                                                              completedBytes: 250_000_000))
        let phase = LocalModelPreparationPhase(staging: staging)
        XCTAssertEqual(phase.determinateFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(phase.accessibilityPercent, 50)
    }

    func testMultiFileProgressCountsEveryFileNotJustTheOneInFlight() throws {
        var multi = plan(state: .downloading(fileIndex: 1), fileCount: 3)
        multi.recordProgress(fileIndex: 0, completedBytes: 500_000_000)   // finished
        multi.recordProgress(fileIndex: 1, completedBytes: 250_000_000)   // half of the second
        let staging = try XCTUnwrap(LocalModelStagingSummary(plan: multi))
        XCTAssertEqual(staging.fileNumber, 2)
        XCTAssertEqual(staging.fileCount, 3)
        // 750 MB of 1.5 GB across three 500 MB files.
        XCTAssertEqual(LocalModelPreparationPhase(staging: staging).accessibilityPercent, 50)
    }

    func testAFailedVerificationIsAFailureWithAReasonAndNeverReadsAsReady() throws {
        // Retryable: the row keeps a phase, and it is a failure carrying the plan's own sentence.
        let retryable = try XCTUnwrap(
            LocalModelStagingSummary(plan: plan(state: .failed(.retryable(.transport)))))
        let phase = LocalModelPreparationPhase(staging: retryable)
        guard case .failed(let reason) = phase else { return XCTFail("expected failed, got \(phase)") }
        XCTAssertEqual(reason, LocalModelRowState.retryExplanation(.transport))
        XCTAssertNotEqual(phase, .ready)

        // A digest mismatch is terminal, so it produces no staging at all — there is no path by
        // which a refused download can be bridged into a phase that claims success.
        XCTAssertNil(LocalModelStagingSummary(plan: plan(state: .failed(.terminal(.digestMismatch)))),
                     "a refused download is not staging, and must not become one")
    }

    // MARK: - The MLX service: download then load

    func testDownloadThenLoadPassesThroughDistinctPhasesEndingReady() async throws {
        let service = LocalLLMService()
        let log = recordPhases(of: service)
        var phaseSeenInsideTheLoad: LocalModelPreparationPhase?

        service.downloadFunction = { _, onProgress in
            onProgress(0.4)
            await Task.yield()
            onProgress(0.99)          // the byte estimate's ceiling
            await Task.yield()
        }
        service.loadFunction = { [weak service] _, onProgress in
            onProgress(0.5)
            phaseSeenInsideTheLoad = service?.preparation
            return false
        }

        try await service.downloadModel(measuredModelID)
        XCTAssertEqual(service.preparation, .ready, "the transfer's return ends the download phase")
        try await service.loadModel(measuredModelID)

        XCTAssertEqual(service.preparation, .ready)
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.loadedModelId, measuredModelID)

        // The whole point: while the load ran, nothing described it as a download.
        guard case .loading = phaseSeenInsideTheLoad else {
            return XCTFail("the load reported itself as \(String(describing: phaseSeenInsideTheLoad))")
        }
        XCTAssertTrue(log.indexOfLast(\.isDownloadPhase)! < log.indexOfFirst(\.isLoadPhase)!,
                      "downloading finished before preparing began: \(log.phases)")
        XCTAssertNil(log.phases.drop(while: { !$0.isLoadPhase }).first(where: \.isDownloadPhase),
                     "a download phase reappeared after the load began: \(log.phases)")
    }

    func testACompletedDownloadNeverRestsAtNinetyNinePercent() async throws {
        let service = LocalLLMService()
        let log = recordPhases(of: service)
        service.downloadFunction = { _, onProgress in onProgress(0.99) }
        service.loadFunction = { _, _ in
            // A slow load, in the window where the old code left "Downloading 99%" on screen.
            for _ in 1...50 { await Task.yield() }
            return false
        }

        try await service.downloadModel(measuredModelID)
        try await service.loadModel(measuredModelID)

        // No published state is both "downloading" and effectively finished *after* the transfer
        // returned. The only 0.99 in the log is the last thing the live transfer itself said.
        let afterTheTransfer = Array(log.phases.drop(while: { $0 != .ready }))
        XCTAssertFalse(afterTheTransfer.contains(where: {
            if case .downloading(let fraction) = $0 { return (fraction ?? 0) >= 0.99 }
            return false
        }), "a finished download went on reading as \"Downloading 99%\": \(log.phases)")
    }

    func testAnUnknownTotalIsIndeterminateAndOffersNoPercentage() async throws {
        let service = LocalLLMService()
        var phaseWhileRunning: LocalModelPreparationPhase?
        service.downloadFunction = { [weak service] _, _ in
            phaseWhileRunning = service?.preparation
        }

        try await service.downloadModel(unmeasuredModelID)

        XCTAssertEqual(phaseWhileRunning, .downloading(fraction: nil),
                       "no catalog size means no denominator, so no invented percentage")
        XCTAssertNil(phaseWhileRunning?.accessibilityPercent)
        XCTAssertNil(phaseWhileRunning?.determinateFraction)
        XCTAssertTrue(phaseWhileRunning?.spokenLabel
            .localizedCaseInsensitiveContains("isn't known") ?? false,
                      "the reason there is no percentage is said out loud")
    }

    func testAMeasurableDownloadReportsATrueFraction() async throws {
        let service = LocalLLMService()
        var phaseWhileRunning: LocalModelPreparationPhase?
        service.downloadFunction = { [weak service] _, onProgress in
            onProgress(0.25)
            phaseWhileRunning = service?.preparation
        }

        try await service.downloadModel(measuredModelID)

        XCTAssertEqual(phaseWhileRunning, .downloading(fraction: 0.25))
        XCTAssertEqual(phaseWhileRunning?.accessibilityPercent, 25)
    }

    // MARK: - Cancel

    func testCancellingADownloadStopsItAndNoLoadFollows() async {
        let service = LocalLLMService()
        let running = expectation(description: "downloading")
        running.assertForOverFulfill = false
        let loadStarted = Gate()

        service.downloadFunction = { _, onProgress in
            for step in 1...1_000_000 {
                try Task.checkCancellation()
                onProgress(min(1, Double(step) / 1_000_000))
                running.fulfill()
                await Task.yield()
            }
        }
        service.loadFunction = { _, _ in loadStarted.isOpen = true; return false }

        // The screen's own sequence: load only if the download succeeded.
        let flow = Task {
            try await service.downloadModel(measuredModelID)
            try await service.loadModel(measuredModelID)
        }
        await fulfillment(of: [running], timeout: 2)
        service.cancelDownload()

        XCTAssertEqual(service.preparation, .cancelled)
        do {
            try await flow.value
            XCTFail("a cancelled download must not go on to load")
        } catch is CancellationError {
            // correct
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(loadStarted.isOpen, "no preparation may start after a cancelled download")
        XCTAssertFalse(service.isDownloading)
        XCTAssertNil(service.downloadingModelId)
        XCTAssertEqual(service.preparation, .cancelled)
    }

    func testCancellingALoadSaysTheStopIsPendingAndTheLateResultIsDiscarded() async {
        let service = LocalLLMService()
        let running = expectation(description: "preparing")
        running.assertForOverFulfill = false
        let release = Gate()

        // A load with no cancellation seam of its own — the real model factory's shape. It keeps
        // going after the stop is asked for, and finishes *successfully*.
        service.loadFunction = { _, onProgress in
            for step in 1...1_000_000 {
                if release.isOpen { return true }
                onProgress(min(1, Double(step) / 1_000))
                running.fulfill()
                await Task.yield()
            }
            return true
        }

        let load = Task { try await service.loadModel(measuredModelID) }
        await fulfillment(of: [running], timeout: 2)
        service.cancelDownload()

        XCTAssertEqual(service.preparation, .cancelling,
                       "a stop that cannot be honoured yet says so rather than pretending")
        XCTAssertTrue(service.isLoadingModel, "the work has not actually stopped")

        release.isOpen = true   // the load completes, late
        do {
            try await load.value
            XCTFail("an invalidated load must not report success")
        } catch is CancellationError {
            // correct
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(service.preparation, .cancelled)
        XCTAssertFalse(service.isModelLoaded, "a late completion must not activate the model")
        XCTAssertNil(service.loadedModelId)
    }

    func testProgressFromACancelledLoadCannotPaintOverTheStop() async {
        let service = LocalLLMService()
        let running = expectation(description: "preparing")
        running.assertForOverFulfill = false
        let release = Gate()
        service.loadFunction = { _, onProgress in
            for step in 1...1_000_000 {
                if release.isOpen { return false }
                onProgress(min(1, Double(step) / 1_000))
                running.fulfill()
                await Task.yield()
            }
            return false
        }

        let load = Task { try await service.loadModel(measuredModelID) }
        await fulfillment(of: [running], timeout: 2)
        service.cancelDownload()

        // Let the load report progress several more times while the stop is pending.
        for _ in 1...20 { await Task.yield() }
        XCTAssertEqual(service.preparation, .cancelling,
                       "progress from a stopped attempt must not overwrite \"Stopping\"")

        release.isOpen = true
        _ = try? await load.value
    }

    // MARK: - Reset across retry and model change

    func testAFailedPreparationIsReportedAsFailedAndRetryingResetsIt() async {
        let service = LocalLLMService()
        service.loadFunction = { _, _ in throw LocalLLMError.generationFailed("Nope.") }

        do {
            try await service.loadModel(measuredModelID)
            XCTFail("expected the failure to propagate")
        } catch {}

        guard case .failed(let reason) = service.preparation else {
            return XCTFail("expected failed, got \(service.preparation)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(service.isModelLoaded)

        // Retry: the phase starts again from the beginning rather than inheriting the failure.
        var phaseWhileRetrying: LocalModelPreparationPhase?
        service.loadFunction = { [weak service] _, _ in
            phaseWhileRetrying = service?.preparation
            return false
        }
        try? await service.loadModel(measuredModelID)

        guard case .loading = phaseWhileRetrying else {
            return XCTFail("a retry inherited \(String(describing: phaseWhileRetrying))")
        }
        XCTAssertEqual(service.preparation, .ready)
    }

    func testSwitchingModelMidPreparationDiscardsTheFirstOne() async {
        let service = LocalLLMService()
        let firstRunning = expectation(description: "first load")
        firstRunning.assertForOverFulfill = false
        let release = Gate()

        service.loadFunction = { modelID, _ in
            guard modelID == self.measuredModelID else { return false }   // the second load
            for _ in 1...1_000_000 {
                if release.isOpen { return false }
                firstRunning.fulfill()
                await Task.yield()
            }
            return false
        }

        let first = Task { try await service.loadModel(measuredModelID) }
        await fulfillment(of: [firstRunning], timeout: 2)

        // The user picks a different model while the first is still preparing.
        try? await service.loadModel(unmeasuredModelID)
        XCTAssertEqual(service.loadedModelId, unmeasuredModelID)
        XCTAssertEqual(service.preparation, .ready)

        release.isOpen = true
        do {
            try await first.value
            XCTFail("a superseded load must not report success")
        } catch is CancellationError {
            // correct
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(service.loadedModelId, unmeasuredModelID,
                       "the superseded load must not steal residency back")
        XCTAssertEqual(service.preparation, .ready,
                       "nor overwrite the phase of the attempt that replaced it")
    }

    // MARK: - Speech

    func testPhaseChangesAreAnnouncedOnceAndPercentTicksAreNot() {
        var announcer = LocalModelProgressAnnouncer(modelName: "Thing")
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertNotNil(announcer.announcement(for: .progress(fraction: 0.2), at: start))
        // Twenty more ticks across the same ten points, over more than the interval floor: silence.
        for tick in 1...20 {
            let at = start.addingTimeInterval(Double(tick) * 5)
            XCTAssertNil(announcer.announcement(for: .progress(fraction: 0.2 + Double(tick) * 0.004),
                                                at: at),
                         "every percent tick must not be announced (tick \(tick))")
        }
        // Completion speaks immediately, and only once.
        let done = start.addingTimeInterval(200)
        XCTAssertNotNil(announcer.announcement(for: .completed, at: done))
        XCTAssertNil(announcer.announcement(for: .completed, at: done))
        XCTAssertNil(announcer.announcement(for: .progress(fraction: 1), at: done),
                     "nothing follows the one event a person was waiting for")
    }

    // MARK: - Fixtures

    private static let everyPhase: [LocalModelPreparationPhase] = [
        .idle, .waitingForConsent, .queued, .downloading(fraction: nil),
        .downloading(fraction: 0.5), .verifying, .installing, .loading(fraction: nil),
        .loading(fraction: 0.5), .ready, .cancelling, .cancelled, .failed(reason: "Nope.")
    ]

    private func plan(state: LocalModelDownloadPlan.State,
                      fileCount: Int = 1) -> LocalModelDownloadPlan {
        var plan = LocalModelDownloadPlan(descriptor: descriptor(fileCount: fileCount),
                                          origin: .curatedCatalog)!
        plan.state = state
        return plan
    }

    private func descriptor(fileCount: Int) -> LocalModelDescriptor {
        let files = (0..<fileCount).map {
            LocalModelFile(relativePath: "weights-\($0).gguf",
                           byteCount: 500_000_000,
                           sha256: String(repeating: "a", count: 64),
                           role: .weights)
        }
        return LocalModelDescriptor(
            id: LocalModelID("owner/repo#weights.gguf"),
            displayName: "Thing",
            runtime: .llamaCpp,
            repositoryID: "owner/repo",
            revision: String(repeating: "b", count: 40),
            files: files,
            quantization: "Q4_K_M",
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: 500_000_000 * Int64(fileCount),
            estimatedWorkingBytes: LocalModelBudget.workingSetBytes(for: .llamaCpp),
            minimumHeadroomBytes: 0,
            license: .unverified)
    }
}

// MARK: - Test support

/// A flag both a test body and an escaping fake can see. `@unchecked` because every touch happens
/// on the main actor; it exists only to give the closure a shared box.
private final class Gate: @unchecked Sendable {
    var isOpen = false
}

/// Every phase the service published, in order.
private final class PhaseLog: @unchecked Sendable {
    var phases: [LocalModelPreparationPhase] = []

    func indexOfFirst(_ predicate: (LocalModelPreparationPhase) -> Bool) -> Int? {
        phases.firstIndex(where: predicate)
    }

    func indexOfLast(_ predicate: (LocalModelPreparationPhase) -> Bool) -> Int? {
        phases.lastIndex(where: predicate)
    }
}

private extension LocalModelPreparationPhase {
    var isDownloadPhase: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isLoadPhase: Bool {
        if case .loading = self { return true }
        return false
    }
}
