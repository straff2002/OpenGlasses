import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the pre-download fit and consent verdict.
///
/// The awkward rows are the reason this is a truth table rather than a couple of happy-path checks:
/// an unknown size, a missing digest and an *unreadable* free-space reading must each stop an
/// install, and none of them may be softened into a warning.
final class LocalModelFitReportTests: XCTestCase {

    private let gigabyte: Int64 = 1_073_741_824

    // MARK: - The facts shown

    func testReportStatesExactSizeRuntimeQuantizationAndCapabilities() {
        let report = LocalModelFitReport.make(.init(descriptor: descriptor(weightsBytes: 500_000_000),
                                                    availableStorageBytes: 20 * gigabyte,
                                                    availableProcessBytes: 4 * gigabyte))
        XCTAssertEqual(report.downloadBytes, 500_000_000, "the exact sum of declared files, not an estimate")
        XCTAssertEqual(report.runtime, .llamaCpp)
        XCTAssertEqual(report.quantization, "Q4_K_M")
        XCTAssertEqual(report.capabilities, [.text])
        XCTAssertEqual(report.availableStorageBytes, 20 * gigabyte)
        XCTAssertTrue(report.canInstall)
    }

    // MARK: - Blockers

    func testUnknownSizeMissingDigestAndUnpinnedRevisionEachBlockInstallation() {
        let unknownSize = LocalModelFitReport.make(.init(
            descriptor: descriptor(files: [file(bytes: 0)]),
            availableStorageBytes: 20 * gigabyte, availableProcessBytes: 4 * gigabyte))
        XCTAssertFalse(unknownSize.canInstall)
        XCTAssertTrue(unknownSize.blockers.contains(.unknownFileSize(relativePath: "m.gguf")))

        let noDigest = LocalModelFitReport.make(.init(
            descriptor: descriptor(files: [file(sha256: "")]),
            availableStorageBytes: 20 * gigabyte, availableProcessBytes: 4 * gigabyte))
        XCTAssertFalse(noDigest.canInstall)
        XCTAssertTrue(noDigest.blockers.contains(.missingDigest(relativePath: "m.gguf")))

        let unpinned = LocalModelFitReport.make(.init(
            descriptor: descriptor(revision: LocalModelDescriptor.floatingRevision),
            availableStorageBytes: 20 * gigabyte, availableProcessBytes: 4 * gigabyte))
        XCTAssertFalse(unpinned.canInstall)
        XCTAssertTrue(unpinned.blockers.contains(.unresolvedRevision))

        let noFiles = LocalModelFitReport.make(.init(
            descriptor: descriptor(files: []),
            availableStorageBytes: 20 * gigabyte, availableProcessBytes: 4 * gigabyte))
        XCTAssertTrue(noFiles.blockers.contains(.noFiles))
    }

    func testUnreadableFreeSpaceIsAnInabilityToCheckNotPermissionToProceed() {
        let report = LocalModelFitReport.make(.init(descriptor: descriptor(),
                                                    availableStorageBytes: nil,
                                                    availableProcessBytes: 8 * gigabyte))
        XCTAssertFalse(report.canInstall, "a reading nobody could take is not a reading that passed")
        XCTAssertEqual(report.blockers, [.freeSpaceUnreadable])
    }

    func testStorageMustCoverTheDownloadPlusAMargin() {
        let weights: Int64 = 2 * gigabyte
        // Enough for the file but not for the margin.
        let tooTight = LocalModelFitReport.make(.init(
            descriptor: descriptor(weightsBytes: weights, files: [file(bytes: weights)]),
            availableStorageBytes: weights + 100,
            availableProcessBytes: 8 * gigabyte))
        XCTAssertFalse(tooTight.canInstall)
        XCTAssertEqual(tooTight.blockers,
                       [.insufficientStorage(neededBytes: weights + LocalModelFitReport.storageMarginBytes,
                                             freeBytes: weights + 100)])

        // Just over the bar: allowed, but the user is told it will be tight.
        let tight = LocalModelFitReport.make(.init(
            descriptor: descriptor(weightsBytes: weights, files: [file(bytes: weights)]),
            availableStorageBytes: weights + LocalModelFitReport.storageMarginBytes + 1,
            availableProcessBytes: 8 * gigabyte))
        XCTAssertTrue(tight.canInstall)
        XCTAssertTrue(tight.warnings.contains { if case .storageAfterInstallIsTight = $0 { return true }
                                                return false })
    }

    func testLicenceAcceptanceGatesInstallationWhenItIsRequired() {
        let licensed = descriptor(license: LocalModelLicenseSummary(
            displayName: "Custom terms", summary: "…", requiresAcceptance: true, revision: "rev-1"))

        let unaccepted = LocalModelFitReport.make(.init(descriptor: licensed,
                                                        availableStorageBytes: 20 * gigabyte,
                                                        availableProcessBytes: 8 * gigabyte))
        XCTAssertEqual(unaccepted.blockers, [.licenseNotAccepted])
        XCTAssertTrue(unaccepted.requiresLicenseAcceptance)

        // Accepting a *different* revision is not accepting this one.
        let wrongRevision = LocalModelFitReport.make(.init(descriptor: licensed,
                                                           availableStorageBytes: 20 * gigabyte,
                                                           availableProcessBytes: 8 * gigabyte,
                                                           acceptedLicenseRevision: "rev-0"))
        XCTAssertEqual(wrongRevision.blockers, [.licenseNotAccepted])

        let accepted = LocalModelFitReport.make(.init(descriptor: licensed,
                                                       availableStorageBytes: 20 * gigabyte,
                                                       availableProcessBytes: 8 * gigabyte,
                                                       acceptedLicenseRevision: "rev-1"))
        XCTAssertTrue(accepted.canInstall)
    }

