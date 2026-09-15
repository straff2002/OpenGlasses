import Foundation

/// The versioned bundled catalog of local models (Plan DZ, P0 item 4; sizes corrected under FC P0).
///
/// Before this existed, the model list was a hard-coded array of `RecommendedModel` inside
/// `LocalLLMService`, mixing display copy with the facts the runtime needs. The catalog owns both
/// halves now and `LocalLLMService.recommendedModels` / `visionModelIds` / `expectedDownloadBytes`
/// are **compatibility projections** of it — same values, same order, no call site changed.
///
/// Sizes used to be authored as display strings ("1.5 GB") and parsed back into bytes with a
/// gibibyte multiplier. That made every number wrong twice over: the unit was misnamed, and one
/// entry (SmolVLM2 2.2B) was understated threefold. Each entry now carries a
/// ``VerifiedSnapshot`` of exact byte counts read from the model host's API, and the display
/// string is derived from those bytes — there is no authored size left to drift.
///
/// It stays Swift rather than the JSON resource the plan sketches, because a JSON entry's whole
/// point is the per-file size/digest/revision triple, and no MLX entry has digests: these are hub
/// *snapshots*, fetched whole by repository id. The JSON catalog arrives with the acquisition
/// pipeline that can populate the per-file half.
///
/// No MLX import: pure, headless-testable, and safe to consult before any runtime exists.
enum LocalModelCatalog {

    /// Bumped when the catalog's *shape* changes, so a stored record can say what it was built from.
    static let version = 1

    // MARK: - Verified snapshots

    /// Exact, measured facts about one hub repository at one revision.
    ///
    /// **Provenance.** Every value below was read from the Hugging Face model API
    /// (`GET https://huggingface.co/api/models/<repository>?blobs=true`) on **2026-09-15**, summing
    /// the `size` of every file the repository lists at the recorded `sha`. The MLX download path
    /// fetches the whole snapshot by repository id (`LocalLLMService.downloadModel` →
    /// `downloadSnapshot(of:)`, no file filter), so the repository total *is* the download.
    ///
    /// `revision` is recorded as provenance — the sha these numbers were measured at — and is
    /// deliberately **not** used as the descriptor's revision. Pinning it would flip
    /// `LocalModelDescriptor.installationFaults()` and `LocalModelFitReport`'s
    /// `.unresolvedRevision` blocker, which are exactly what stop the acquisition pipeline
    /// accepting an unpinned MLX entry today, while the legacy download path would still fetch
    /// `main`. Claiming a pin the downloader does not honour belongs to the acquisition work, not
    /// to a metadata correction.
    struct VerifiedSnapshot: Equatable, Sendable {
        /// The commit these byte counts were measured at. Provenance only — see the note above.
        let revision: String
        /// Every file in the repository at `revision`, summed. This is what a fresh install pulls.
        let totalBytes: Int64
        /// `model.safetensors` alone — the weights that become resident when the model loads.
        let weightsBytes: Int64
        /// How many files the repository listed, so a silently truncated re-verification shows up.
        let fileCount: Int
        /// ISO day the measurement was taken.
        let verifiedOn: String
    }

    /// A catalog entry: the runtime-facing descriptor, the verified artifact facts, and the copy
    /// the picker renders.
    struct Entry: Equatable, Sendable {
        let descriptor: LocalModelDescriptor
        /// Measured artifact facts. The single source for every byte count this entry reports.
        let snapshot: VerifiedSnapshot
        let notes: String
        /// Minimum device RAM (GB) to offer this model. 0 = no restriction.
        let minimumRAMGB: Double

        var id: LocalModelID { descriptor.id }

        /// The download size as the picker shows it. Derived from ``VerifiedSnapshot/totalBytes``,
        /// never authored — the accessor keeps its old name so `RecommendedModel` and the two
        /// picker screens are unchanged, but the value can no longer disagree with the bytes.
        var estimatedSize: String { formattedDownloadSize(snapshot.totalBytes) }
    }

    // MARK: - Authoritative capability claims

    /// Model ids whose checkpoints declare a vision tree. Factual, asserted here rather than
    /// inferred from the name, and the single source `LocalLLMService.visionModelIds` projects.
    ///
    /// It is a superset of the catalog's vision entries: both hub casings of the Gemma 4 E-series
    /// appear in the wild, and a user who typed the other one must still get the VLM factory.
    static let visionCapableModelIDs: Set<String> = [
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-E2B-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
    ]

