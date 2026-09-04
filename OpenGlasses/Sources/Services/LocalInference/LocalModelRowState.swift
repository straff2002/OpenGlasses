import Foundation

/// What one row of the local-model manager is *about*, derived from facts rather than from
/// whichever branch the view happened to take first
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Local model manager and diagnostics").
///
/// The screen has to show five states — installed, staged, incompatible, loaded, update-available —
/// and a model can satisfy several at once: an installed model can be resident *and* have a newer
/// catalog revision, and an installed model can be re-downloading while the old copy is still
/// loaded. A view that answers that with nested `if`s answers it differently in each place it
/// asks. So the precedence is a single pure function with a truth table behind it, and the row
/// renders what it returns.
///
/// ### Precedence, and why it is this order
///
/// 1. **staged** — bytes are moving. It is the only state with a clock, a cancel and a retry, and
///    it is the state a person came to the screen to watch.
/// 2. **incompatible** — the files are there and the runtime will not take them. Saying "installed"
///    to someone who is about to tap Load is a lie they act on.
/// 3. **loaded** — residency is a fact about right now and it owns the unload action.
/// 4. **updateAvailable** — the same model, at a revision the catalog has moved past.
/// 5. **installed**, then **notInstalled**.
///
/// `incompatible` and `loaded` cannot both be true of an honest input: a model that loaded is a
/// model the runtime accepted, and a successful load clears the recorded reason. The ordering says
/// what happens if a caller passes a stale reason anyway, rather than leaving it to chance.
enum LocalModelRowState: Equatable, Sendable {
    /// No files on disk and nothing in flight.
    case notInstalled
    /// An acquisition plan exists for this model.
    case staged(LocalModelStagingSummary)
    /// Installed, and this build cannot load it. Carries what is missing.
    case incompatible(LocalModelIncompatibility)
    /// Resident in memory right now.
    case loaded
    /// Installed at an older revision than the one on offer.
    case updateAvailable(installedRevision: String, availableRevision: String)
    /// Installed, loadable, not resident.
    case installed
}

/// How far an acquisition has got, in the shape a row renders.
///
/// Byte counts come from the plan, which reads them back from disk — so this survives a relaunch
/// with the same numbers, which is the whole reason `LocalModelDownloadPlan` persists them.
struct LocalModelStagingSummary: Equatable, Sendable {

    /// The plan's state, collapsed to what the row says out loud. `awaitingConsent` is kept
    /// separate from `queued` because one of them is waiting for a person and the other is waiting
    /// for the network, and telling a person their download is "waiting" when it is waiting for
    /// *them* is how a stuck download gets reported as a bug.
    enum Phase: Equatable, Sendable {
        case awaitingConsent
        case queued
        case downloading
        case validating
        case installing
        /// Stopped, and the same plan may run again.
        case retryable(LocalModelDownloadPlan.FailureReason)
    }

    let phase: Phase
    /// 1-based index of the file being worked on, or nil when no file is.
    let fileNumber: Int?
    let fileCount: Int
    let completedBytes: Int64
    let totalBytes: Int64

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// Whether the row should offer Cancel. A failed plan has nothing to cancel — it offers Retry.
    var isCancellable: Bool {
        if case .retryable = phase { return false }
        return true
    }

    var isRetryable: Bool {
        if case .retryable = phase { return true }
        return false
    }

    /// Build from a plan, or nil when the plan has finished and has nothing left to show.
    ///
    /// `completedBytes` overrides the plan's own persisted count with the live reading the download
    /// manager keeps for the file in flight. The persisted count is still the fallback, and is what
    /// a relaunched app shows.
    init?(plan: LocalModelDownloadPlan, completedBytes: Int64? = nil) {
        let phase: Phase
        switch plan.state {
        case .planned, .awaitingConsent: phase = .awaitingConsent
        case .queued: phase = .queued
        case .downloading: phase = .downloading
        case .validating: phase = .validating
        case .installing: phase = .installing
        case .failed(let failure) where failure.isRetryable: phase = .retryable(failure.reason)
        // Installed, cancelled and terminally failed plans are not staging: the row's state comes
        // from the installation record (or its absence), not from a plan that is over.
        case .installed, .cancelled, .failed: return nil
        }
        self.phase = phase
        self.fileNumber = plan.state.fileIndex.map { $0 + 1 }
        self.fileCount = plan.files.count
        self.completedBytes = completedBytes ?? plan.completedBytes
        self.totalBytes = plan.totalBytes
    }
}

