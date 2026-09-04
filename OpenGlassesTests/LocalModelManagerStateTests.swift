import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — what a row of the local-model manager says, and why.
///
/// The screen has five states that overlap, a badge set that must never carry meaning in colour
/// alone, and an incompatibility vocabulary that has to come from the runtime's own typed errors
/// rather than from a string match on a description. All three are pure, so all three are pinned
/// here rather than by looking at the screen.
final class LocalModelManagerStateTests: XCTestCase {

    private let gigabyte: Int64 = 1_073_741_824

    // MARK: - Row state truth table

    func testNothingInstalledAndNothingStagedIsNotInstalled() {
        XCTAssertEqual(LocalModelRowState.derive(.init(descriptor: ggufDescriptor())), .notInstalled)
    }

    func testInstalledWithNothingElseTrueIsInstalled() {
        let state = LocalModelRowState.derive(.init(descriptor: ggufDescriptor(),
                                                    installation: installation()))
        XCTAssertEqual(state, .installed)
    }

    func testResidencyBeatsInstalled() {
        let state = LocalModelRowState.derive(.init(descriptor: ggufDescriptor(),
                                                    installation: installation(),
                                                    isResident: true))
        XCTAssertEqual(state, .loaded)
    }

    func testARecordedIncompatibilityBeatsResidency() {
        // A stale reason on a resident model should never read as "installed and fine"; the
        // ordering says what happens rather than leaving it to whichever branch ran first.
        let state = LocalModelRowState.derive(.init(
            descriptor: ggufDescriptor(),
            installation: installation(),
            isResident: true,
            recordedIncompatibility: .missingArchitectureMetadata))
        XCTAssertEqual(state, .incompatible(.missingArchitectureMetadata))
    }

    func testStagingBeatsEverythingIncludingAnInstalledCopy() {
        // Re-downloading an update over an installed, resident model: bytes are moving, and that is
        // what the row is about.
        let state = LocalModelRowState.derive(.init(
            descriptor: ggufDescriptor(),
            installation: installation(),
            plan: plan(state: .downloading(fileIndex: 0)),
            isResident: true,
            recordedIncompatibility: .weightsMissing))
        guard case .staged(let staging) = state else { return XCTFail("expected staged, got \(state)") }
        XCTAssertEqual(staging.phase, .downloading)
    }

    func testASwitchedOffRuntimeOutranksARecordedReason() {
        // "GGUF is switched off" is why the load would fail *now*, whatever failed last time.
        let state = LocalModelRowState.derive(.init(
            descriptor: ggufDescriptor(),
            installation: installation(),
            recordedIncompatibility: .missingArchitectureMetadata,
            runtimeAvailability: .disabled))
        XCTAssertEqual(state, .incompatible(.runtimeDisabled(.llamaCpp)))
    }

    func testAMissingBackendIsReportedAsUnavailableNotAsAFileProblem() {
        let state = LocalModelRowState.derive(.init(descriptor: ggufDescriptor(),
                                                    installation: installation(),
                                                    runtimeAvailability: .unavailable))
        XCTAssertEqual(state, .incompatible(.runtimeUnavailable(.llamaCpp)))
    }

    func testADifferentPinnedRevisionIsAnUpdate() {
        let installedAt = String(repeating: "1", count: 40)
        let offeredAt = String(repeating: "2", count: 40)
        let state = LocalModelRowState.derive(.init(
            descriptor: ggufDescriptor(revision: offeredAt),
            installation: installation(descriptor: ggufDescriptor(revision: installedAt))))
        XCTAssertEqual(state, .updateAvailable(installedRevision: installedAt,
                                               availableRevision: offeredAt))
    }

    func testUnpinnedRevisionsAreNeverAnUpdate() {
        // Every legacy MLX record reads `unpinned-legacy`; treating that as a difference would put
        // an Update badge on every model a user already has.
        let legacy = LocalModelDescriptor.floatingRevision
        let state = LocalModelRowState.derive(.init(
            descriptor: mlxDescriptor(revision: legacy),
            installation: installation(descriptor: mlxDescriptor(revision: legacy))))
        XCTAssertEqual(state, .installed)
    }

