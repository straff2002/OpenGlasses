import XCTest
@testable import OpenGlasses

/// The first-run offline-model offer (Plan DH P2).
///
/// Two things are being protected here. One is the capability gate: a phone that would thrash is
/// not shown a local tier at all, and the number that decides it comes from the model catalog
/// rather than being a second opinion invented beside it. The other is the copy — what the user is
/// told before a multi-gigabyte download starts is a promise, and on a device with no Apple
/// Intelligence it is a different promise from the one on a device that has it.
///
/// Nothing here touches the network, the filesystem or a real download: every input is a value.
final class OfflineModelOfferTests: XCTestCase {

    private let modelId = "mlx-community/gemma-4-e2b-it-4bit"
    private let sizeBytes: Int64 = 3_865_470_566   // ~3.6 GB

    private func inputs(ramGB: Double,
                        downloaded: [String] = [],
                        freeDisk: Int64? = 64 * 1_073_741_824) -> OfflineModelOffer.Inputs {
        OfflineModelOffer.Inputs(marketingRAMGB: ramGB,
                                 downloadedModelIds: downloaded,
                                 freeDiskBytes: freeDisk,
                                 expectedSizeBytes: sizeBytes)
    }

    private func verdict(_ inputs: OfflineModelOffer.Inputs) -> OfflineModelOffer.Verdict {
        OfflineModelOffer.verdict(inputs, modelId: modelId)
    }

    // MARK: - Capability gate

    /// The offer's threshold is the offered model's own catalog requirement. If the catalog ever
    /// moves, this fails rather than letting the two drift into disagreeing about which phones
    /// can run the thing.
    @MainActor
    func testTheGateMatchesTheCatalogRequirement() {
        let catalogued = LocalLLMService.recommendedModels.first { $0.id == OfflineModelOffer.modelId }
        XCTAssertNotNil(catalogued, "The offered model is not in the recommended catalog")
        XCTAssertEqual(catalogued?.minimumRAMGB, OfflineModelOffer.minimumRAMGB)
    }

    /// A device below the bar is not offered the download at all — the plan's whole point. It is
    /// told why, and pointed at what does work there.
    func testASmallDeviceIsNotOfferedTheDownload() {
        XCTAssertEqual(verdict(inputs(ramGB: 6)),
                       .deviceTooSmall(requiredRAMGB: OfflineModelOffer.minimumRAMGB))
        XCTAssertEqual(verdict(inputs(ramGB: 4)),
                       .deviceTooSmall(requiredRAMGB: OfflineModelOffer.minimumRAMGB))
    }

    /// Exactly at the bar counts as in. The marketing figure is a ceiling of the reported one, so
    /// an 8 GB phone reports 8 here and a strict `>` would exclude the tier it defines.
    func testTheThresholdIsInclusive() {
        guard case .offer = verdict(inputs(ramGB: OfflineModelOffer.minimumRAMGB)) else {
            return XCTFail("A device exactly at the threshold was refused the offer")
        }
    }

    func testARoomyDeviceIsOfferedTheDownloadWithItsSize() {
        XCTAssertEqual(verdict(inputs(ramGB: 12)), .offer(modelId: modelId, sizeBytes: sizeBytes))
    }

    // MARK: - Storage

    /// Room for the model *and* a margin. Ending a setup flow by filling the user's phone is not a
    /// good first impression, and the snapshot needs space to assemble before it settles.
    func testNoRoomIsRefusedWithBothNumbers() {
        let free: Int64 = 2 * 1_073_741_824
        XCTAssertEqual(verdict(inputs(ramGB: 12, freeDisk: free)),
                       .notEnoughStorage(neededBytes: sizeBytes + OfflineModelOffer.storageMarginBytes,
                                         freeBytes: free))
    }

    /// Just enough for the model but not the margin still counts as no room.
    func testTheMarginIsPartOfTheRequirement() {
        let free = sizeBytes + OfflineModelOffer.storageMarginBytes - 1
        guard case .notEnoughStorage = verdict(inputs(ramGB: 12, freeDisk: free)) else {
            return XCTFail("The storage margin was not required")
        }
        guard case .offer = verdict(inputs(ramGB: 12,
                                           freeDisk: sizeBytes + OfflineModelOffer.storageMarginBytes)) else {
            return XCTFail("Exactly enough room was refused")
        }
    }

    /// An unreadable volume is not a small one. Refusing on a reading we could not take would
    /// block the offer on any device whose free space the OS declines to report.
    func testAnUnreadableVolumeIsNotAReasonToRefuse() {
        guard case .offer = verdict(inputs(ramGB: 12, freeDisk: nil)) else {
            return XCTFail("A device with no storage reading was refused the offer")
        }
    }