// MARK: - Runtime availability

/// Whether the runtime a model needs can run it here at all. Separate from the model's own files:
/// a perfectly good GGUF is unloadable on a build with the feature switched off, and that is a
/// different sentence from "this file is broken".
enum LocalModelRuntimeAvailability: Equatable, Sendable {
    /// A backend is registered and switched on.
    case available
    /// The runtime exists in this build but the user has not turned it on.
    case disabled
    /// This build has no backend for that runtime at all.
    case unavailable
}

// MARK: - Incompatibility

/// Why an installed model cannot be loaded, in the vocabulary the runtime actually refused in.
///
/// Every case names *what is missing* rather than saying the load failed — that is the plan's
/// accessibility requirement ("unsupported models explain what metadata or runtime capability is
/// missing"), and it is the difference between a message a person can act on and one they can only
/// report.
///
/// Transient failures are deliberately **not** here. Not enough memory, a transition already in
/// flight, the app being backgrounded — those are retryable conditions the manager already surfaces
/// with a Try again button, and filing them as incompatibility would tell someone their model is
/// broken because they had a video call open.
enum LocalModelIncompatibility: Equatable, Sendable {
    /// The GGUF runtime is switched off.
    case runtimeDisabled(LocalModelRuntime)
    /// No backend for the runtime this model declares.
    case runtimeUnavailable(LocalModelRuntime)
    /// The file carries no `general.architecture`, so nothing can be configured from it.
    case missingArchitectureMetadata
    /// The embedded chat template cannot carry a conversation.
    case unsupportedChatTemplate(LlamaChatTemplateFault)
    /// Every ceiling together left a context too small to hold one exchange.
    case contextTooSmall(tokens: Int)
    /// The manifest names a weights file that is not on disk.
    case weightsMissing
    /// The manifest no longer describes what is on disk.
    case installationIncomplete

    /// Map a load failure to an incompatibility, or nil when the failure was transient.
    ///
    /// Driven by the backends' own typed errors (`LlamaBackendError` from PR3,
    /// `LocalInferenceError` from PR1) so the screen cannot drift from what the runtime refused.
    static func from(_ error: Error) -> LocalModelIncompatibility? {
        if let backend = error as? LlamaBackendError {
            switch backend {
            case .runtimeDisabled: return .runtimeDisabled(.llamaCpp)
            case .unsupportedArchitecture: return .missingArchitectureMetadata
            case .unsupportedChatTemplate(let fault): return .unsupportedChatTemplate(fault)
            case .contextTooSmall(let tokens): return .contextTooSmall(tokens: tokens)
            case .weightsMissing: return .weightsMissing
            case .installationIncomplete: return .installationIncomplete
            // Memory, engine faults, tokenization and "already generating" are conditions of the
            // moment, not of the model.
            case .insufficientMemory, .notLoaded, .alreadyGenerating, .promptTooLong,
                 .tokenizationFailed, .engine:
                return nil
            }
        }
        if let seam = error as? LocalInferenceError {
            switch seam {
            case .noBackend(let runtime): return .runtimeUnavailable(runtime)
            case .installationInvalid: return .installationIncomplete
            case .transitionInProgress, .notLoaded, .wrongModelResident, .backgrounded,
                 .visionNotAvailable:
                return nil
            }
        }
        return nil
    }

    /// Whether re-running the same load could plausibly succeed without anything else changing.
    /// Only the two switch-shaped cases can: the rest are properties of the file.
    var isResolvableBySetting: Bool {
        switch self {
        case .runtimeDisabled: return true
        case .runtimeUnavailable, .missingArchitectureMetadata, .unsupportedChatTemplate,
             .contextTooSmall, .weightsMissing, .installationIncomplete:
            return false
        }
    }

    /// One line for the badge. Short enough for a row, and never colour alone — the badge is text.
    var badgeText: String {
        switch self {
        case .runtimeDisabled: return "Turned off"
        case .runtimeUnavailable: return "Unsupported"
        case .missingArchitectureMetadata, .unsupportedChatTemplate: return "Can't run"
        case .contextTooSmall: return "Too large"
        case .weightsMissing, .installationIncomplete: return "Files missing"
        }
    }

