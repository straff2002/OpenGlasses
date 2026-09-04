import Foundation

/// What the user is told before a model download starts, and what may stop it
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Fit and consent").
///
/// The report is a value, not a screen: the model manager renders it, and every rule in it —
/// including the awkward ones — is decided here where a test can drive the whole truth table.
///
/// The two rules that are easiest to get wrong, and are therefore the reason this type exists:
///
///  - **Unknown size, missing digest or unresolved revision blocks installation.** They are not
///    warnings. Without them there is nothing to verify a download against, and an unverifiable
///    install is precisely what the integrity invariant forbids.
///  - **An unreadable free-space reading is an inability to check, not permission to proceed.**
///    `nil` free space blocks; it does not fall through to "probably fine".
struct LocalModelFitReport: Equatable, Sendable {

    /// Space the download needs beyond the model itself — staging holds the bytes before they are
    /// moved into place, and finishing an install by filling the phone is not an install.
    static let storageMarginBytes: Int64 = OfflineModelOffer.storageMarginBytes

    /// Something that makes installation impossible right now. Every case is checkable before a
    /// byte moves.
    enum Blocker: Equatable, Sendable {
        /// A file with no declared byte count. Nothing could confirm the download finished.
        case unknownFileSize(relativePath: String)
        /// A file with no recorded digest. Nothing could confirm the bytes are the right bytes.
        case missingDigest(relativePath: String)
        /// No exact revision, so "the same model" means nothing tomorrow.
        case unresolvedRevision
        /// The descriptor declares no files at all.
        case noFiles
        /// Free space could not be read. Visible inability to check.
        case freeSpaceUnreadable
        /// It fits nowhere: download plus margin exceeds what is free.
        case insufficientStorage(neededBytes: Int64, freeBytes: Int64)
        /// The licence requires acceptance and none has been recorded.
        case licenseNotAccepted
    }

    /// Something the user should know but which does not, on its own, stop an install.
    enum Warning: Equatable, Sendable {
        /// The honest one the plan requires: files can install perfectly and still never load,
        /// because the architecture or the chat template inside them is not supported.
        case mayInstallButNotLoad
        /// The memory gate says this model cannot be loaded on this device as things stand. The
        /// files may still be installed — freeing memory or closing other work can change the
        /// verdict, and refusing the download would be refusing on a reading taken minutes early.
        case unlikelyToLoad(neededBytes: Int64, availableBytes: Int64)
        /// It loads, but with little to spare.
        case tightMemoryHeadroom(spareBytes: Int64)
        /// The requested context will be clamped at load time.
        case contextWillBeClamped(toTokens: Int)
        /// The licence has not been summarized in the app; the user should read it upstream.
        case licenseNotSummarized
        /// Free space is above the bar but not by much.
        case storageAfterInstallIsTight(remainingBytes: Int64)
    }

    // Facts the consent surface shows.
    let displayName: String
    let runtime: LocalModelRuntime
    let quantization: String?
    let capabilities: Set<LocalModelCapability>
    /// Exact bytes to be downloaded — the sum of the declared file sizes, never an estimate.
    let downloadBytes: Int64
    /// Free space, or `nil` when it could not be read.
    let availableStorageBytes: Int64?
    /// Weights plus the runtime's working reserve: the conservative figure the load verdict uses.
    let estimatedResidentBytes: Int64
    let loadVerdict: LocalModelBudget.Admission
    let license: LocalModelLicenseSummary
    let requiresLicenseAcceptance: Bool

    let blockers: [Blocker]
    let warnings: [Warning]

    /// Installation may begin. The one gate the download manager consults.
    var canInstall: Bool { blockers.isEmpty }

    /// Everything the verdict looks at. Supplied rather than measured, so the unreadable-free-space
    /// case is a value a test can pass rather than a device state it has to arrange.
    struct Inputs: Equatable, Sendable {
        let descriptor: LocalModelDescriptor
        /// `nil` = could not be read. Not "unlimited".
        let availableStorageBytes: Int64?
        /// What this process may still allocate. `0` = no per-process budget known (simulator, Mac).
        let availableProcessBytes: Int64
        /// Licence revision the user has accepted for this model, if any.
        let acceptedLicenseRevision: String?

        init(descriptor: LocalModelDescriptor,
             availableStorageBytes: Int64?,
             availableProcessBytes: Int64,
             acceptedLicenseRevision: String? = nil) {
            self.descriptor = descriptor
            self.availableStorageBytes = availableStorageBytes
            self.availableProcessBytes = availableProcessBytes
            self.acceptedLicenseRevision = acceptedLicenseRevision
        }
    }

