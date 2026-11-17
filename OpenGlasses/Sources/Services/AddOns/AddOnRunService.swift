import Foundation

/// Runs installed add-on skills for the model (Plan GF P2): one run at a time per add-on
/// (`RecipeRunQueue`), inside the sandbox (`RecipeRunner`), then hands what the run asked for to
/// the wearer's stores — memory writes under the add-on's own namespace, a card to the display —
/// and returns the spoken answer framed as untrusted data.
///
/// Every gate is checked again at run time, whatever the registry offered a moment ago: the
/// add-on may have been removed or switched off, Medical Compliance turned on, or the
/// organisation's policy changed between the prompt and the call.
@MainActor
final class AddOnRunService {

    /// Where a run's side effects go. Injected so tests see them and the runner touches no store.
    struct Sinks {
        /// Keep one fact; false when it was not kept.
        var remember: @MainActor (_ addOnID: String, _ key: String, _ value: String) -> Bool = { _, _, _ in false }
        /// Show a card on the phone and, when present, the glasses display.
        var display: @MainActor (_ addOnName: String, _ payload: RecipeDisplayPayload) -> Void = { _, _ in }
        /// Say a short line before a slow add-on runs.
        var announce: @MainActor (_ text: String) async -> Void = { _ in }
    }

    private let queue = RecipeRunQueue()
    private let runner: RecipeRunner
    private let lookup: @MainActor (String) -> AddOnStore.Loaded?
    private let conditions: @MainActor () -> AddOnAvailability.Conditions
    private let medicalBlocks: @MainActor () -> Bool
    private let context: @MainActor (RecipeAddOnManifest.Permissions) -> RecipeRunContext
    private let sinks: Sinks

    init(runner: RecipeRunner,
         lookup: @escaping @MainActor (String) -> AddOnStore.Loaded?,
         conditions: @escaping @MainActor () -> AddOnAvailability.Conditions,
         medicalBlocks: @escaping @MainActor () -> Bool = { MedicalEgressGuard.blocks(.recipeAddOn) },
         context: @escaping @MainActor (RecipeAddOnManifest.Permissions) -> RecipeRunContext,
         sinks: Sinks = Sinks()) {
        self.runner = runner
        self.lookup = lookup
        self.conditions = conditions
        self.medicalBlocks = medicalBlocks
        self.context = context
        self.sinks = sinks
    }

    func run(addOnID: String, skill: String, arguments: [String: Any]) async -> String {
        guard let addOn = lookup(addOnID) else {
            return String(localized: "That add-on isn't installed any more.")
        }
        let manifest = addOn.manifest
        if let hidden = AddOnAvailability.hidden(manifest, trust: addOn.trust, enabled: addOn.record.enabled,
                                                 conditions: conditions()) {
            return String(localized: "That add-on can't run right now: \(AddOnAvailability.explanation(hidden)).")
        }
        if AddOnAvailability.usesNetwork(manifest), medicalBlocks() {
            return MedicalEgressRefusal.userMessage
        }
        if manifest.slow { await sinks.announce(String(localized: "One moment.")) }

        let runner = self.runner
        let runContext = context(manifest.permissions)
        let boxed = SendableArguments(arguments)
        let admission = await queue.run(addOnID: addOnID) {
            await runner.run(manifest, skill: skill, arguments: boxed.value, context: runContext)
        }
        guard case .ran(let result) = admission else {
            return String(localized: "\(manifest.name) is busy with another request. Try again in a moment.")
        }
        apply(result, addOn: addOn)
        return Self.modelText(for: result, toolName: AddOnToolNaming.toolName(addOnID: addOnID, skill: skill),
                              addOnName: manifest.name)
    }

    /// Memory writes (only with `memory`, at most three) and the card (only with `display`).
    private func apply(_ result: RecipeRunResult, addOn: AddOnStore.Loaded) {
        let permissions = addOn.manifest.permissions
        if permissions.memory {
            for write in result.memoryWrites.prefix(RecipeAddOnValidator.maxRemembersPerRun) {
                _ = sinks.remember(addOn.manifest.id, write.key, write.value)
            }
        }
        if permissions.display, let payload = result.display {
            sinks.display(addOn.manifest.name, payload)
        }
    }

    /// What the model is told. A skill's own words are always framed as untrusted data; the app's
    /// own explanations (a refused argument, a withheld credential) are not, because they are not
    /// anything a host sent.
    static func modelText(for result: RecipeRunResult, toolName: String, addOnName: String) -> String {
        switch result.outcome {
        case .completed:
            let spoken = result.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else {
                return String(localized: "\(addOnName) returned no answer.")
            }
            return PromptInjectionPolicy.wrap(toolName: toolName, content: spoken)
        case .timedOut:
            let spoken = result.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = String(localized: "\(addOnName) ran out of time.")
            return spoken.isEmpty ? note : note + " " + PromptInjectionPolicy.wrap(toolName: toolName, content: spoken)
        case .unknownSkill:
            return String(localized: "\(addOnName) has no skill by that name any more.")
        case .invalidArguments(let reason):
            return String(localized: "\(addOnName) couldn't run: \(reason).")
        case .blockedCredential:
            return String(localized: "Nothing was sent: one of the values looked like a password or a key. Do not retry; tell the user it was blocked.")
        }
    }
}

/// The model's arguments carried into the run queue's closure. They are only read, once, inside
/// the run they were made for.
private struct SendableArguments: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The run's view of the wearer's moment, from the phone (Plan GF): local time, language and
/// units, and — only for an add-on allowed it — the location, which the runner rounds to about a
/// kilometre before any step sees it.
enum AddOnRunContextSource {

    static func context(permissions: RecipeAddOnManifest.Permissions,
                        latitude: Double?, longitude: Double?,
                        now: Date = Date(), locale: Locale = .current,
                        timeZone: TimeZone = .current) -> RecipeRunContext {
        var place: RecipeLocation?
        if permissions.location, let latitude, let longitude {
            // Coarse before it is stored anywhere in the run; the runner rounds again.
            place = RecipeLocation(latitude: (latitude * 100).rounded() / 100,
                                   longitude: (longitude * 100).rounded() / 100,
                                   city: nil, country: locale.region?.identifier)
        }
        return RecipeRunContext(now: now, timeZone: timeZone, locale: locale,
                                // US customary is the only imperial system; the UK's is metric for
                                // everything an add-on is likely to look up.
                                units: locale.measurementSystem == .us ? .imperial : .metric,
                                location: place)
    }
}