    /// The whole reason, in the words the "show incompatibility reason" action puts on screen. It
    /// names the missing metadata or capability and, where one exists, the way out.
    var explanation: String {
        switch self {
        case .runtimeDisabled:
            return "GGUF models are switched off on this iPhone, so this model can't be loaded. "
                + "Turn them on in Settings to use it. Its files stay where they are either way."
        case .runtimeUnavailable(let runtime):
            return "This build has no on-device runtime for \(Self.runtimeName(runtime)) models, "
                + "so it can't load this one."
        case .missingArchitectureMetadata:
            return "This model file doesn't record which architecture it is, so nothing can be "
                + "configured from it. On-device models are read from the file's own metadata — "
                + "the architecture is the one field there is no safe default for. Its files stay "
                + "installed; it can't be selected for conversation."
        case .unsupportedChatTemplate(let fault):
            return "This model doesn't carry a usable chat template, so there's no way to hand it "
                + "a conversation. " + Self.templateDetail(fault)
                + " Its files stay installed; it can't be selected for conversation."
        case .contextTooSmall(let tokens):
            return "There isn't enough memory on this iPhone to give this model a usable "
                + "conversation window — it came out at \(tokens) tokens, below the minimum for a "
                + "system prompt and one exchange. A smaller model, or a smaller quantization of "
                + "this one, will fit."
        case .weightsMissing:
            return "The model file this installation names isn't on disk any more. Remove it and "
                + "download it again."
        case .installationIncomplete:
            return "This installation's record no longer matches the files on disk, so it can't be "
                + "trusted to load. Remove it and download it again."
        }
    }

    /// Spoken form. Same words — the explanation is already a sentence rather than a colour or a
    /// glyph — prefixed so a VoiceOver user hears what the sentence is *about* first.
    var spokenLabel: String { "Can't be loaded. \(explanation)" }

    private static func runtimeName(_ runtime: LocalModelRuntime) -> String {
        switch runtime {
        case .mlx: return "MLX"
        case .llamaCpp: return "GGUF"
        }
    }

    /// The template fault, said in terms of what the file failed to do rather than which probe
    /// caught it.
    private static func templateDetail(_ fault: LlamaChatTemplateFault) -> String {
        switch fault {
        case .absent: return "The file carries no chat template at all."
        case .renderFailed: return "Its template couldn't render a basic exchange."
        case .emptyRender: return "Its template rendered an exchange to nothing."
        case .dropsUserContent: return "Its template drops what the user said."
        case .dropsAssistantContent: return "Its template drops the model's own replies."
        case .noAssistantHeader:
            return "Its template has no way to signal that it's the model's turn to speak."
        }
    }
}

// MARK: - Derivation

/// Everything the row state is derived from. A value rather than a view's `@State` so the truth
/// table is a test rather than a screenshot.
struct LocalModelRowInputs: Equatable, Sendable {
    /// What is on offer: the catalog entry, the import descriptor, or the installed model's own.
    let descriptor: LocalModelDescriptor
    /// The installation record, when the files are on disk.
    let installation: InstalledLocalModel?
    /// An acquisition plan naming this model, when there is one.
    let plan: LocalModelDownloadPlan?
    /// Resident in memory right now.
    let isResident: Bool
    /// A reason recorded by a previous failed load, when one was recorded.
    let recordedIncompatibility: LocalModelIncompatibility?
    let runtimeAvailability: LocalModelRuntimeAvailability

    init(descriptor: LocalModelDescriptor,
         installation: InstalledLocalModel? = nil,
         plan: LocalModelDownloadPlan? = nil,
         isResident: Bool = false,
         recordedIncompatibility: LocalModelIncompatibility? = nil,
         runtimeAvailability: LocalModelRuntimeAvailability = .available) {
        self.descriptor = descriptor
        self.installation = installation
        self.plan = plan
        self.isResident = isResident
        self.recordedIncompatibility = recordedIncompatibility
        self.runtimeAvailability = runtimeAvailability
    }
}

extension LocalModelRowState {

    /// The truth table. Precedence is documented on the type; this is the only place it is applied.
    static func derive(_ inputs: LocalModelRowInputs) -> LocalModelRowState {
        if let plan = inputs.plan, let staging = LocalModelStagingSummary(plan: plan) {
            return .staged(staging)
        }
        guard let installation = inputs.installation else { return .notInstalled }

        if let incompatibility = incompatibility(for: installation, inputs: inputs) {
            return .incompatible(incompatibility)
        }
        if inputs.isResident { return .loaded }
        if let update = updateRevision(installed: installation, offered: inputs.descriptor) {
            return .updateAvailable(installedRevision: installation.descriptor.revision,
                                    availableRevision: update)
        }
        return .installed
    }

