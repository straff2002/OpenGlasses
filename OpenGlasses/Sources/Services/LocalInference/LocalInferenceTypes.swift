import Foundation

/// Backend-neutral identity and request/response shapes for on-device inference
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Core data contracts").
///
/// Nothing here imports MLX, llama, Metal or UIKit: the whole file is pure Swift so the seam can be
/// exercised headlessly. The MLX runtime keeps living in `LocalLLMService`; `MLXLocalInferenceBackend`
/// is what adapts it to these shapes.

// MARK: - Runtime and model identity

/// Which native runtime executes a model. A model's identity is separate from the engine that runs
/// it, so an id never has to change when a second runtime appears.
enum LocalModelRuntime: String, Codable, Sendable, CaseIterable {
    case mlx
    case llamaCpp
}

/// App-owned stable model identity. Stable across display-name and repository-URL changes — the
/// thing saved configurations and installed-model directories are keyed by.
///
/// For every model that exists today the raw value *is* the hub repository id
/// (`mlx-community/gemma-4-e2b-it-4bit`). That is deliberate: it makes the legacy migration a
/// no-op rename and keeps pre-DZ saved configurations decodable without a lookup table.
struct LocalModelID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }

    /// Encoded as a bare string, not as `{"rawValue": …}` — the manifest is meant to stay readable
    /// and a future hand-authored catalog entry should not need the wrapper object.
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Directory-safe rendering of the id, for `installed/<percent-encoded stable model ID>/`.
    ///
    /// Percent-encodes everything outside an explicit allowlist, so `/` (every hub id has one)
    /// can never introduce a path component and `.`/`..` can never name a parent. Reversible via
    /// `init(storageComponent:)`, which is what makes a directory scan able to recover the id.
    var storageComponent: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
    }

    /// Recover an id from a `storageComponent`. Returns nil when the component is not decodable,
    /// which is how a foreign directory under `installed/` is ignored rather than guessed at.
    init?(storageComponent: String) {
        guard let decoded = storageComponent.removingPercentEncoding, !decoded.isEmpty else { return nil }
        self.init(rawValue: decoded)
    }
}

/// What a model can factually do. Never inferred from a name (invariant: "A model is never
/// inferred to be vision-capable from its name") — every value is asserted by the bundled catalog
/// or by a load that actually succeeded.
enum LocalModelCapability: String, Codable, Sendable, CaseIterable {
    case text
    case vision
    case toolFriendly
}

/// License facts shown before installation.
///
/// PR1 ships `.unverified` for every entry: the MLX models in the catalog are already installable
/// today with no acceptance step, and inventing a license name for them would be asserting
/// something nobody checked. Curated per-model license text arrives with the catalog work.
struct LocalModelLicenseSummary: Codable, Hashable, Sendable {
    let displayName: String
    let summary: String
    /// Whether installation must record an explicit acceptance before the files are usable.
    let requiresAcceptance: Bool
    /// Revision of the license text this summary describes; `nil` when unverified.
    let revision: String?

    static let unverified = LocalModelLicenseSummary(
        displayName: "See the model card",
        summary: "License terms are published on the model's repository page and have not been "
            + "summarized in the app yet.",
        requiresAcceptance: false,
        revision: nil)
}

/// One file belonging to a model, identified precisely enough to be re-fetched and verified.
struct LocalModelFile: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case weights, projector, tokenizer, config, auxiliary
    }

    let relativePath: String
    let byteCount: Int64
    /// Lowercase hex SHA-256. Empty only for a legacy MLX installation discovered on disk, whose
    /// files were fetched before per-file digests were recorded — see `LocalModelRepository`.
    let sha256: String
    let role: Role

    /// A file whose digest was never recorded. Such a file can be *reported*, but it can never
    /// satisfy the integrity check a fresh download must pass.
    var hasVerifiedDigest: Bool { !sha256.isEmpty }
}

