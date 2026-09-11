import Foundation

/// Whether first run should offer to download the on-device model, and what to say about it.
///
/// The keyless path resolves legacy key → Apple Intelligence *if the device has it* → a
/// downloaded on-device model → nothing. Apple Intelligence is device-gated, so on a large slice
/// of perfectly capable iPhones that chain has no on-device brain to land on unless a model is
/// actually on disk — and nothing in the first-run flow ever put one there. This is the offer
/// that does, and the rules that decide whether making it would be honest.
///
/// Pure: RAM, disk and what is already downloaded come in as values, so both tiers of every
/// decision are exercised headlessly rather than only on whatever phone happens to be plugged in.
enum OfflineModelOffer {

    /// The model the offer downloads — the same id the local provider defaults to, so the offer
    /// and the provider it configures can never drift apart.
    static var modelId: String { LLMProvider.local.defaultModel }

    /// Marketing RAM (GB) at or above which the offer is made at all.
    ///
    /// This is the offered model's *own* catalog requirement, not a second number invented here —
    /// `testTheGateMatchesTheCatalogRequirement` pins the two together, so the model list stays
    /// the single place a tier line is drawn. Below it the model would thrash, or fail to load
    /// outright, and the honest answer on that phone is a cloud provider rather than a local tier
    /// that never finishes a turn. Conservative on purpose: measurement on real hardware can
    /// lower confidence in a device, so a device excluded here is never worse off than one shown
    /// a tier that doesn't work.
    static let minimumRAMGB: Double = 8

    /// The download's stated size, from the catalog. Nil only for an id that is not in it.
    @MainActor
    static var expectedSizeBytes: Int64? { LocalLLMService.expectedDownloadBytes(for: modelId) }

    /// Free space the download needs *beyond* the model itself: the snapshot is assembled from
    /// temporary files before it settles, and finishing a setup flow by filling the user's phone
    /// is not a good first impression.
    static let storageMarginBytes: Int64 = 1_073_741_824   // 1 GB

    /// What first run should do about the offline model on this device.
    enum Verdict: Equatable {
        /// Offer it. The size is stated before anything starts downloading.
        case offer(modelId: String, sizeBytes: Int64)
        /// This phone is under the primary model's floor, but the catalog has something that does
        /// fit. Offer that instead, and say plainly that it is the smaller one — a 6 GB iPhone is
        /// not a device with no on-device option, and telling it so was simply untrue.
        case offerSmaller(modelId: String, sizeBytes: Int64, primaryRequiredRAMGB: Double)
        /// Already on disk from a previous run — there is nothing to download.
        case alreadyDownloaded(modelId: String)
        /// The device could run it, but there is not room for it right now.
        case notEnoughStorage(neededBytes: Int64, freeBytes: Int64)
        /// Nothing in the catalog runs on this phone — not the primary, not the smallest entry.
        /// Say so plainly and point at the cloud providers.
        case deviceTooSmall(requiredRAMGB: Double)
    }

    /// A catalog entry reduced to the three facts this decision needs. Keeps the fallback search
    /// a value computation, so "what would a 6 GB iPhone be offered?" is a headless question.
    struct Candidate: Equatable {
        var modelId: String
        /// Minimum device RAM (GB) to run it. 0 = no floor.
        var minimumRAMGB: Double
        var sizeBytes: Int64

        init(modelId: String, minimumRAMGB: Double, sizeBytes: Int64) {
            self.modelId = modelId
            self.minimumRAMGB = minimumRAMGB
            self.sizeBytes = sizeBytes
        }
    }

    /// The catalog in picker order, as candidates. The order is the contract: the fallback is the
    /// first entry that fits, so the list stays the one place the preference is expressed.
    static var catalogCandidates: [Candidate] {
        LocalModelCatalog.entries.map {
            Candidate(modelId: $0.id.rawValue,
                      minimumRAMGB: $0.minimumRAMGB,
                      sizeBytes: LocalLLMService.expectedDownloadBytes(for: $0.id.rawValue) ?? 0)
        }
    }

