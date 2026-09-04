import Foundation

/// The copy the local-model manager draws, kept out of the view so the wording is a test rather
/// than a screenshot (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Local model manager
/// and diagnostics").
///
/// The accessibility requirement that shapes the whole file: **badges have full VoiceOver labels
/// rather than relying on colour**. A badge on screen is three characters in a tinted capsule; the
/// same badge to VoiceOver is a sentence. Both come from here, so one cannot be changed without
/// the other.

/// One badge: what is drawn, what is spoken, and the glyph that keeps two badges of the same size
/// from being distinguishable only by hue.
struct LocalModelBadge: Equatable, Sendable, Identifiable {
    /// How much attention the badge asks for. Never the *only* carrier of anything — it selects a
    /// tint, and the text says the same thing.
    enum Emphasis: Equatable, Sendable { case neutral, positive, caution, critical }

    let id: String
    let text: String
    let spokenLabel: String
    let systemImage: String?
    let emphasis: Emphasis

    init(id: String,
         text: String,
         spokenLabel: String,
         systemImage: String? = nil,
         emphasis: Emphasis = .neutral) {
        self.id = id
        self.text = text
        self.spokenLabel = spokenLabel
        self.systemImage = systemImage
        self.emphasis = emphasis
    }
}

enum LocalModelPresentation {

    // MARK: - Runtime and quantization

    /// Which engine runs this model. Drawn as the name people see in model repositories, spoken as
    /// a sentence, because "MLX" read aloud is three letters with no context.
    static func runtimeBadge(_ runtime: LocalModelRuntime) -> LocalModelBadge {
        switch runtime {
        case .mlx:
            return LocalModelBadge(id: "runtime.mlx",
                                   text: "MLX",
                                   spokenLabel: "Runs on the MLX runtime",
                                   systemImage: "cpu")
        case .llamaCpp:
            return LocalModelBadge(id: "runtime.gguf",
                                   text: "GGUF",
                                   spokenLabel: "Runs on the GGUF runtime",
                                   systemImage: "cpu")
        }
    }

    /// The quantization caption. It is display metadata parsed from a file name and nothing more —
    /// the spoken form says "labelled", not "is", because a repack under a different name must not
    /// make the app claim something about the bytes.
    static func quantizationBadge(_ quantization: String?) -> LocalModelBadge? {
        guard let quantization,
              !quantization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LocalModelBadge(id: "quantization",
                               text: quantization,
                               spokenLabel: "Labelled \(spellOut(quantization)) quantization",
                               systemImage: "square.stack.3d.down.right")
    }

    /// `Q4_K_M` spoken as letters and numbers rather than as a word. VoiceOver makes a mouthful of
    /// the underscores otherwise.
    static func spellOut(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ")
    }

    /// What the model can factually do. `.text` is not badged: everything can, and a badge every
    /// row wears carries no information.
    static func capabilityBadges(_ capabilities: Set<LocalModelCapability>) -> [LocalModelBadge] {
        var badges: [LocalModelBadge] = []
        if capabilities.contains(.vision) {
            badges.append(LocalModelBadge(id: "capability.vision",
                                          text: "Vision",
                                          spokenLabel: "Can look at photos",
                                          systemImage: "eye",
                                          emphasis: .positive))
        }
        if capabilities.contains(.toolFriendly) {
            badges.append(LocalModelBadge(id: "capability.tools",
                                          text: "Tools",
                                          spokenLabel: "Can call the app's tools",
                                          systemImage: "wrench.and.screwdriver",
                                          emphasis: .positive))
        }
        return badges
    }

    /// The state badge for a row, from the derived state.
    static func stateBadge(_ state: LocalModelRowState) -> LocalModelBadge {
        let emphasis: LocalModelBadge.Emphasis
        let glyph: String
        switch state {
        case .notInstalled: emphasis = .neutral; glyph = "arrow.down.circle"
        case .staged(let staging): emphasis = staging.isRetryable ? .caution : .neutral
            glyph = staging.isRetryable ? "exclamationmark.arrow.circlepath" : "arrow.down.circle"
        case .incompatible: emphasis = .critical; glyph = "exclamationmark.triangle"
        case .loaded: emphasis = .positive; glyph = "memorychip"
        case .updateAvailable: emphasis = .caution; glyph = "arrow.triangle.2.circlepath"
        case .installed: emphasis = .positive; glyph = "checkmark.circle"
        }
        return LocalModelBadge(id: "state",
                               text: state.badgeText,
                               spokenLabel: state.spokenLabel,
                               systemImage: glyph,
                               emphasis: emphasis)
    }

    /// Every badge a row wears, in drawing order: state first (it is what changed), then what the
    /// model is.
    static func rowBadges(state: LocalModelRowState,
                          descriptor: LocalModelDescriptor) -> [LocalModelBadge] {
        var badges = [stateBadge(state), runtimeBadge(descriptor.runtime)]
        if let quantization = quantizationBadge(descriptor.quantization) { badges.append(quantization) }
        badges.append(contentsOf: capabilityBadges(descriptor.capabilities))
        return badges
    }

    // MARK: - Filters

    /// The manager's filter axes. Two independent choices rather than one combined list, because
    /// "the GGUF ones" and "the ones that can see" are different questions and combining them into
    /// a single picker forces a person to ask both at once.
    enum RuntimeFilter: String, CaseIterable, Equatable, Sendable {
        case all, mlx, gguf

        var title: String {
            switch self {
            case .all: return "All runtimes"
            case .mlx: return "MLX"
            case .gguf: return "GGUF"
            }
        }

