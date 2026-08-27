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
        /// Already on disk from a previous run — there is nothing to download.
        case alreadyDownloaded(modelId: String)
        /// The device could run it, but there is not room for it right now.
        case notEnoughStorage(neededBytes: Int64, freeBytes: Int64)
        /// This phone is below the bar. Say so plainly and point at the cloud providers.
        case deviceTooSmall(requiredRAMGB: Double)
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
        /// Stated download size, or nil for an id the catalog doesn't know.
        var expectedSizeBytes: Int64?

        init(marketingRAMGB: Double,
             downloadedModelIds: [String],
             freeDiskBytes: Int64?,
             expectedSizeBytes: Int64?) {
            self.marketingRAMGB = marketingRAMGB
            self.downloadedModelIds = downloadedModelIds
            self.freeDiskBytes = freeDiskBytes
            self.expectedSizeBytes = expectedSizeBytes
        }
    }

    /// Decide, in the order the reasons matter: a model already here beats every other answer,
    /// then the capability gate, then room to put it.
    static func verdict(_ inputs: Inputs, modelId: String) -> Verdict {
        if inputs.downloadedModelIds.contains(modelId) {
            return .alreadyDownloaded(modelId: modelId)
        }
        let required = minimumRAMGB
        guard inputs.marketingRAMGB >= required else {
            return .deviceTooSmall(requiredRAMGB: required)
        }
        let size = inputs.expectedSizeBytes ?? 0
        if let free = inputs.freeDiskBytes, free < size + storageMarginBytes {
            return .notEnoughStorage(neededBytes: size + storageMarginBytes, freeBytes: free)
        }
        return .offer(modelId: modelId, sizeBytes: size)
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

    /// The refusal. It names the device's limit and where to go instead, because a dead end with
    /// no route out is how a first run gets abandoned.
    static func deviceTooSmallDetail(requiredRAMGB: Double) -> String {
        "This iPhone has less than \(Int(requiredRAMGB)) GB of memory, which isn't enough to run a "
        + "model on-device. Choose one of the providers instead — those run in the cloud and work "
        + "on any iPhone."
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