    /// Catalog ids that emit usable `<tool_call>` markup.
    static let toolCapableModelIDs: Set<String> = [
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "LiquidAI/LFM2.5-2.6B-MLX-4bit",
        "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    ]

    // MARK: - Entries

    /// The recommended models, in the order the picker shows them.
    ///
    /// Order is part of the contract: `LocalModelManagerView` and `AgenticFeaturesView` render this
    /// array directly, and the first entry is the one first-run offers.
    ///
    /// The copy carries no qualification claim. Nothing in this repository records a device test
    /// for any of these checkpoints, so the notes describe what a model *is* and what it costs,
    /// and leave "works well on your phone" to the device-qualification pass that can measure it.
    static let entries: [Entry] = [
        // Gemma 4 — the on-device agent pair
        entry(id: "mlx-community/gemma-4-e2b-it-4bit",
              displayName: "Gemma 4 E2B (Agent)",
              snapshot: VerifiedSnapshot(revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
                                         totalBytes: 3_583_088_661,
                                         weightsBytes: 3_550_670_554,
                                         fileCount: 10,
                                         verifiedOn: "2026-09-15"),
              quantization: "4bit",
              notes: "On-device agent — tool calling, 140+ languages, vision. Uses about 4 GB of memory while running.",
              minimumRAMGB: 8),
        entry(id: "mlx-community/gemma-4-e4b-it-4bit",
              displayName: "Gemma 4 E4B (Agent+)",
              snapshot: VerifiedSnapshot(revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
                                         totalBytes: 5_179_241_512,
                                         weightsBytes: 5_146_800_534,
                                         fileCount: 10,
                                         verifiedOn: "2026-09-15"),
              quantization: "4bit",
              notes: "Bigger Gemma 4 — tool calling and vision with more room for quality. Needs a high-memory device (12 GB).",
              minimumRAMGB: 12),
        // Vision models (can see photos from glasses)
        entry(id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
              displayName: "SmolVLM2 2.2B (Vision)",
              snapshot: VerifiedSnapshot(revision: "844516024a1c4400d34489b89ee067d794e432ed",
                                         totalBytes: 4_498_568_233,
                                         weightsBytes: 4_493_651_795,
                                         fileCount: 14,
                                         verifiedOn: "2026-09-15"),
              quantization: nil,
              notes: "Vision model — sees photos and video frames. Its weights are unquantized, so "
                  + "both the download and the memory it needs are large for its parameter count."),
        entry(id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
              displayName: "SmolVLM2 500M (Vision)",
              snapshot: VerifiedSnapshot(revision: "fa57db46815177fbdfd65cc85a2b3416a8332268",
                                         totalBytes: 1_019_926_804,
                                         weightsBytes: 1_015_023_993,
                                         fileCount: 14,
                                         verifiedOn: "2026-09-15"),
              quantization: nil,
              notes: "Small vision model — basic photo understanding."),
        // Text-only MLX models
        entry(id: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
              displayName: "LFM2.5 2.6B (Reasoning)",
              snapshot: VerifiedSnapshot(revision: "04efa23776ce61ec34ec95ec34c859854c89542b",
                                         totalBytes: 1_601_123_632,
                                         weightsBytes: 1_583_152_892,
                                         fileCount: 10,
                                         verifiedOn: "2026-09-15"),
              quantization: "4bit",
              notes: "Liquid AI hybrid reasoning model — thinks before every answer (expect a "
                  + "pause before speech starts), then answers with tool use and instruction "
                  + "following."),
        entry(id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
              displayName: "Qwen 2.5 3B",
              snapshot: VerifiedSnapshot(revision: "4f83f8f146fdf28b512a06562b671d7af4fab457",
                                         totalBytes: 1_747_851_324,
                                         weightsBytes: 1_736_293_090,
                                         fileCount: 11,
                                         verifiedOn: "2026-09-15"),
              quantization: "4bit",
              notes: "General reasoning and tool use."),
        // (Gemma 2 2B was retired from this list in favour of the Gemma 4 pair above —
        // vision + tools at comparable footprints. Already-downloaded copies keep working:
        // loading is by id, its `LocalModelBudget` entry remains, and the legacy migration
        // gives it a compatibility descriptor.)
        entry(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
              displayName: "Qwen 2.5 0.5B",
              snapshot: VerifiedSnapshot(revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
                                         totalBytes: 289_601_064,
                                         weightsBytes: 278_064_920,
                                         fileCount: 11,
                                         verifiedOn: "2026-09-15"),
              quantization: "4bit",
              notes: "Ultra-light, basic capability."),
    ]

    /// Build an entry, deriving every runtime fact from the one place that already owns it —
    /// context window from `LocalModelBudget`, working set from `MemoryHeadroom`, capabilities from
    /// the asserted sets above, and every byte count from the verified snapshot. Nothing is
    /// inferred from the id string, and nothing is parsed back out of display copy.
    ///
    /// Weights and download are deliberately different numbers: `estimatedWeightsBytes` is what
    /// becomes resident (`model.safetensors`), while the download is the whole snapshot. The two
    /// differ by only the tokenizer and configs here, but they are not the same fact.
    private static func entry(id rawID: String,
                              displayName: String,
                              snapshot: VerifiedSnapshot,
                              quantization: String?,
                              notes: String,
                              minimumRAMGB: Double = 0) -> Entry {
        let weights = snapshot.weightsBytes
        let working = MemoryHeadroom.workingOverheadBytes
        var capabilities: Set<LocalModelCapability> = [.text]
        if visionCapableModelIDs.contains(rawID) { capabilities.insert(.vision) }
        if toolCapableModelIDs.contains(rawID) { capabilities.insert(.toolFriendly) }

        let descriptor = LocalModelDescriptor(
            id: LocalModelID(rawID),
            displayName: displayName,
            runtime: .mlx,
            repositoryID: rawID,
            // Honest: the MLX path fetches whatever `main` holds. The snapshot records the sha its
            // byte counts were measured at, but the descriptor stays unpinned, because
            // `installationFaults()` refuses to *download* an unpinned descriptor precisely so a
            // revision nothing actually requests cannot quietly become the new normal.
            revision: LocalModelDescriptor.floatingRevision,
            files: [],
            quantization: quantization,
            capabilities: capabilities,
            contextLength: LocalModelBudget.contextWindow(for: rawID),
            estimatedWeightsBytes: weights,
            estimatedWorkingBytes: working,
            minimumHeadroomBytes: weights + working,
            license: .unverified)
        return Entry(descriptor: descriptor,
                     snapshot: snapshot,
                     notes: notes,
                     minimumRAMGB: minimumRAMGB)
    }

    // MARK: - Lookup

    static func entry(for id: LocalModelID) -> Entry? {
        entries.first { $0.id == id }
    }

    static func descriptor(for id: LocalModelID) -> LocalModelDescriptor? {
        entry(for: id)?.descriptor
    }

    /// Exact bytes a fresh install of this model pulls, or `nil` for an id the catalog does not
    /// know. Never a guess: an uncatalogued id has no size, and callers must treat `nil` as
    /// "unknown" rather than substituting a number.
    static func downloadBytes(for id: LocalModelID) -> Int64? {
        entry(for: id)?.snapshot.totalBytes
    }

    /// Every catalogued id, as raw strings.
    static var catalogedModelIDs: Set<String> { Set(entries.map(\.id.rawValue)) }

    /// A descriptor for a model this build has never heard of — a user-typed id, or a catalog entry
    /// retired after the user downloaded it (Gemma 2 2B is the live example).
    ///
    /// Deliberately conservative and never inventive: MLX runtime (the only runtime that could have
    /// produced an existing installation), the id as its own display name, `.text` alone unless the
    /// asserted vision set says otherwise, and the context window `LocalModelBudget` already
    /// applies to unknown ids. No capability, size or licence is guessed.
    static func compatibilityDescriptor(forLegacyMLXModelID rawID: String) -> LocalModelDescriptor {
        var capabilities: Set<LocalModelCapability> = [.text]
        if visionCapableModelIDs.contains(rawID) { capabilities.insert(.vision) }
        return LocalModelDescriptor(
            id: LocalModelID(rawID),
            displayName: rawID,
            runtime: .mlx,
            repositoryID: rawID,
            revision: LocalModelDescriptor.floatingRevision,
            files: [],
            quantization: nil,
            capabilities: capabilities,
            contextLength: LocalModelBudget.contextWindow(for: rawID),
            estimatedWeightsBytes: 0,
            estimatedWorkingBytes: MemoryHeadroom.workingOverheadBytes,
            minimumHeadroomBytes: 0,
            license: .unverified)
    }

    /// Resolve a saved MLX model string to a descriptor: the bundled entry when it is catalogued,
    /// a compatibility descriptor otherwise. Never fails — no saved configuration may become
    /// invalid because of this plan.
    static func resolveDescriptor(forLegacyMLXModelID rawID: String) -> LocalModelDescriptor {
        descriptor(for: LocalModelID(rawID)) ?? compatibilityDescriptor(forLegacyMLXModelID: rawID)
    }

    // MARK: - Size formatting

    /// The one way a *download or storage* size is written for a person, in decimal gigabytes —
    /// the same units the model host quotes and iOS reports free space in, so the number in the
    /// picker is the number the user sees their disk lose.
    ///
    /// (Memory is a different fact and stays in binary units: `LocalModelPresentation.formatBytes`
    /// draws working-set and headroom figures, which are counted the way the allocator counts.)
    ///
    /// The rule, in full: one decimal place from 1 GB up ("4.5 GB"), two below it so a small model
    /// is not rounded into "0.3 GB" ("0.29 GB"), and whole decimal megabytes under 100 MB. Zero or
    /// negative bytes are not silently drawn as "0.0 GB" — an absent measurement says so.
    static func formattedDownloadSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Unknown size" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 0.995 { return String(format: "%.1f GB", gb) }
        if gb >= 0.0995 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
