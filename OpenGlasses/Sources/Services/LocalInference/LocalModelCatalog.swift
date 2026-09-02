import Foundation

/// The versioned bundled catalog of local models (Plan DZ, P0 item 4).
///
/// Before this existed, the model list was a hard-coded array of `RecommendedModel` inside
/// `LocalLLMService`, mixing display copy with the facts the runtime needs. The catalog owns both
/// halves now and `LocalLLMService.recommendedModels` / `visionModelIds` / `expectedDownloadBytes`
/// are **compatibility projections** of it — same values, same order, no call site changed.
///
/// It stays Swift rather than the JSON resource the plan sketches, because a JSON entry's whole
/// point is the per-file size/digest/revision triple, and no MLX entry has one: these are hub
/// *snapshots*, fetched whole by repository id with no revision pinning and no recorded digests.
/// Writing them into JSON would be writing empty fields in a more expensive format. The JSON
/// catalog arrives with the acquisition pipeline that can actually populate it.
///
/// No MLX import: pure, headless-testable, and safe to consult before any runtime exists.
enum LocalModelCatalog {

    /// Bumped when the catalog's *shape* changes, so a stored record can say what it was built from.
    static let version = 1

    /// A catalog entry: the runtime-facing descriptor plus the copy the picker renders.
    struct Entry: Equatable, Sendable {
        let descriptor: LocalModelDescriptor
        /// Human-authored size string, e.g. `"3.6 GB"`. Kept verbatim because it is what the UI
        /// has always shown and what the download-progress estimate parses.
        let estimatedSize: String
        let notes: String
        /// Minimum device RAM (GB) to offer this model. 0 = no restriction.
        let minimumRAMGB: Double

        var id: LocalModelID { descriptor.id }
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
    static let entries: [Entry] = [
        // Gemma 4 — best on-device agent model
        entry(id: "mlx-community/gemma-4-e2b-it-4bit",
              displayName: "Gemma 4 E2B (Agent)",
              estimatedSize: "3.6 GB",
              quantization: "4bit",
              notes: "Best on-device agent — tool calling, 140+ languages, vision. Uses ~4 GB while running.",
              minimumRAMGB: 8),
        entry(id: "mlx-community/gemma-4-e4b-it-4bit",
              displayName: "Gemma 4 E4B (Agent+)",
              estimatedSize: "5.1 GB",
              quantization: "4bit",
              notes: "Bigger Gemma 4 — highest-quality on-device agent, with vision. Needs a high-memory device (12 GB).",
              minimumRAMGB: 12),
        // Vision models (can see photos from glasses)
        entry(id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
              displayName: "SmolVLM2 2.2B (Vision)",
              estimatedSize: "1.5 GB",
              quantization: nil,
              notes: "Best small vision model — sees photos + video"),
        entry(id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
              displayName: "SmolVLM2 500M (Vision)",
              estimatedSize: "0.35 GB",
              quantization: nil,
              notes: "Tiny vision model — basic photo understanding"),
        // Text-only MLX models
        entry(id: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
              displayName: "LFM2.5 2.6B (Reasoning)",
              estimatedSize: "1.6 GB",
              quantization: "4bit",
              notes: "Liquid AI hybrid reasoning model — thinks before every answer (expect a "
                  + "pause before speech starts), then answers with strong tool use and "
                  + "instruction following. Best quality per GB of the text-only models."),
        entry(id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
              displayName: "Qwen 2.5 3B",
              estimatedSize: "1.8 GB",
              quantization: "4bit",
              notes: "Strong reasoning and tool use"),
        // (Gemma 2 2B was retired from this list in favour of the Gemma 4 pair above —
        // vision + tools at comparable footprints. Already-downloaded copies keep working:
        // loading is by id, its `LocalModelBudget` entry remains, and the legacy migration
        // gives it a compatibility descriptor.)
        entry(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
              displayName: "Qwen 2.5 0.5B",
              estimatedSize: "0.4 GB",
              quantization: "4bit",
              notes: "Ultra-light, basic capability"),
    ]

    /// Build an entry, deriving every runtime fact from the one place that already owns it —
    /// context window from `LocalModelBudget`, working set from `MemoryHeadroom`, capabilities from
    /// the asserted sets above. Nothing is inferred from the id string.
    private static func entry(id rawID: String,
                              displayName: String,
                              estimatedSize: String,
                              quantization: String?,
                              notes: String,
                              minimumRAMGB: Double = 0) -> Entry {
        let weights = bytes(fromEstimatedSize: estimatedSize) ?? 0
        let working = MemoryHeadroom.workingOverheadBytes
        var capabilities: Set<LocalModelCapability> = [.text]
        if visionCapableModelIDs.contains(rawID) { capabilities.insert(.vision) }
        if toolCapableModelIDs.contains(rawID) { capabilities.insert(.toolFriendly) }

        let descriptor = LocalModelDescriptor(
            id: LocalModelID(rawID),
            displayName: displayName,
            runtime: .mlx,
            repositoryID: rawID,
            // Honest: the MLX path has always fetched whatever `main` held. Pinning these is part
            // of the acquisition work, and `installationFaults()` refuses to *download* an
            // unpinned descriptor precisely so this cannot quietly become the new normal.
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
                     estimatedSize: estimatedSize,
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

    // MARK: - Size parsing

    /// Parse an authored `"3.6 GB"` into bytes. Same rule the download-progress estimate has always
    /// used, moved here so the catalog is the only place that reads its own copy.
    static func bytes(fromEstimatedSize estimatedSize: String) -> Int64? {
        let cleaned = estimatedSize.uppercased()
            .replacingOccurrences(of: "GB", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let gb = Double(cleaned), gb > 0 else { return nil }
        return Int64(gb * 1_073_741_824)
    }
}
