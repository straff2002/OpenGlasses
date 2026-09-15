import XCTest
@testable import OpenGlasses

/// Plan FC P0 — the catalog's model sizes are measured facts, and everything that quotes a size
/// quotes those bytes.
///
/// The defect this pins: sizes used to be authored as display strings and parsed back with a
/// gibibyte multiplier, so every entry was a few percent out and `SmolVLM2-2.2B-Instruct-mlx` was
/// understated threefold — labelled 1.5 GB for a 4.5 GB download. A phone was offered that model
/// with 3 GB free, and the download-progress bar was measuring against a number that could never
/// arrive.
///
/// The fixture below is the provenance, repeated independently of the catalog: every figure was
/// read from the Hugging Face model API (`/api/models/<repository>?blobs=true`) on 2026-09-15,
/// summing the size of every file listed at the recorded commit. A test that asked the catalog
/// what the catalog believes would agree with any mistake in it, so these are typed out.
///
/// Nothing here touches the network — the numbers are the fixture, and the measurement that
/// produced them is a recorded act, not a step of the test run.
final class LocalModelVerifiedSizeTests: XCTestCase {

    private struct Measured {
        let id: String
        let revision: String
        let totalBytes: Int64
        let weightsBytes: Int64
        let fileCount: Int
        let display: String
    }

    private let measured: [Measured] = [
        Measured(id: "mlx-community/gemma-4-e2b-it-4bit",
                 revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
                 totalBytes: 3_583_088_661, weightsBytes: 3_550_670_554,
                 fileCount: 10, display: "3.6 GB"),
        Measured(id: "mlx-community/gemma-4-e4b-it-4bit",
                 revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
                 totalBytes: 5_179_241_512, weightsBytes: 5_146_800_534,
                 fileCount: 10, display: "5.2 GB"),
        Measured(id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
                 revision: "844516024a1c4400d34489b89ee067d794e432ed",
                 totalBytes: 4_498_568_233, weightsBytes: 4_493_651_795,
                 fileCount: 14, display: "4.5 GB"),
        Measured(id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
                 revision: "fa57db46815177fbdfd65cc85a2b3416a8332268",
                 totalBytes: 1_019_926_804, weightsBytes: 1_015_023_993,
                 fileCount: 14, display: "1.0 GB"),
        Measured(id: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
                 revision: "04efa23776ce61ec34ec95ec34c859854c89542b",
                 totalBytes: 1_601_123_632, weightsBytes: 1_583_152_892,
                 fileCount: 10, display: "1.6 GB"),
        Measured(id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                 revision: "4f83f8f146fdf28b512a06562b671d7af4fab457",
                 totalBytes: 1_747_851_324, weightsBytes: 1_736_293_090,
                 fileCount: 11, display: "1.7 GB"),
        Measured(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                 revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
                 totalBytes: 289_601_064, weightsBytes: 278_064_920,
                 fileCount: 11, display: "0.29 GB"),
    ]

    private func entry(_ id: String) throws -> LocalModelCatalog.Entry {
        try XCTUnwrap(LocalModelCatalog.entry(for: LocalModelID(id)), "\(id) left the catalog")
    }

    // MARK: - The measured snapshot

    func testEveryCatalogEntryCarriesItsMeasuredSnapshot() throws {
        XCTAssertEqual(LocalModelCatalog.entries.map(\.id.rawValue), measured.map(\.id),
                       "the catalog's ids or their order changed — a saved selection depends on both")
        for fact in measured {
            let snapshot = try entry(fact.id).snapshot
            XCTAssertEqual(snapshot.totalBytes, fact.totalBytes, "\(fact.id) download total")
            XCTAssertEqual(snapshot.weightsBytes, fact.weightsBytes, "\(fact.id) weights")
            XCTAssertEqual(snapshot.fileCount, fact.fileCount, "\(fact.id) file count")
            XCTAssertEqual(snapshot.revision, fact.revision, "\(fact.id) measured revision")
            XCTAssertEqual(snapshot.verifiedOn, "2026-09-15", "\(fact.id) verification date")
        }
    }