        /// Spoken separately: the drawn title is a segment in a row of segments, and "MLX" alone
        /// does not say it is a filter.
        var spokenLabel: String {
            switch self {
            case .all: return "Show models for every runtime"
            case .mlx: return "Show only MLX models"
            case .gguf: return "Show only GGUF models"
            }
        }

        func accepts(_ runtime: LocalModelRuntime) -> Bool {
            switch self {
            case .all: return true
            case .mlx: return runtime == .mlx
            case .gguf: return runtime == .llamaCpp
            }
        }
    }

    enum CapabilityFilter: String, CaseIterable, Equatable, Sendable {
        case all, text, vision

        var title: String {
            switch self {
            case .all: return "All models"
            case .text: return "Text only"
            case .vision: return "Vision"
            }
        }

        var spokenLabel: String {
            switch self {
            case .all: return "Show text and vision models"
            case .text: return "Show only text models"
            case .vision: return "Show only models that can look at photos"
            }
        }

        /// `.text` means *text-only* — a vision model answers text as well, so a filter that let it
        /// through would make the two options indistinguishable on a list of vision models.
        func accepts(_ capabilities: Set<LocalModelCapability>) -> Bool {
            switch self {
            case .all: return true
            case .text: return !capabilities.contains(.vision)
            case .vision: return capabilities.contains(.vision)
            }
        }
    }

    // MARK: - Sizes

    /// Byte counts as this screen has always drawn them. Binary units, because that is what a model
    /// repository quotes and what the catalog's authored sizes were parsed from.
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    /// The four size facts the plan requires on every row, as label/value pairs. `onDiskBytes` is
    /// nil for a model that is not installed — there is no such fact yet, and printing a zero would
    /// look like a measurement.
    static func sizeFacts(descriptor: LocalModelDescriptor,
                          onDiskBytes: Int64?) -> [(label: String, value: String)] {
        var facts: [(String, String)] = []
        let downloadBytes = descriptor.files.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        if downloadBytes > 0 {
            facts.append(("Download", formatBytes(downloadBytes)))
        }
        if let onDiskBytes, onDiskBytes > 0 {
            facts.append(("On disk", formatBytes(onDiskBytes)))
        }
        let working = estimatedResidentBytes(descriptor)
        if working > 0 {
            facts.append(("Working memory", "about \(formatBytes(working))"))
        }
        return facts
    }

    /// Weights plus the runtime's working reserve — the same conservative figure the fit report
    /// judges the load verdict on, computed the same way so the row and the consent screen cannot
    /// disagree about the number they both print.
    static func estimatedResidentBytes(_ descriptor: LocalModelDescriptor) -> Int64 {
        let extraReserve = descriptor.runtime == .llamaCpp ? max(0, descriptor.minimumHeadroomBytes) : 0
        return descriptor.estimatedWeightsBytes
            + LocalModelBudget.workingSetBytes(for: descriptor.runtime)
            + extraReserve
    }

    // MARK: - Fit verdict

    /// How a fit report reads on a consent surface: whether the action may proceed, and what the
    /// person is told either way.
    ///
    /// The one rule worth stating out loud, because it is the plan's and it is easy to soften:
    /// **blockers disable the action and say why; warnings inform and permit.** Nothing here can
    /// turn a blocker into a warning — `canInstall` is the report's own, and this type reads it.
    struct FitPresentation: Equatable, Sendable {
        let canProceed: Bool
        /// Short line under the action, e.g. "Can't download". Empty when it can proceed.
        let refusalSummary: String?
        let blockerMessages: [String]
        let warningMessages: [String]
        /// Facts a person checks before agreeing: size, free space, working memory, load verdict.
        let facts: [Fact]

        struct Fact: Equatable, Sendable, Identifiable {
            let id: String
            let label: String
            let value: String
        }
    }

    static func present(_ report: LocalModelFitReport) -> FitPresentation {
        var facts: [FitPresentation.Fact] = [
            .init(id: "runtime", label: "Runtime", value: runtimeBadge(report.runtime).text),
        ]
        if let quantization = report.quantization, !quantization.isEmpty {
            facts.append(.init(id: "quantization", label: "Quantization", value: quantization))
        }
        facts.append(.init(id: "download", label: "Download",
                           value: formatBytes(report.downloadBytes)))
        facts.append(.init(id: "storage", label: "Free storage",
                           value: report.availableStorageBytes.map(formatBytes) ?? "Couldn't be read"))
        facts.append(.init(id: "memory", label: "Working memory",
                           value: "about \(formatBytes(report.estimatedResidentBytes))"))
        facts.append(.init(id: "verdict", label: "Fit on this iPhone",
                           value: verdictText(report.loadVerdict)))
        facts.append(.init(id: "licence", label: "Licence", value: report.license.displayName))

        return FitPresentation(
            canProceed: report.canInstall,
            refusalSummary: report.canInstall ? nil : "This model can't be downloaded.",
            blockerMessages: report.blockers.map(\.localizedMessage),
            warningMessages: report.warnings.map(\.localizedMessage),
            facts: facts)
    }

    /// The admission verdict in one phrase. `refuse` is deliberately not "won't fit": the fit
    /// report files that as a *warning*, because a memory reading taken on a consent screen can
    /// change by the time someone taps Load.
    static func verdictText(_ admission: LocalModelBudget.Admission) -> String {
        switch admission {
        case .allow:
            return "Fits"
        case .allowConstrained(.tightHeadroom):
            return "Fits, with little to spare"
        case .allowConstrained(.contextClamped(let tokens)):
            return "Fits, conversation limited to about \(tokens) tokens"
        case .refuse(.insufficientHeadroom):
            return "Probably won't fit right now"
        }
    }
}