/// A model's identity plus everything needed to decide whether it can run here — separate from the
/// question of whether its files are currently on disk (that is `InstalledLocalModel`).
struct LocalModelDescriptor: Codable, Hashable, Sendable {
    let id: LocalModelID
    let displayName: String
    let runtime: LocalModelRuntime
    let repositoryID: String
    /// Exact immutable revision. `LocalModelDescriptor.floatingRevision` marks a legacy MLX entry
    /// that was fetched before revisions were pinned; it is never valid for a *new* download.
    let revision: String
    let files: [LocalModelFile]
    let quantization: String?
    let capabilities: Set<LocalModelCapability>
    let contextLength: Int
    let estimatedWeightsBytes: Int64
    let estimatedWorkingBytes: Int64
    let minimumHeadroomBytes: Int64
    let license: LocalModelLicenseSummary

    /// Sentinel revision for a model whose exact revision is unknown because it predates pinning.
    /// Named rather than blank so "we never knew" is distinguishable from "the field is missing".
    static let floatingRevision = "unpinned-legacy"

    var isRevisionPinned: Bool { revision != Self.floatingRevision && !revision.isEmpty }

    var supportsVision: Bool { capabilities.contains(.vision) }
    var supportsTools: Bool { capabilities.contains(.toolFriendly) }

    // MARK: Legacy-safe decoding
    //
    // Every field added after PR1 must be optional here, decoded with a default, exactly as
    // `ModelConfig.supportsVision` is. A record written by a newer build and read by an older one
    // keeps decoding; a record written by an older build and read by a newer one gets the default
    // rather than failing the whole installation.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, runtime, repositoryID, revision, files, quantization
        case capabilities, contextLength
        case estimatedWeightsBytes, estimatedWorkingBytes, minimumHeadroomBytes, license
    }

    init(id: LocalModelID,
         displayName: String,
         runtime: LocalModelRuntime,
         repositoryID: String,
         revision: String,
         files: [LocalModelFile] = [],
         quantization: String? = nil,
         capabilities: Set<LocalModelCapability>,
         contextLength: Int,
         estimatedWeightsBytes: Int64,
         estimatedWorkingBytes: Int64,
         minimumHeadroomBytes: Int64,
         license: LocalModelLicenseSummary = .unverified) {
        self.id = id
        self.displayName = displayName
        self.runtime = runtime
        self.repositoryID = repositoryID
        self.revision = revision
        self.files = files
        self.quantization = quantization
        self.capabilities = capabilities
        self.contextLength = contextLength
        self.estimatedWeightsBytes = estimatedWeightsBytes
        self.estimatedWorkingBytes = estimatedWorkingBytes
        self.minimumHeadroomBytes = minimumHeadroomBytes
        self.license = license
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LocalModelID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        // An unknown runtime string from a newer build decodes as MLX rather than failing: MLX is
        // the runtime that has always existed, so it is the safe reading of "I don't know this".
        runtime = (try? c.decode(LocalModelRuntime.self, forKey: .runtime)) ?? .mlx
        repositoryID = try c.decode(String.self, forKey: .repositoryID)
        revision = (try? c.decode(String.self, forKey: .revision)) ?? Self.floatingRevision
        files = (try? c.decode([FailableDecodable<LocalModelFile>].self, forKey: .files))?
            .compactMap(\.value) ?? []
        quantization = try? c.decode(String.self, forKey: .quantization)
        // Unknown capability strings are dropped, not fatal — a newer build's `.audio` must not
        // make this record undecodable, and silently *keeping* it would claim a capability this
        // build cannot honour.
        let rawCapabilities = (try? c.decode([String].self, forKey: .capabilities)) ?? []
        capabilities = Set(rawCapabilities.compactMap(LocalModelCapability.init(rawValue:)))
        contextLength = (try? c.decode(Int.self, forKey: .contextLength)) ?? 0
        estimatedWeightsBytes = (try? c.decode(Int64.self, forKey: .estimatedWeightsBytes)) ?? 0
        estimatedWorkingBytes = (try? c.decode(Int64.self, forKey: .estimatedWorkingBytes)) ?? 0
        minimumHeadroomBytes = (try? c.decode(Int64.self, forKey: .minimumHeadroomBytes)) ?? 0
        license = (try? c.decode(LocalModelLicenseSummary.self, forKey: .license)) ?? .unverified
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(runtime, forKey: .runtime)
        try c.encode(repositoryID, forKey: .repositoryID)
        try c.encode(revision, forKey: .revision)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(quantization, forKey: .quantization)
        // Sorted so an encode is byte-stable: a `Set` has no order, and an unstable manifest makes
        // the migration's read-back comparison meaningless.
        try c.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try c.encode(contextLength, forKey: .contextLength)
        try c.encode(estimatedWeightsBytes, forKey: .estimatedWeightsBytes)
        try c.encode(estimatedWorkingBytes, forKey: .estimatedWorkingBytes)
        try c.encode(minimumHeadroomBytes, forKey: .minimumHeadroomBytes)
        try c.encode(license, forKey: .license)
    }
}