    /// The headline correction, stated as its own failure so a regression cannot hide inside a
    /// table comparison: the understated label is gone and the real one is threefold larger.
    func testTheVisionModelIsNoLongerLabelledAtAThirdOfItsSize() throws {
        let smol = try entry("mlx-community/SmolVLM2-2.2B-Instruct-mlx")
        XCTAssertNotEqual(smol.estimatedSize, "1.5 GB", "the understated label is back")
        XCTAssertEqual(smol.estimatedSize, "4.5 GB")
        XCTAssertGreaterThan(smol.snapshot.totalBytes, 4_000_000_000)
    }

    // MARK: - One number, everywhere it is quoted

    @MainActor
    func testExpectedDownloadBytesAreTheSnapshotTotals() throws {
        for fact in measured {
            XCTAssertEqual(LocalLLMService.expectedDownloadBytes(for: fact.id), fact.totalBytes,
                           "\(fact.id) download estimate")
        }
    }

    @MainActor
    func testAnUncataloguedIDHasNoSizeRatherThanAGuessedOne() {
        for unknown in ["someone/custom-model-4bit", "mlx-community/gemma-2-2b-it-4bit", ""] {
            XCTAssertNil(LocalLLMService.expectedDownloadBytes(for: unknown),
                         "\(unknown) must have no expected size at all")
            XCTAssertNil(LocalModelCatalog.downloadBytes(for: LocalModelID(unknown)))
        }
        // And a descriptor built for one claims no weights either — an unknown size is unknown in
        // both directions, never zero-as-a-measurement.
        let legacy = LocalModelCatalog.compatibilityDescriptor(
            forLegacyMLXModelID: "mlx-community/gemma-2-2b-it-4bit")
        XCTAssertEqual(legacy.estimatedWeightsBytes, 0)
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(0), "Unknown size",
                       "an absent measurement must not be drawn as 0.0 GB")
    }

    func testTheDisplayedSizeIsDerivedFromTheBytes() throws {
        for fact in measured {
            let shown = try entry(fact.id).estimatedSize
            XCTAssertEqual(shown, fact.display, "\(fact.id) display size")
            XCTAssertEqual(shown, LocalModelCatalog.formattedDownloadSize(fact.totalBytes),
                           "\(fact.id) display size is not derived from its bytes")
        }
    }

    /// The formatting rule in full, including the places it changes shape.
    func testTheSizeFormatterRules() {
        // A gigabyte and up: one decimal place.
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(4_498_568_233), "4.5 GB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(1_019_926_804), "1.0 GB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(1_000_000_000), "1.0 GB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(5_179_241_512), "5.2 GB")
        // Just under: still rounds up into gigabytes rather than reading "0.99 GB" at 1.0 GB.
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(996_000_000), "1.0 GB")
        // Below that: two decimals, so a small model is not flattened to "0.3 GB".
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(289_601_064), "0.29 GB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(994_000_000), "0.99 GB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(150_000_000), "0.15 GB")
        // Genuinely small: megabytes, decimal like everything else here.
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(99_000_000), "99 MB")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(1_000_000), "1 MB")
        // Not a size.
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(0), "Unknown size")
        XCTAssertEqual(LocalModelCatalog.formattedDownloadSize(-1), "Unknown size")
    }

    // MARK: - Download, weights and headroom are three separate facts

    func testWeightsAreTheSafetensorsAndTheDownloadIsTheWholeSnapshot() throws {
        for fact in measured {
            let catalogued = try entry(fact.id)
            XCTAssertEqual(catalogued.descriptor.estimatedWeightsBytes, fact.weightsBytes,
                           "\(fact.id) resident weights must be the checkpoint, not the download")
            XCTAssertLessThan(catalogued.descriptor.estimatedWeightsBytes,
                              catalogued.snapshot.totalBytes,
                              "\(fact.id): the snapshot carries tokenizer and configs too")
            XCTAssertEqual(catalogued.descriptor.estimatedWorkingBytes,
                           MemoryHeadroom.workingOverheadBytes,
                           "\(fact.id) working overhead is the one shared constant")
            XCTAssertEqual(catalogued.descriptor.minimumHeadroomBytes,
                           fact.weightsBytes + MemoryHeadroom.workingOverheadBytes,
                           "\(fact.id) headroom must derive from the measured weights")
        }
    }

    /// The guard the plan asks for: a future edit that drops a byte count or a provenance line
    /// fails here rather than shipping a zero that reads as a measurement.
    func testNoEntryMayShipWithoutBytesOrProvenance() {
        for entry in LocalModelCatalog.entries {
            let id = entry.id.rawValue
            XCTAssertGreaterThan(entry.snapshot.totalBytes, 0, "\(id) has no download size")
            XCTAssertGreaterThan(entry.snapshot.weightsBytes, 0, "\(id) has no weights size")
            XCTAssertGreaterThan(entry.snapshot.fileCount, 0, "\(id) has no file count")
            XCTAssertFalse(entry.snapshot.revision.isEmpty, "\(id) has no measured revision")
            XCTAssertNotEqual(entry.snapshot.revision, LocalModelDescriptor.floatingRevision,
                              "\(id): the sentinel is not provenance")
            XCTAssertFalse(entry.snapshot.verifiedOn.isEmpty, "\(id) has no verification date")
            XCTAssertNotEqual(entry.estimatedSize, "Unknown size", "\(id) shows no size")
        }
    }

    /// Recording the revision the bytes were measured at must not be mistaken for pinning the
    /// download to it. The MLX path still fetches the repository's default branch, so the
    /// descriptor stays unpinned and the acquisition pipeline keeps refusing it — changing that
    /// belongs to the work that can actually request a revision.
    func testRecordedRevisionsDoNotPinTheDescriptors() {
        for entry in LocalModelCatalog.entries {
            XCTAssertEqual(entry.descriptor.revision, LocalModelDescriptor.floatingRevision,
                           "\(entry.id.rawValue) descriptor was pinned by the metadata fix")
            XCTAssertFalse(entry.descriptor.isRevisionPinned)
            XCTAssertTrue(entry.descriptor.installationFaults().contains(.unpinnedRevision))
        }
    }

    // MARK: - What the corrected bytes change downstream

    /// The decision the wrong number was making wrongly. A 6 GB iPhone with 3 GB free is offered
    /// SmolVLM2 2.2B as the smaller-device fallback; at the label's old 1.5 GB that download
    /// "fitted" in 3 GB, and at its real size it does not.
    func testAPhoneWithThreeGigabytesFreeIsToldTheVisionModelDoesNotFit() throws {
        let smol = try entry("mlx-community/SmolVLM2-2.2B-Instruct-mlx")
        let free: Int64 = 3_000_000_000
        let inputs = OfflineModelOffer.Inputs(
            marketingRAMGB: 6,
            downloadedModelIds: [],
            freeDiskBytes: free,
            expectedSizeBytes: LocalModelCatalog.downloadBytes(
                for: LocalModelID("mlx-community/gemma-4-e2b-it-4bit")))
        let needed = smol.snapshot.totalBytes + OfflineModelOffer.storageMarginBytes

        XCTAssertEqual(OfflineModelOffer.verdict(inputs, modelId: "mlx-community/gemma-4-e2b-it-4bit"),
                       .notEnoughStorage(neededBytes: needed, freeBytes: free))
        // The contrast that makes this a regression test rather than an arithmetic restatement.
        let understated: Int64 = 1_610_612_736   // what "1.5 GB" parsed to before the correction
        XCTAssertGreaterThan(free, understated + OfflineModelOffer.storageMarginBytes,
                             "the old label would have called this phone roomy enough")
    }

    /// Correcting a size changes no identity: every catalogued id still resolves to itself, and a
    /// model a user already selected or installed is untouched by this fix.
    func testCorrectingSizesPreservesEveryInstalledIdentity() {
        for fact in measured {
            let resolved = LocalModelCatalog.resolveDescriptor(forLegacyMLXModelID: fact.id)
            XCTAssertEqual(resolved.id, LocalModelID(fact.id))
            XCTAssertEqual(resolved.runtime, .mlx)
        }
        // Including one that was retired from the list before this plan: still resolvable, still
        // MLX, still named by the id it was installed under.
        let retired = LocalModelCatalog.resolveDescriptor(
            forLegacyMLXModelID: "mlx-community/gemma-2-2b-it-4bit")
        XCTAssertEqual(retired.id.rawValue, "mlx-community/gemma-2-2b-it-4bit")
        XCTAssertEqual(retired.runtime, .mlx)
    }
}