    // MARK: - Warnings

    func testAGGUFImportAlwaysWarnsThatItMayInstallAndStillNotLoad() {
        let report = LocalModelFitReport.make(.init(descriptor: descriptor(),
                                                    availableStorageBytes: 20 * gigabyte,
                                                    availableProcessBytes: 8 * gigabyte))
        XCTAssertTrue(report.warnings.contains(.mayInstallButNotLoad))

        // The MLX path has no unsupported-template failure mode to warn about.
        let mlx = LocalModelFitReport.make(.init(descriptor: descriptor(runtime: .mlx),
                                                  availableStorageBytes: 20 * gigabyte,
                                                  availableProcessBytes: 8 * gigabyte))
        XCTAssertFalse(mlx.warnings.contains(.mayInstallButNotLoad))
    }

    func testMemoryVerdictWarnsButDoesNotBlock() {
        // Weights far beyond what the process may allocate: the files can still be installed,
        // because memory a minute from now is not memory now.
        let report = LocalModelFitReport.make(.init(
            descriptor: descriptor(weightsBytes: 6 * gigabyte, files: [file(bytes: 6 * gigabyte)]),
            availableStorageBytes: 64 * gigabyte,
            availableProcessBytes: gigabyte))
        XCTAssertTrue(report.canInstall)
        XCTAssertTrue(report.warnings.contains { if case .unlikelyToLoad = $0 { return true }
                                                 return false })
        if case .refuse = report.loadVerdict {} else { XCTFail("the load verdict itself must refuse") }
    }

    func testTightHeadroomIsReportedSeparatelyFromRefusal() {
        // Fits, but inside the comfort margin.
        let weights: Int64 = gigabyte
        let available = weights + LocalModelBudget.workingSetBytes(for: .llamaCpp)
            + LocalModelBudget.admissionComfortMarginBytes / 2
        let report = LocalModelFitReport.make(.init(
            descriptor: descriptor(weightsBytes: weights, minimumHeadroomBytes: 0,
                                   files: [file(bytes: weights)]),
            availableStorageBytes: 64 * gigabyte,
            availableProcessBytes: available))
        XCTAssertTrue(report.canInstall)
        XCTAssertTrue(report.warnings.contains { if case .tightMemoryHeadroom = $0 { return true }
                                                 return false })
    }

    func testTheVerdictUsesTheSameReserveTheGGUFLoadPathWillUse() {
        // `minimumHeadroomBytes` is an *additional* reserve for the GGUF runtime, and the load gate
        // adds it. A pre-download verdict that ignored it would promise a load the backend refuses.
        let weights: Int64 = gigabyte
        let reserve: Int64 = 512 * 1024 * 1024
        let available = weights + LocalModelBudget.workingSetBytes(for: .llamaCpp) + reserve - 1
        let report = LocalModelFitReport.make(.init(
            descriptor: descriptor(weightsBytes: weights, minimumHeadroomBytes: reserve,
                                   files: [file(bytes: weights)]),
            availableStorageBytes: 64 * gigabyte,
            availableProcessBytes: available))
        if case .refuse = report.loadVerdict {} else {
            XCTFail("the extra reserve must count against the verdict, as it does at load time")
        }
        XCTAssertEqual(report.estimatedResidentBytes,
                       weights + LocalModelBudget.workingSetBytes(for: .llamaCpp) + reserve)
    }

    func testEveryBlockerAndWarningHasCopy() {
        let blockers: [LocalModelFitReport.Blocker] = [
            .unknownFileSize(relativePath: "m.gguf"), .missingDigest(relativePath: "m.gguf"),
            .unresolvedRevision, .noFiles, .freeSpaceUnreadable,
            .insufficientStorage(neededBytes: 1, freeBytes: 0), .licenseNotAccepted,
        ]
        for blocker in blockers { XCTAssertFalse(blocker.localizedMessage.isEmpty) }

        let warnings: [LocalModelFitReport.Warning] = [
            .mayInstallButNotLoad, .unlikelyToLoad(neededBytes: 1, availableBytes: 0),
            .tightMemoryHeadroom(spareBytes: 1), .contextWillBeClamped(toTokens: 2048),
            .licenseNotSummarized, .storageAfterInstallIsTight(remainingBytes: 1),
        ]
        for warning in warnings { XCTAssertFalse(warning.localizedMessage.isEmpty) }
    }

    // MARK: - Helpers

    private func file(bytes: Int64 = 500_000_000,
                      sha256: String = String(repeating: "a", count: 64)) -> LocalModelFile {
        LocalModelFile(relativePath: "m.gguf", byteCount: bytes, sha256: sha256, role: .weights)
    }

    private func descriptor(runtime: LocalModelRuntime = .llamaCpp,
                            revision: String = String(repeating: "b", count: 40),
                            weightsBytes: Int64 = 500_000_000,
                            minimumHeadroomBytes: Int64 = 0,
                            files: [LocalModelFile]? = nil,
                            license: LocalModelLicenseSummary = .unverified) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: LocalModelID("owner/repo#m.gguf"),
            displayName: "Test model",
            runtime: runtime,
            repositoryID: "owner/repo",
            revision: revision,
            files: files ?? [file(bytes: weightsBytes)],
            quantization: "Q4_K_M",
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: weightsBytes,
            estimatedWorkingBytes: LocalModelBudget.workingSetBytes(for: runtime),
            minimumHeadroomBytes: minimumHeadroomBytes,
            license: license)
    }
}