    static func make(_ inputs: Inputs) -> LocalModelFitReport {
        let descriptor = inputs.descriptor
        var blockers: [Blocker] = []
        var warnings: [Warning] = []

        if descriptor.files.isEmpty { blockers.append(.noFiles) }
        if !descriptor.isRevisionPinned { blockers.append(.unresolvedRevision) }
        for file in descriptor.files {
            if file.byteCount <= 0 { blockers.append(.unknownFileSize(relativePath: file.relativePath)) }
            if !file.hasVerifiedDigest { blockers.append(.missingDigest(relativePath: file.relativePath)) }
        }

        let downloadBytes = descriptor.files.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        let needed = downloadBytes + storageMarginBytes
        switch inputs.availableStorageBytes {
        case .none:
            blockers.append(.freeSpaceUnreadable)
        case .some(let free) where free < needed:
            blockers.append(.insufficientStorage(neededBytes: needed, freeBytes: free))
        case .some(let free):
            let remaining = free - needed
            if remaining < storageMarginBytes {
                warnings.append(.storageAfterInstallIsTight(remainingBytes: free - downloadBytes))
            }
        }

        if descriptor.license.requiresAcceptance,
           inputs.acceptedLicenseRevision == nil
               || (descriptor.license.revision != nil
                       && inputs.acceptedLicenseRevision != descriptor.license.revision) {
            blockers.append(.licenseNotAccepted)
        }
        if descriptor.license.revision == nil { warnings.append(.licenseNotSummarized) }

        // The conservative load verdict: declared weights, the runtime's working reserve, and the
        // descriptor's own extra reserve — through the one admission rule the load path uses.
        //
        // The extra reserve is added only for `llamaCpp`, because that is the only runtime whose
        // load path passes `minimumHeadroomBytes` to `admit` as `safetyReserveBytes`. The MLX
        // entries compute the same field as "weights + working set", so adding it there would
        // double-count and make this verdict refuse loads the MLX path performs happily. The field
        // meaning two things by runtime is a wrinkle worth removing; silently disagreeing with the
        // gate that actually runs would be worse.
        let extraReserve = descriptor.runtime == .llamaCpp ? max(0, descriptor.minimumHeadroomBytes) : 0
        let residentBytes = descriptor.estimatedWeightsBytes
            + LocalModelBudget.workingSetBytes(for: descriptor.runtime)
            + extraReserve
        let admission = LocalModelBudget.admit(.init(
            runtime: descriptor.runtime,
            declaredWeightsBytes: descriptor.estimatedWeightsBytes,
            configuredContextTokens: descriptor.contextLength,
            policyContextTokens: descriptor.contextLength,
            availableProcessBytes: inputs.availableProcessBytes,
            safetyReserveBytes: extraReserve))
        switch admission {
        case .allow:
            break
        case .allowConstrained(.tightHeadroom(let spare)):
            warnings.append(.tightMemoryHeadroom(spareBytes: spare))
        case .allowConstrained(.contextClamped(let tokens)):
            warnings.append(.contextWillBeClamped(toTokens: tokens))
        case .refuse(.insufficientHeadroom(let neededBytes, let availableBytes)):
            warnings.append(.unlikelyToLoad(neededBytes: neededBytes, availableBytes: availableBytes))
        }

        // Always stated for the second runtime, never inferred away by a successful-looking plan:
        // the GGUF backend refuses an unsupported architecture or chat template at load time, and
        // that refusal happens after the files are already on disk.
        if descriptor.runtime == .llamaCpp { warnings.append(.mayInstallButNotLoad) }

        return LocalModelFitReport(
            displayName: descriptor.displayName,
            runtime: descriptor.runtime,
            quantization: descriptor.quantization,
            capabilities: descriptor.capabilities,
            downloadBytes: downloadBytes,
            availableStorageBytes: inputs.availableStorageBytes,
            estimatedResidentBytes: residentBytes,
            loadVerdict: admission,
            license: descriptor.license,
            requiresLicenseAcceptance: descriptor.license.requiresAcceptance,
            blockers: blockers,
            warnings: warnings)
    }
}

extension LocalModelFitReport.Blocker {
    /// User-facing copy. Says what is missing and, where there is one, what the user can do; it
    /// never suggests proceeding anyway, because none of these are advisory.
    var localizedMessage: String {
        switch self {
        case .unknownFileSize:
            return "This model doesn't state how large its files are, so the download can't be checked."
        case .missingDigest:
            return "This model doesn't publish a checksum, so a download can't be verified."
        case .unresolvedRevision:
            return "This model isn't pinned to an exact version, so it can't be installed safely."
        case .noFiles:
            return "This model lists no files to download."
        case .freeSpaceUnreadable:
            return "Available storage couldn't be checked, so the download hasn't been started."
        case .insufficientStorage:
            return "There isn't enough free storage for this model."
        case .licenseNotAccepted:
            return "Accept this model's licence to continue."
        }
    }
}

extension LocalModelFitReport.Warning {
    var localizedMessage: String {
        switch self {
        case .mayInstallButNotLoad:
            return "This model may install and still not run: on-device models must use a supported "
                + "architecture and chat template, which is only known once it loads."
        case .unlikelyToLoad:
            return "This device probably can't hold this model in memory right now. The files will "
                + "install, but loading may fail until more memory is free."
        case .tightMemoryHeadroom:
            return "This model fits, but with little memory to spare. Expect slower answers and warmth."
        case .contextWillBeClamped(let tokens):
            return "Conversation length will be limited to about \(tokens) tokens on this device."
        case .licenseNotSummarized:
            return "This model's licence hasn't been summarized in the app. Read it on the "
                + "repository page before installing."
        case .storageAfterInstallIsTight:
            return "Storage will be nearly full after this download."
        }
    }
}
