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
/// The third is the fallback: only the primary model carries an 8 GB floor, and a phone under it
/// was being told no model runs on-device at all — untrue on any iPhone that can hold SmolVLM2.
/// The tests below pin which model such a phone is offered, and that the fallback is subject to
/// every check the primary is.
///
/// Nothing here touches the network, the filesystem or a real download: every input is a value.
final class OfflineModelOfferTests: XCTestCase {

    private let modelId = "mlx-community/gemma-4-e2b-it-4bit"
    private let sizeBytes: Int64 = 3_865_470_566   // ~3.6 GB

    /// What a phone under the primary's floor should be offered: the first catalog entry after
    /// the primary whose RAM floor it clears.
    private let fallbackId = "mlx-community/SmolVLM2-2.2B-Instruct-mlx"
    private let fallbackSize: Int64 = 1_610_612_736   // 1.5 GB

    private func inputs(ramGB: Double,
                        downloaded: [String] = [],
                        freeDisk: Int64? = 64 * 1_073_741_824,
                        catalog: [OfflineModelOffer.Candidate] = OfflineModelOffer.catalogCandidates)
        -> OfflineModelOffer.Inputs {
        OfflineModelOffer.Inputs(marketingRAMGB: ramGB,
                                 downloadedModelIds: downloaded,
                                 freeDiskBytes: freeDisk,
                                 expectedSizeBytes: sizeBytes,
                                 catalog: catalog)
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

    /// A device below the bar is not offered the *primary* model — but it is not left with
    /// nothing either. It gets the first catalog entry that actually runs there, and is told the
    /// full-size one needs more memory than it has.
    func testASmallDeviceIsOfferedTheSmallerModelInstead() {
        XCTAssertEqual(verdict(inputs(ramGB: 6)),
                       .offerSmaller(modelId: fallbackId,
                                     sizeBytes: fallbackSize,
                                     primaryRequiredRAMGB: OfflineModelOffer.minimumRAMGB))
        XCTAssertEqual(verdict(inputs(ramGB: 4)),
                       .offerSmaller(modelId: fallbackId,
                                     sizeBytes: fallbackSize,
                                     primaryRequiredRAMGB: OfflineModelOffer.minimumRAMGB))
    }

    /// The fallback is the first catalog entry, in picker order, that fits — not the smallest, not
    /// an arbitrary one. Excluding the primary and the entry with the even higher floor, that is
    /// SmolVLM2 2.2B on a 6 GB iPhone.
    @MainActor
    func testTheFallbackIsTheFirstCatalogEntryThatFits() {
        let expected = LocalModelCatalog.entries.first {
            $0.id.rawValue != modelId && $0.minimumRAMGB <= 6
        }
        XCTAssertEqual(expected?.id.rawValue, fallbackId)
        XCTAssertEqual(fallbackId, "mlx-community/SmolVLM2-2.2B-Instruct-mlx")
        XCTAssertEqual(LocalLLMService.expectedDownloadBytes(for: fallbackId), fallbackSize)
    }

    /// `deviceTooSmall` survives, for the one device that deserves it: nothing in the catalog
    /// fits. Constructed by handing the pure decision a catalog whose every entry has a floor
    /// above the device, which the shipping catalog (full of floorless entries) cannot express.
    func testADeviceBelowEveryFloorIsStillToldPlainly() {
        let unreachable = [
            OfflineModelOffer.Candidate(modelId: "big/one", minimumRAMGB: 12, sizeBytes: 1),
            OfflineModelOffer.Candidate(modelId: "big/two", minimumRAMGB: 16, sizeBytes: 1),
        ]
        XCTAssertEqual(verdict(inputs(ramGB: 6, catalog: unreachable)),
                       .deviceTooSmall(requiredRAMGB: OfflineModelOffer.minimumRAMGB))
    }

    /// The primary is never offered as its own fallback, however the catalog is ordered.
    func testThePrimaryIsNeverOfferedAsTheFallback() {
        let onlyPrimary = [
            OfflineModelOffer.Candidate(modelId: modelId, minimumRAMGB: 0, sizeBytes: sizeBytes)
        ]
        XCTAssertEqual(verdict(inputs(ramGB: 6, catalog: onlyPrimary)),
                       .deviceTooSmall(requiredRAMGB: OfflineModelOffer.minimumRAMGB))
    }

    // MARK: - The fallback is subject to every check the primary is

    /// A fallback already on disk is not downloaded again — and the size checked against disk is
    /// the fallback's own, not the 3.6 GB primary's, which would refuse a 1.5 GB download on a
    /// phone with room for it.
    func testAFallbackAlreadyOnDiskIsNotOfferedAgain() {
        XCTAssertEqual(verdict(inputs(ramGB: 6, downloaded: [fallbackId])),
                       .alreadyDownloaded(modelId: fallbackId))
    }

    /// Any fitting model on disk counts, wherever it sits in the order — offering a different one
    /// would be asking a 6 GB phone for a second copy it does not need.
    func testAFittingModelFurtherDownTheListCountsAsAlreadyDownloaded() {
        let qwen = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        XCTAssertEqual(verdict(inputs(ramGB: 6, downloaded: [qwen])),
                       .alreadyDownloaded(modelId: qwen))
    }

    /// Storage is measured against what is actually being fetched. Free space between the
    /// fallback's requirement and the primary's is enough here and would not have been if the
    /// primary's size leaked into this branch.
    func testTheFallbackStorageCheckUsesTheFallbacksOwnSize() {
        let tooLittle = fallbackSize + OfflineModelOffer.storageMarginBytes - 1
        XCTAssertEqual(verdict(inputs(ramGB: 6, freeDisk: tooLittle)),
                       .notEnoughStorage(neededBytes: fallbackSize + OfflineModelOffer.storageMarginBytes,
                                         freeBytes: tooLittle))

        // Exactly enough for the fallback — far short of the primary's 3.6 GB — is still a yes.
        let justEnough = fallbackSize + OfflineModelOffer.storageMarginBytes
        XCTAssertLessThan(justEnough, sizeBytes + OfflineModelOffer.storageMarginBytes)
        XCTAssertEqual(verdict(inputs(ramGB: 6, freeDisk: justEnough)),
                       .offerSmaller(modelId: fallbackId,
                                     sizeBytes: fallbackSize,
                                     primaryRequiredRAMGB: OfflineModelOffer.minimumRAMGB))
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

    /// The capability gate is checked before storage: a phone that cannot run *any* model is told
    /// that, not sent to free up space for something that would never work.
    func testTheDeviceReasonWinsOverTheStorageReason() {
        let unreachable = [
            OfflineModelOffer.Candidate(modelId: "big/one", minimumRAMGB: 12, sizeBytes: 1)
        ]
        XCTAssertEqual(verdict(inputs(ramGB: 4, freeDisk: 0, catalog: unreachable)),
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
        // It is now reached only when the *smallest* model is out of reach too, and must say so
        // rather than implying the 8 GB number alone is what excluded this phone.
        XCTAssertTrue(detail.lowercased().contains("smallest"),
                      "The refusal must say nothing in the catalog fits: \(detail)")
    }

    /// The smaller offer's copy is honest in all three directions: the memory the full-size model
    /// wanted, that this one is smaller, and what it costs to download.
    func testTheSmallerOfferStatesTheReasonAndTheSize() {
        let detail = OfflineModelOffer.offerSmallerDetail(primaryRequiredRAMGB: 8,
                                                          sizeBytes: fallbackSize)
        XCTAssertTrue(detail.contains("8 GB"),
                      "The full-size model's requirement is not named: \(detail)")
        XCTAssertTrue(detail.contains("1.5 GB"),
                      "The smaller download's size is not stated: \(detail)")
        XCTAssertTrue(detail.lowercased().contains("smaller"),
                      "The user must not think this is the full-size model: \(detail)")
        XCTAssertFalse(detail.lowercased().contains("isn't enough to run a model on-device"),
                       "The old dead-end claim must not survive: \(detail)")
    }

    /// The smaller row's title cannot read as the full-size one's, or the whole point is lost.
    func testTheSmallerTitleIsDistinct() {
        XCTAssertTrue(OfflineModelOffer.smallerTitle.lowercased().contains("smaller"),
                      OfflineModelOffer.smallerTitle)
        for available in [true, false] {
            XCTAssertNotEqual(OfflineModelOffer.smallerTitle,
                              OfflineModelOffer.title(appleIntelligenceAvailable: available))
        }
    }

    // MARK: - The shared RAM rule

    /// The rounding is the whole reason this helper exists. An 8 GB iPhone reports about 7.5 GB,
    /// and the raw byte comparison the model manager used to do hid the Download button on
    /// precisely the hardware an 8 GB floor was written to include.
    func testTheRAMFloorIsMeasuredAgainstTheNominalSize() {
        let eightGB = (7.5 as Double).rounded(.up)
        XCTAssertTrue(LocalLLMService.deviceMeetsRAMFloor(8, marketingRAMGB: eightGB),
                      "An 8 GB iPhone (reports ~7.5 GB) was excluded by its own tier's floor")

        let sixGB = (5.9 as Double).rounded(.up)
        XCTAssertFalse(LocalLLMService.deviceMeetsRAMFloor(8, marketingRAMGB: sixGB),
                       "A 6 GB iPhone was let past an 8 GB floor")

        // A floor of zero is no restriction at all, on any device.
        XCTAssertTrue(LocalLLMService.deviceMeetsRAMFloor(0, marketingRAMGB: sixGB))
        XCTAssertTrue(LocalLLMService.deviceMeetsRAMFloor(0, marketingRAMGB: 1))
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