    /// Everything the decision depends on, as values.
    struct Inputs: Equatable {
        /// Nominal device RAM (`LocalLLMService.marketingRAMGB`).
        var marketingRAMGB: Double
        /// Model ids already on disk.
        var downloadedModelIds: [String]
        /// Free disk usable for the download, or nil when it can't be read (then storage is not
        /// used as a reason to refuse — an unreadable volume is not a small one).
        var freeDiskBytes: Int64?
        /// Stated download size of the primary model, or nil for an id the catalog doesn't know.
        var expectedSizeBytes: Int64?
        /// What the fallback may be drawn from, in preference order. Defaults to the shipping
        /// catalog; a test supplies its own to construct devices the real catalog cannot.
        var catalog: [Candidate]

        init(marketingRAMGB: Double,
             downloadedModelIds: [String],
             freeDiskBytes: Int64?,
             expectedSizeBytes: Int64?,
             catalog: [Candidate] = OfflineModelOffer.catalogCandidates) {
            self.marketingRAMGB = marketingRAMGB
            self.downloadedModelIds = downloadedModelIds
            self.freeDiskBytes = freeDiskBytes
            self.expectedSizeBytes = expectedSizeBytes
            self.catalog = catalog
        }
    }

    /// Decide, in the order the reasons matter: a model already here beats every other answer,
    /// then the capability gate, then room to put it.
    ///
    /// The gate no longer ends the conversation. Only the *primary* model carries an 8 GB floor;
    /// most of the catalog carries none at all, and a phone under the floor was being told it
    /// could not run a model on-device when several would have run there fine. So a device below
    /// the primary's bar falls through to the first catalog entry it can actually run, with its
    /// own size and its own storage check — and `deviceTooSmall` is kept for the only case that
    /// deserves it, a device nothing in the catalog fits.
    static func verdict(_ inputs: Inputs, modelId: String) -> Verdict {
        if inputs.downloadedModelIds.contains(modelId) {
            return .alreadyDownloaded(modelId: modelId)
        }
        let required = minimumRAMGB
        guard inputs.marketingRAMGB >= required else {
            return smallerDeviceVerdict(inputs, excluding: modelId, primaryRequiredRAMGB: required)
        }
        let size = inputs.expectedSizeBytes ?? 0
        if let shortfall = storageShortfall(inputs, sizeBytes: size) { return shortfall }
        return .offer(modelId: modelId, sizeBytes: size)
    }

    /// What to offer a phone under the primary's floor. Everything the primary path checks is
    /// checked again here against the fallback's own numbers — a smaller model is still a download
    /// that needs room, and one already on disk is still nothing to download.
    private static func smallerDeviceVerdict(_ inputs: Inputs,
                                             excluding primaryId: String,
                                             primaryRequiredRAMGB: Double) -> Verdict {
        let fitting = inputs.catalog.filter {
            $0.modelId != primaryId && fits($0.minimumRAMGB, marketingRAMGB: inputs.marketingRAMGB)
        }
        // A fitting model already on disk wins, wherever it sits in the order — there is nothing
        // to download, and offering a different one would be asking for a second copy.
        if let here = fitting.first(where: { inputs.downloadedModelIds.contains($0.modelId) }) {
            return .alreadyDownloaded(modelId: here.modelId)
        }
        guard let fallback = fitting.first else {
            return .deviceTooSmall(requiredRAMGB: primaryRequiredRAMGB)
        }
        if let shortfall = storageShortfall(inputs, sizeBytes: fallback.sizeBytes) { return shortfall }
        return .offerSmaller(modelId: fallback.modelId,
                             sizeBytes: fallback.sizeBytes,
                             primaryRequiredRAMGB: primaryRequiredRAMGB)
    }

    /// One RAM rule for the whole app, expressed against the nominal figure rather than the
    /// reported one. See `LocalLLMService.deviceMeetsRAMFloor(_:marketingRAMGB:)`.
    private static func fits(_ minimumRAMGB: Double, marketingRAMGB: Double) -> Bool {
        LocalLLMService.deviceMeetsRAMFloor(minimumRAMGB, marketingRAMGB: marketingRAMGB)
    }