// MARK: - Descriptor validation

/// Why a descriptor cannot be trusted. Typed rather than a string so the importer (later phase)
/// and the migration can both act on the specific fault.
enum LocalModelDescriptorFault: Equatable, Sendable {
    case emptyID
    case emptyRepositoryID
    case unpinnedRevision
    case emptyRelativePath
    case absoluteRelativePath(String)
    case escapingRelativePath(String)
    case duplicateRelativePath(String)
    case nonPositiveByteCount(String)
    case missingDigest(String)
    case noTextCapability
}

extension LocalModelDescriptor {
    /// Faults that make this descriptor unfit to *install from*. Empty means installable.
    ///
    /// Deliberately not called from the legacy migration: a model already on disk is not made safe
    /// or unsafe by this check, and refusing to record it would lose the user's existing install.
    /// It is the gate for anything that fetches files.
    func installationFaults() -> [LocalModelDescriptorFault] {
        var faults: [LocalModelDescriptorFault] = []
        if id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { faults.append(.emptyID) }
        if repositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            faults.append(.emptyRepositoryID)
        }
        if !isRevisionPinned { faults.append(.unpinnedRevision) }
        if !capabilities.contains(.text) { faults.append(.noTextCapability) }

        var seen = Set<String>()
        for file in files {
            switch LocalModelPath.normalize(file.relativePath) {
            case .empty:
                faults.append(.emptyRelativePath)
            case .absolute:
                faults.append(.absoluteRelativePath(file.relativePath))
            case .escaping:
                faults.append(.escapingRelativePath(file.relativePath))
            case .contained(let normalized):
                if !seen.insert(normalized).inserted {
                    faults.append(.duplicateRelativePath(normalized))
                }
            }
            if file.byteCount <= 0 { faults.append(.nonPositiveByteCount(file.relativePath)) }
            if !file.hasVerifiedDigest { faults.append(.missingDigest(file.relativePath)) }
        }
        return faults
    }
}

/// Relative-path containment for model files. Pure, and the single place the rule lives.
///
/// The rule is structural rather than filesystem-based on purpose: it must reject a traversal in a
/// download *plan*, long before anything exists on disk to resolve symlinks against.
enum LocalModelPath {
    enum Normalization: Equatable {
        case empty
        case absolute
        /// Leaves the model's root once components are resolved (`..`, or an encoded form of it).
        case escaping
        case contained(String)
    }

    static func normalize(_ path: String) -> Normalization {
        // Decode first: `%2e%2e/weights` is a traversal that a naive component scan misses.
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return .absolute }
        // A backslash is a separator on some producers and a literal here; treating it as a
        // separator is the conservative reading.
        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var stack: [String] = []
        for component in components {
            if component == "." { continue }
            if component == ".." {
                if stack.isEmpty { return .escaping }
                stack.removeLast()
                continue
            }
            stack.append(component)
        }
        guard !stack.isEmpty else { return .empty }
        return .contained(stack.joined(separator: "/"))
    }

    /// Resolve a relative path beneath `root`, or nil when it would not stay there.
    static func resolve(_ path: String, under root: URL) -> URL? {
        guard case .contained(let normalized) = normalize(path) else { return nil }
        let candidate = root.appendingPathComponent(normalized)
        // Belt and braces against a normalization the string pass didn't anticipate: compare the
        // standardized paths, which is what the filesystem will actually use.
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }
}

// MARK: - Installation record

/// A model whose files are present and usable, as recorded in `installation.json`.
///
/// `storage` is what lets PR1 record existing MLX installs without touching a byte of them: a
/// migrated model is `.legacyHubSnapshot`, still living in the hub's `models--org--name` layout.
struct InstalledLocalModel: Codable, Hashable, Sendable {
    /// Where this installation's files actually live.
    enum Storage: Codable, Hashable, Sendable {
        /// swift-huggingface's Python-compatible cache layout, directly under `LocalModels/`.
        /// Discovered, never moved.
        case legacyHubSnapshot(directoryName: String)
        /// `LocalModels/installed/<storageComponent>/`, owned by this app.
        case managed(directoryName: String)