    func testAFinishedPlanIsNotStaging() {
        for finished: LocalModelDownloadPlan.State in [.installed, .cancelled,
                                                       .failed(.terminal(.digestMismatch))] {
            let state = LocalModelRowState.derive(.init(descriptor: ggufDescriptor(),
                                                        installation: installation(),
                                                        plan: plan(state: finished)))
            XCTAssertEqual(state, .installed,
                           "a \(finished) plan is over; the row's state comes from the installation")
        }
    }

    func testARetryablePlanStagesWithARetryOfferAndNoCancel() {
        let state = LocalModelRowState.derive(.init(
            descriptor: ggufDescriptor(),
            plan: plan(state: .failed(.retryable(.transport)))))
        guard case .staged(let staging) = state else { return XCTFail("expected staged") }
        XCTAssertTrue(staging.isRetryable)
        XCTAssertFalse(staging.isCancellable, "a stopped plan has nothing in flight to cancel")
    }

    // MARK: - Staging progress

    func testStagingProgressPrefersTheLiveReadingOverThePersistedOne() {
        var persisted = plan(state: .downloading(fileIndex: 0))
        persisted.recordProgress(fileIndex: 0, completedBytes: 0)

        let fromDisk = LocalModelStagingSummary(plan: persisted)
        XCTAssertEqual(fromDisk?.completedBytes, 0)

        let live = LocalModelStagingSummary(plan: persisted, completedBytes: 250_000_000)
        XCTAssertEqual(live?.completedBytes, 250_000_000)
        XCTAssertEqual(live?.fractionCompleted ?? 0, 0.5, accuracy: 0.001)
    }

    // MARK: - Badges

    func testEveryBadgeCarriesASpokenLabelThatIsNotJustItsDrawnText() {
        let descriptor = ggufDescriptor(capabilities: [.text, .vision, .toolFriendly])
        let badges = LocalModelPresentation.rowBadges(state: .installed, descriptor: descriptor)

        XCTAssertTrue(badges.contains { $0.id == "runtime.gguf" })
        XCTAssertTrue(badges.contains { $0.id == "quantization" })
        XCTAssertTrue(badges.contains { $0.id == "capability.vision" })
        XCTAssertTrue(badges.contains { $0.id == "capability.tools" })

        for badge in badges {
            XCTAssertFalse(badge.spokenLabel.isEmpty, "\(badge.id) has no spoken label")
            XCTAssertNotEqual(badge.spokenLabel, badge.text,
                              "\(badge.id) speaks its drawn abbreviation rather than a sentence")
        }
    }

    func testTextOnlyModelsWearNoCapabilityBadge() {
        // A badge every row wears carries no information.
        XCTAssertTrue(LocalModelPresentation.capabilityBadges([.text]).isEmpty)
    }

    func testEveryRowStateSpeaksSomethingSpecific() {
        let states: [LocalModelRowState] = [
            .notInstalled,
            .installed,
            .loaded,
            .updateAvailable(installedRevision: String(repeating: "1", count: 40),
                             availableRevision: String(repeating: "2", count: 40)),
            .incompatible(.missingArchitectureMetadata),
            .staged(LocalModelStagingSummary(plan: plan(state: .downloading(fileIndex: 0)),
                                             completedBytes: 250_000_000)!),
        ]
        var spoken = Set<String>()
        for state in states {
            XCTAssertFalse(state.badgeText.isEmpty)
            XCTAssertFalse(state.spokenLabel.isEmpty)
            XCTAssertTrue(spoken.insert(state.spokenLabel).inserted,
                          "two states speak identically: \(state.spokenLabel)")
        }
    }

    func testADownloadingRowSpeaksItsPercentage() {
        let staging = LocalModelStagingSummary(plan: plan(state: .downloading(fileIndex: 0)),
                                               completedBytes: 250_000_000)!
        XCTAssertTrue(LocalModelRowState.staged(staging).spokenLabel.contains("50 percent"),
                      LocalModelRowState.staged(staging).spokenLabel)
    }

    // MARK: - Incompatibility mapping

    func testTypedRuntimeErrorsMapToWhatIsMissing() {
        XCTAssertEqual(LocalModelIncompatibility.from(LlamaBackendError.runtimeDisabled),
                       .runtimeDisabled(.llamaCpp))
        XCTAssertEqual(LocalModelIncompatibility.from(LlamaBackendError.unsupportedArchitecture),
                       .missingArchitectureMetadata)
        XCTAssertEqual(LocalModelIncompatibility.from(
            LlamaBackendError.unsupportedChatTemplate(.absent)),
                       .unsupportedChatTemplate(.absent))
        XCTAssertEqual(LocalModelIncompatibility.from(LlamaBackendError.contextTooSmall(tokens: 128)),
                       .contextTooSmall(tokens: 128))
        XCTAssertEqual(LocalModelIncompatibility.from(
            LlamaBackendError.weightsMissing(LocalModelID("a/b"))), .weightsMissing)
        XCTAssertEqual(LocalModelIncompatibility.from(
            LocalInferenceError.noBackend(.llamaCpp)), .runtimeUnavailable(.llamaCpp))
    }