    /// Room for the download plus the margin, or the refusal that says both numbers.
    private static func storageShortfall(_ inputs: Inputs, sizeBytes: Int64) -> Verdict? {
        let needed = sizeBytes + storageMarginBytes
        guard let free = inputs.freeDiskBytes, free < needed else { return nil }
        return .notEnoughStorage(neededBytes: needed, freeBytes: free)
    }

    /// Free disk usable for the download. `importantUsage` rather than raw free space, so iOS's
    /// purgeable reserve counts — the same reading the recording path takes before it starts
    /// writing, for the same reason.
    static func freeDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The live reading of this device, for the flow to hand to ``verdict(_:modelId:)``.
    @MainActor
    static func currentInputs() -> Inputs {
        Inputs(marketingRAMGB: LocalLLMService.marketingRAMGB,
               downloadedModelIds: LocalLLMService.downloadedModelIdsOnDisk(),
               freeDiskBytes: freeDiskBytes(),
               expectedSizeBytes: expectedSizeBytes)
    }

    // MARK: - Copy
    //
    // The wording turns on one thing: whether this phone *already* has an assistant. On a device
    // with Apple Intelligence the download is an upgrade and must not read as a prerequisite — the
    // user can finish setup and start talking right now. On every other device it is the thing
    // that makes the keyless path work at all, and saying otherwise would be a promise the app
    // cannot keep.

    static func title(appleIntelligenceAvailable: Bool) -> String {
        appleIntelligenceAvailable ? "Add an offline model" : "Download the offline model"
    }

    static func detail(appleIntelligenceAvailable: Bool, sizeBytes: Int64) -> String {
        let size = formattedSize(sizeBytes)
        if appleIntelligenceAvailable {
            return "The assistant already works on this iPhone. A \(size) download adds a model "
                + "that keeps working with no network at all. It appears alongside your other "
                + "models in Settings once it's ready."
        }
        return "A \(size) download is what makes this path work on your iPhone — no account, no "
            + "key. The assistant starts answering on-device as soon as it's finished."
    }

    /// Said while a download is running, so leaving the flow is not a leap of faith.
    static let inProgressDetail =
        "You can carry on setting up. The download keeps going in the background and picks up "
        + "where it left off if it's interrupted."

    static let alreadyDownloadedDetail =
        "An offline model is already on this iPhone, so the assistant works with no network."

    /// The smaller model's title. Distinct from the primary's, because the one thing this row
    /// must not do is let a user believe they are getting the full-size model.
    static let smallerTitle = "Download a smaller offline model"

    /// The honest version of what used to be a flat refusal: name the memory the full-size model
    /// wants, say this iPhone gets a smaller one instead, and state what that one costs to fetch.
    static func offerSmallerDetail(primaryRequiredRAMGB: Double, sizeBytes: Int64) -> String {
        "The full-size model needs \(Int(primaryRequiredRAMGB)) GB of memory, which is more than "
        + "this iPhone has. A smaller model runs here instead — a \(formattedSize(sizeBytes)) "
        + "download, and the assistant still answers on-device with no network and no account."
    }

    /// The refusal. It names the device's limit and where to go instead, because a dead end with
    /// no route out is how a first run gets abandoned.
    static func deviceTooSmallDetail(requiredRAMGB: Double) -> String {
        "This iPhone doesn't have enough memory for any of the on-device models — the smallest "
        + "one still needs more than it has, and the full-size model needs \(Int(requiredRAMGB)) GB. "
        + "Choose one of the providers instead — those run in the cloud and work on any iPhone."
    }

    static func notEnoughStorageDetail(neededBytes: Int64, freeBytes: Int64) -> String {
        "The offline model needs about \(formattedSize(neededBytes)) free and there's "
        + "\(formattedSize(freeBytes)) left. Free up some space and it can be downloaded later "
        + "from Settings."
    }

    /// One size format for every string above, so "3.6 GB" reads the same everywhere.
    static func formattedSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