    /// The capability gate is checked before storage: a phone that cannot run the model is told
    /// that, not sent to free up space for something that would never work.
    func testTheDeviceReasonWinsOverTheStorageReason() {
        XCTAssertEqual(verdict(inputs(ramGB: 4, freeDisk: 0)),
                       .deviceTooSmall(requiredRAMGB: OfflineModelOffer.minimumRAMGB))
    }

    // MARK: - Already here

    /// A model on disk beats every other answer, including a device the gate would now refuse —
    /// it is already downloaded, so there is nothing to decide.
    func testAModelAlreadyOnDiskIsNeverOfferedAgain() {
        XCTAssertEqual(verdict(inputs(ramGB: 12, downloaded: [modelId])),
                       .alreadyDownloaded(modelId: modelId))
        XCTAssertEqual(verdict(inputs(ramGB: 4, downloaded: [modelId], freeDisk: 0)),
                       .alreadyDownloaded(modelId: modelId))
    }

    /// Some other model being downloaded is not this one.
    func testADifferentDownloadedModelDoesNotSatisfyTheOffer() {
        guard case .offer = verdict(inputs(ramGB: 12, downloaded: ["mlx-community/Qwen2.5-0.5B-Instruct-4bit"])) else {
            return XCTFail("An unrelated downloaded model was mistaken for this one")
        }
    }

    // MARK: - Copy

    /// The size is in the sentence, before anything downloads — the plan's "stated up front".
    func testTheDetailStatesTheSizeOnBothDevices() {
        for available in [true, false] {
            let detail = OfflineModelOffer.detail(appleIntelligenceAvailable: available,
                                                  sizeBytes: sizeBytes)
            XCTAssertTrue(detail.contains("3.6 GB"),
                          "The download's size is not stated: \(detail)")
        }
    }

    /// The two devices are promised different things, and neither promise may be the other's.
    /// On a device that already has an assistant the download is an upgrade; on one that doesn't,
    /// it is what makes the keyless path work at all.
    func testTheCopyDistinguishesAnUpgradeFromAPrerequisite() {
        let upgrade = OfflineModelOffer.detail(appleIntelligenceAvailable: true, sizeBytes: sizeBytes)
        let prerequisite = OfflineModelOffer.detail(appleIntelligenceAvailable: false, sizeBytes: sizeBytes)

        XCTAssertNotEqual(upgrade, prerequisite)
        XCTAssertTrue(upgrade.lowercased().contains("already works"),
                      "The upgrade wording must say the assistant works now: \(upgrade)")
        XCTAssertFalse(prerequisite.lowercased().contains("already works"),
                       "A device with no on-device assistant must not be told it has one: \(prerequisite)")
    }

    /// The refusal names the limit and a way forward. A dead end with no route out is where a
    /// first run gets abandoned.
    func testTheRefusalNamesTheLimitAndTheAlternative() {
        let detail = OfflineModelOffer.deviceTooSmallDetail(requiredRAMGB: 8)
        XCTAssertTrue(detail.contains("8 GB"), detail)
        XCTAssertTrue(detail.lowercased().contains("cloud"),
                      "The refusal has to say what does work on this phone: \(detail)")
    }

    /// The honest bit about leaving mid-download: it keeps going, and it resumes.
    func testTheInProgressCopySaysTheDownloadSurvivesLeavingTheFlow() {
        let text = OfflineModelOffer.inProgressDetail.lowercased()
        XCTAssertTrue(text.contains("keeps going"), OfflineModelOffer.inProgressDetail)
        XCTAssertTrue(text.contains("picks up where it left off"), OfflineModelOffer.inProgressDetail)
    }

    func testTheStorageShortfallStatesBothNumbers() {
        let detail = OfflineModelOffer.notEnoughStorageDetail(
            neededBytes: 4 * 1_073_741_824, freeBytes: 1_073_741_824)
        XCTAssertTrue(detail.contains("4.0 GB"), detail)
        XCTAssertTrue(detail.contains("1.0 GB"), detail)
    }

    func testSizesReadTheSameEverywhere() {
        XCTAssertEqual(OfflineModelOffer.formattedSize(3_865_470_566), "3.6 GB")
        XCTAssertEqual(OfflineModelOffer.formattedSize(1_073_741_824), "1.0 GB")
        XCTAssertEqual(OfflineModelOffer.formattedSize(367_001_600), "350 MB")
    }

    /// The offer configures the provider it belongs to. If these two ever disagree the flow would
    /// download one model and activate another.
    func testTheOfferedModelIsTheOneTheLocalProviderDefaultsTo() {
        XCTAssertEqual(OfflineModelOffer.modelId, LLMProvider.local.defaultModel)
    }
}