        var directoryName: String {
            switch self {
            case .legacyHubSnapshot(let name), .managed(let name): return name
            }
        }

        var isLegacy: Bool {
            if case .legacyHubSnapshot = self { return true }
            return false
        }
    }

    /// Bumped when the manifest's *meaning* changes, not when a field is added — an added field is
    /// handled by the optional-decode rule above.
    static let currentManifestVersion = 1

    var manifestVersion: Int
    var descriptor: LocalModelDescriptor
    var storage: Storage
    var installedAt: Date
    /// Files this installation validated at install time. Empty for a legacy discovery, which
    /// validated nothing because nothing recorded digests when it was fetched.
    var validatedFiles: [LocalModelFile]
    /// License revision the user accepted, when acceptance was required.
    var acceptedLicenseRevision: String?
    /// Framework build id of the last *successful* load. Diagnostics only; never gates a load.
    var lastLoadedFrameworkBuild: String?

    var id: LocalModelID { descriptor.id }
    var runtime: LocalModelRuntime { descriptor.runtime }

    init(descriptor: LocalModelDescriptor,
         storage: Storage,
         installedAt: Date,
         validatedFiles: [LocalModelFile] = [],
         acceptedLicenseRevision: String? = nil,
         lastLoadedFrameworkBuild: String? = nil,
         manifestVersion: Int = InstalledLocalModel.currentManifestVersion) {
        self.manifestVersion = manifestVersion
        self.descriptor = descriptor
        self.storage = storage
        self.installedAt = installedAt
        self.validatedFiles = validatedFiles
        self.acceptedLicenseRevision = acceptedLicenseRevision
        self.lastLoadedFrameworkBuild = lastLoadedFrameworkBuild
    }

    private enum CodingKeys: String, CodingKey {
        case manifestVersion, descriptor, storage, installedAt, validatedFiles
        case acceptedLicenseRevision, lastLoadedFrameworkBuild
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = (try? c.decode(Int.self, forKey: .manifestVersion)) ?? 1
        descriptor = try c.decode(LocalModelDescriptor.self, forKey: .descriptor)
        storage = try c.decode(Storage.self, forKey: .storage)
        installedAt = (try? c.decode(Date.self, forKey: .installedAt)) ?? Date(timeIntervalSince1970: 0)
        validatedFiles = (try? c.decode([FailableDecodable<LocalModelFile>].self, forKey: .validatedFiles))?
            .compactMap(\.value) ?? []
        acceptedLicenseRevision = try? c.decode(String.self, forKey: .acceptedLicenseRevision)
        lastLoadedFrameworkBuild = try? c.decode(String.self, forKey: .lastLoadedFrameworkBuild)
    }
}

// MARK: - Generation shapes

/// One conversation turn, backend-neutral. Deliberately not the tuple the MLX path uses: the tuple
/// has no system role, and a seam that cannot carry a system turn forces every backend to invent
/// its own merge rule.
struct LocalChatMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    static func system(_ content: String) -> LocalChatMessage { .init(role: .system, content: content) }
    static func user(_ content: String) -> LocalChatMessage { .init(role: .user, content: content) }
    static func assistant(_ content: String) -> LocalChatMessage { .init(role: .assistant, content: content) }
}

/// An image for a multimodal turn. Encoded bytes, not a decoded surface: decoding is the backend's
/// business and a `CIImage` is not `Sendable`.
struct LocalImageInput: Hashable, Sendable {
    let data: Data

    init(data: Data) { self.data = data }
}

/// App-owned sampling defaults. Per-model overrides belong in the catalog descriptor, never in a
/// filename heuristic.
struct LocalSamplingConfiguration: Codable, Hashable, Sendable {
    var temperature: Float
    var topP: Float
    var topK: Int?
    var repetitionPenalty: Float?
    /// Fixed seed for deterministic tests. `nil` in production.
    var seed: UInt64?