    /// A runtime that cannot run is an incompatibility of its own, and it outranks a recorded one:
    /// "GGUF is switched off" is why the load would fail *now*, whatever failed last time.
    private static func incompatibility(for installation: InstalledLocalModel,
                                        inputs: LocalModelRowInputs) -> LocalModelIncompatibility? {
        switch inputs.runtimeAvailability {
        case .disabled: return .runtimeDisabled(installation.runtime)
        case .unavailable: return .runtimeUnavailable(installation.runtime)
        case .available: return inputs.recordedIncompatibility
        }
    }

    /// An update is a *different pinned revision*. Two unpinned revisions are not comparable — the
    /// legacy MLX entries all read `unpinned-legacy`, and calling that an update would put an
    /// "Update" badge on every model a user already has.
    private static func updateRevision(installed: InstalledLocalModel,
                                       offered: LocalModelDescriptor) -> String? {
        guard installed.descriptor.id == offered.id else { return nil }
        guard installed.descriptor.isRevisionPinned, offered.isRevisionPinned else { return nil }
        guard installed.descriptor.revision != offered.revision else { return nil }
        return offered.revision
    }
}

// MARK: - Row copy

extension LocalModelRowState {

    /// The short state caption drawn on the row.
    var badgeText: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .staged(let staging): return LocalModelRowState.stagingBadge(staging)
        case .incompatible(let reason): return reason.badgeText
        case .loaded: return "Loaded"
        case .updateAvailable: return "Update available"
        case .installed: return "Installed"
        }
    }

    /// The whole state, spoken. Every badge on this screen carries one of these, because the badges
    /// differ in colour on screen and a colour is not a label.
    var spokenLabel: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .staged(let staging):
            return LocalModelRowState.stagingSpokenLabel(staging)
        case .incompatible(let reason):
            return reason.spokenLabel
        case .loaded:
            return "Loaded into memory"
        case .updateAvailable(let installed, let available):
            return "Update available. Installed version \(shortRevision(installed)), "
                + "version \(shortRevision(available)) is available."
        case .installed:
            return "Installed, not loaded"
        }
    }

    /// A commit hash is unreadable aloud in full; twelve characters is what the diagnostics card
    /// shows and what a person compares.
    private func shortRevision(_ revision: String) -> String { String(revision.prefix(12)) }

    private static func stagingBadge(_ staging: LocalModelStagingSummary) -> String {
        switch staging.phase {
        case .awaitingConsent: return "Waiting for you"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .validating: return "Checking"
        case .installing: return "Installing"
        case .retryable: return "Stopped"
        }
    }

    private static func stagingSpokenLabel(_ staging: LocalModelStagingSummary) -> String {
        let percent = Int((staging.fractionCompleted * 100).rounded())
        let fileClause: String
        if let number = staging.fileNumber, staging.fileCount > 1 {
            fileClause = ", file \(number) of \(staging.fileCount)"
        } else {
            fileClause = ""
        }
        switch staging.phase {
        case .awaitingConsent:
            return "Waiting for you to confirm the download"
        case .queued:
            return "Download queued\(fileClause)"
        case .downloading:
            return "Downloading, \(percent) percent\(fileClause)"
        case .validating:
            return "Checking the downloaded file\(fileClause)"
        case .installing:
            return "Installing"
        case .retryable(let reason):
            return "Download stopped at \(percent) percent. \(retryExplanation(reason))"
        }
    }

    /// Why a stopped download stopped, in the closed vocabulary the plan records. Only retryable
    /// reasons reach here — a terminal failure has already removed its plan.
    static func retryExplanation(_ reason: LocalModelDownloadPlan.FailureReason) -> String {
        switch reason {
        case .transport: return "The connection dropped. You can try again."
        case .httpStatus: return "The server refused the request. You can try again."
        case .storageUnavailable: return "There wasn't room to write the file. Free up space and try again."
        case .installFailed: return "The files downloaded but couldn't be installed. You can try again."
        // Terminal reasons never carry a retry offer; if one is ever passed here, say so plainly
        // rather than inviting a retry that will fail the same way.
        case .sizeMismatch, .digestMismatch, .redirectHostRejected, .insecureRedirect,
             .containmentRefused, .revisionMismatch, .planUnreadable, .consentMissing, .fitRefused:
            return "The download was refused and can't be resumed. Start it again."
        }
    }
}