    func testTransientFailuresAreNotIncompatibilities() {
        // Telling someone their model is broken because they had a video call open is the failure
        // this filter exists to prevent.
        let transient: [Error] = [
            LlamaBackendError.insufficientMemory(neededBytes: 1, availableBytes: 0),
            LlamaBackendError.alreadyGenerating,
            LlamaBackendError.promptTooLong(promptTokens: 9, reserveTokens: 1, contextTokens: 4),
            LocalInferenceError.transitionInProgress,
            LocalInferenceError.backgrounded,
            CancellationError(),
        ]
        for error in transient {
            XCTAssertNil(LocalModelIncompatibility.from(error), "\(error) is a moment, not a model")
        }
    }

    func testEveryIncompatibilityNamesWhatIsMissing() {
        let reasons: [LocalModelIncompatibility] = [
            .runtimeDisabled(.llamaCpp), .runtimeUnavailable(.mlx), .missingArchitectureMetadata,
            .unsupportedChatTemplate(.noAssistantHeader), .contextTooSmall(tokens: 200),
            .weightsMissing, .installationIncomplete,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.badgeText.isEmpty)
            XCTAssertGreaterThan(reason.explanation.count, 40,
                                 "\(reason) explains nothing a person can act on")
            XCTAssertTrue(reason.spokenLabel.hasPrefix("Can't be loaded."))
        }
        // Only the switch-shaped ones are fixable without touching the file.
        XCTAssertTrue(LocalModelIncompatibility.runtimeDisabled(.llamaCpp).isResolvableBySetting)
        XCTAssertFalse(LocalModelIncompatibility.missingArchitectureMetadata.isResolvableBySetting)
    }

    func testEveryChatTemplateFaultIsExplainedDistinctly() {
        let faults: [LlamaChatTemplateFault] = [
            .absent, .renderFailed, .emptyRender, .dropsUserContent, .dropsAssistantContent,
            .noAssistantHeader,
        ]
        var explanations = Set<String>()
        for fault in faults {
            let explanation = LocalModelIncompatibility.unsupportedChatTemplate(fault).explanation
            XCTAssertTrue(explanations.insert(explanation).inserted,
                          "two template faults read identically")
        }
    }

    // MARK: - Filters

    func testRuntimeAndCapabilityFiltersAreIndependent() {
        XCTAssertTrue(LocalModelPresentation.RuntimeFilter.all.accepts(.mlx))
        XCTAssertTrue(LocalModelPresentation.RuntimeFilter.gguf.accepts(.llamaCpp))
        XCTAssertFalse(LocalModelPresentation.RuntimeFilter.gguf.accepts(.mlx))

        // "Text only" must exclude vision models, or it is indistinguishable from "all".
        XCTAssertTrue(LocalModelPresentation.CapabilityFilter.text.accepts([.text]))
        XCTAssertFalse(LocalModelPresentation.CapabilityFilter.text.accepts([.text, .vision]))
        XCTAssertTrue(LocalModelPresentation.CapabilityFilter.vision.accepts([.text, .vision]))
    }

    func testFilterTitlesAndSpokenLabelsDiffer() {
        for filter in LocalModelPresentation.RuntimeFilter.allCases {
            XCTAssertNotEqual(filter.title, filter.spokenLabel)
        }
        for filter in LocalModelPresentation.CapabilityFilter.allCases {
            XCTAssertNotEqual(filter.title, filter.spokenLabel)
        }
    }

    // MARK: - Fit rendering

    func testBlockersDisableTheActionAndSayWhy() {
        let report = LocalModelFitReport.make(.init(descriptor: ggufDescriptor(),
                                                    availableStorageBytes: nil,
                                                    availableProcessBytes: 8 * gigabyte))
        let presentation = LocalModelPresentation.present(report)
        XCTAssertFalse(presentation.canProceed)
        XCTAssertNotNil(presentation.refusalSummary)
        XCTAssertEqual(presentation.blockerMessages,
                       [LocalModelFitReport.Blocker.freeSpaceUnreadable.localizedMessage],
                       "the blocker's own words, not a paraphrase")
    }

    func testWarningsInformAndPermit() {
        let report = LocalModelFitReport.make(.init(
            descriptor: ggufDescriptor(weightsBytes: 6 * gigabyte),
            availableStorageBytes: 64 * gigabyte,
            availableProcessBytes: gigabyte))
        let presentation = LocalModelPresentation.present(report)
        XCTAssertTrue(presentation.canProceed, "a memory verdict warns; it does not block")
        XCTAssertTrue(presentation.blockerMessages.isEmpty)
        XCTAssertFalse(presentation.warningMessages.isEmpty)
    }

    func testTheConsentFactsCoverSizeStorageMemoryAndVerdict() {
        let report = LocalModelFitReport.make(.init(descriptor: ggufDescriptor(),
                                                    availableStorageBytes: 20 * gigabyte,
                                                    availableProcessBytes: 8 * gigabyte))
        let ids = Set(LocalModelPresentation.present(report).facts.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["download", "storage", "memory", "verdict", "licence"]))
    }

    func testUnreadableFreeSpaceIsShownAsUnreadableNotAsZero() {
        let report = LocalModelFitReport.make(.init(descriptor: ggufDescriptor(),
                                                    availableStorageBytes: nil,
                                                    availableProcessBytes: 8 * gigabyte))
        let storage = LocalModelPresentation.present(report).facts.first { $0.id == "storage" }
        XCTAssertEqual(storage?.value, "Couldn't be read")
    }

    func testEstimatedResidentBytesMatchesWhatTheFitReportJudged() {
        // The row and the consent screen print the same figure, or one of them is lying.
        let descriptor = ggufDescriptor(minimumHeadroomBytes: 128 * 1024 * 1024)
        let report = LocalModelFitReport.make(.init(descriptor: descriptor,
                                                    availableStorageBytes: 64 * gigabyte,
                                                    availableProcessBytes: 8 * gigabyte))
        XCTAssertEqual(LocalModelPresentation.estimatedResidentBytes(descriptor),
                       report.estimatedResidentBytes)
    }

    // MARK: - Helpers

    private func file(bytes: Int64 = 500_000_000, path: String = "m.gguf") -> LocalModelFile {
        LocalModelFile(relativePath: path, byteCount: bytes,
                       sha256: String(repeating: "a", count: 64), role: .weights)
    }

    private func ggufDescriptor(revision: String = String(repeating: "b", count: 40),
                                weightsBytes: Int64 = 500_000_000,
                                minimumHeadroomBytes: Int64 = 0,
                                capabilities: Set<LocalModelCapability> = [.text])
        -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: LocalModelID("owner/repo#m.gguf"),
            displayName: "Test model",
            runtime: .llamaCpp,
            repositoryID: "owner/repo",
            revision: revision,
            files: [file(bytes: weightsBytes)],
            quantization: "Q4_K_M",
            capabilities: capabilities,
            contextLength: 4096,
            estimatedWeightsBytes: weightsBytes,
            estimatedWorkingBytes: LocalModelBudget.workingSetBytes(for: .llamaCpp),
            minimumHeadroomBytes: minimumHeadroomBytes,
            license: .unverified)
    }

    private func mlxDescriptor(revision: String) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: LocalModelID("mlx-community/thing-4bit"),
            displayName: "Thing",
            runtime: .mlx,
            repositoryID: "mlx-community/thing-4bit",
            revision: revision,
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: 0,
            estimatedWorkingBytes: 0,
            minimumHeadroomBytes: 0)
    }

    private func installation(descriptor: LocalModelDescriptor? = nil) -> InstalledLocalModel {
        let descriptor = descriptor ?? ggufDescriptor()
        return InstalledLocalModel(descriptor: descriptor,
                                   storage: .managed(directoryName: descriptor.id.storageComponent),
                                   installedAt: Date(timeIntervalSince1970: 0))
    }

    private func plan(state: LocalModelDownloadPlan.State) -> LocalModelDownloadPlan {
        var plan = LocalModelDownloadPlan(descriptor: ggufDescriptor(), origin: .curatedCatalog)!
        plan.state = state
        return plan
    }
}