    init(temperature: Float = 0.7,
         topP: Float = 0.9,
         topK: Int? = nil,
         repetitionPenalty: Float? = nil,
         seed: UInt64? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }

    static let conservative = LocalSamplingConfiguration()
}

/// One generation, as handed to a backend.
///
/// **Output contract.** `generate` returns an `AsyncThrowingStream<String, Error>` whose
/// *concatenation is the authoritative assistant text* — the text the tool parser and the
/// conversation store consume. `previewSink` is the separate, lossy, UI-only channel: it receives
/// chunks as the runtime produces them and may legitimately differ from the authoritative text
/// (the MLX reasoning path already filters `<think>` out of the preview and strips it from the
/// return value by different routes). Keeping them apart is what lets the MLX adapter be a pure
/// wrapper instead of a rewrite of behaviour that already ships.
struct LocalGenerationRequest: @unchecked Sendable {
    let messages: [LocalChatMessage]
    let images: [LocalImageInput]
    let maxOutputTokens: Int
    let sampling: LocalSamplingConfiguration
    let stopSequences: [String]
    let previewSink: ((String) -> Void)?

    init(messages: [LocalChatMessage],
         images: [LocalImageInput] = [],
         maxOutputTokens: Int,
         sampling: LocalSamplingConfiguration = .conservative,
         stopSequences: [String] = [],
         previewSink: ((String) -> Void)? = nil) {
        self.messages = messages
        self.images = images
        self.maxOutputTokens = maxOutputTokens
        self.sampling = sampling
        self.stopSequences = stopSequences
        self.previewSink = previewSink
    }
}

/// How a model should be brought up. Every value is a *ceiling the caller already decided*; a
/// backend clamps further but never raises.
struct LocalLoadConfiguration: Hashable, Sendable {
    /// Context window to create, already clamped by descriptor policy and the memory budget.
    let contextLength: Int
    /// Maximum prompt tokens submitted in one decode call.
    let batchSize: Int
    /// Whether the caller wants the multimodal path attached, when the model has one.
    let wantsVision: Bool

    init(contextLength: Int, batchSize: Int = 512, wantsVision: Bool = false) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.wantsVision = wantsVision
    }
}

/// What a backend reports after a successful load. Capabilities here are *as loaded*, which is not
/// always what the descriptor claimed: the MLX path demotes a vision model to text when its weight
/// tree fails to map, and that demotion has to be visible to the vision guard.
struct LocalLoadedModel: Hashable, Sendable {
    let id: LocalModelID
    let runtime: LocalModelRuntime
    let contextLength: Int
    let capabilities: Set<LocalModelCapability>

    var supportsVision: Bool { capabilities.contains(.vision) }
}

// MARK: - Errors

/// Typed faults raised by the seam itself, as opposed to the runtime-specific errors a backend
/// wraps (`LocalLLMError` for MLX). Every case is actionable by the caller.
enum LocalInferenceError: LocalizedError, Equatable {
    /// No backend registered for the runtime the model declares.
    case noBackend(LocalModelRuntime)
    /// A load or generation was requested while another transition was still in flight.
    case transitionInProgress
    /// Generation requested with nothing resident.
    case notLoaded
    /// The resident model is not the one this request names.
    case wrongModelResident(expected: LocalModelID, resident: LocalModelID)
    /// Metal work is forbidden in the background; the caller should defer or use a cloud model.
    case backgrounded
    /// Images supplied to a runtime or model that cannot see.
    case visionNotAvailable
    /// The installation's manifest no longer describes what is on disk.
    case installationInvalid(LocalModelID)

    var errorDescription: String? {
        switch self {
        case .noBackend(let runtime):
            return "No on-device runtime is available for \(runtime.rawValue) models."
        case .transitionInProgress:
            return "The on-device model is still loading or unloading. Try again in a moment."
        case .notLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .wrongModelResident(let expected, let resident):
            return "The on-device model \(resident.rawValue) is loaded, but this request needs "
                + "\(expected.rawValue)."
        case .backgrounded:
            return "On-device models can't run while the app is in the background. Switch to a "
                + "cloud model for background tasks."
        case .visionNotAvailable:
            return "This on-device model can't look at images."
        case .installationInvalid(let id):
            return "The installed files for \(id.rawValue) are incomplete. Download the model again."
        }
    }
}
