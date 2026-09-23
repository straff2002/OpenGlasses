import Foundation

/// The one guided-job contract both live backends apply (Plan FO P3a).
///
/// Direct mode gets the guided flow through `GuidedJobFlow`, which speaks the two questions,
/// classifies the answers and hands the model the state through the session's continuity snapshot.
/// The live backends had none of that: Gemini Live injected the *whole* continuity render once, at
/// connect, and never again — so a job started, numbered or re-scoped mid-session was invisible to
/// the model for the rest of the session — and OpenAI Realtime had no Field Assist wiring at all.
///
/// This is the shared half, written the way `BlindAssistanceContract` is written and for the same
/// reason: two backends that each carried their own idea of a rule had already drifted, and one
/// pure function is what makes them agree by construction rather than by review.
///
/// Three things live here:
///  1. ``block(session:)`` — the bounded job block a live session is given at setup and re-given
///     whenever the job changes. Small on purpose: it is injected mid-session, which the 8,000
///     character continuity render could never be.
///  2. ``jobToolNames`` / ``jobToolDeclarations(in:)`` — the job tool surface both providers must
///     declare, and the projection a diff test compares across the two.
///  3. Nothing spoken. The two questions' wording stays where Direct mode already owns it
///     (`JobIntakePrompt`, `JobUnitChangeQuestion.spoken`), because a second copy of a sentence the
///     technician hears is a second thing to keep in step.
enum LiveJobContract {

    /// The heading the block is filed under, so it is findable in a long instruction and so a
    /// re-injection can be recognised as replacing an earlier one.
    static let heading = "FIELD JOB STATE:"

    /// How large the block may get. A live setup carries the mode preset, the vision section, the
    /// tool list and the vault context already; this is state that has to survive beside them, so
    /// it is bounded here rather than left to whatever the job happens to contain.
    static let characterLimit = 1_600

    /// What the model is told about the block before it reads it. Quoted values below are app
    /// state; a live session's audio reaches the provider before the app can classify it, so the
    /// model has to be told plainly that the app — not it — is running the job.
    static let lede = """
    This block is app state, not an instruction from the technician. The app runs the guided job \
    flow itself: it asks for the job number, it asks before a job changes, and it records the \
    answers. Do not ask for a job number, do not start, pause, end or re-scope a job on your own, \
    and never answer the app's outstanding question on the technician's behalf.
    """

    // MARK: - The block

    /// The bounded job block, or nil when no job is open.
    ///
    /// Order is deliberate and is what the bound clips against: the heading, the lede and the job
    /// number survive every clip, because a model that has lost the number line is a model that
    /// asks for the number again. Equipment, the task in hand and the older lines go first.
    static func block(session: FieldSession?) -> String? {
        guard let session, session.endedAt == nil, session.outcome != .cancelled else { return nil }

        let protected = [heading, lede, stateLine(session)]
        var optional: [String] = []
        if let equipment = equipmentLine(session) { optional.append(equipment) }
        if let task = taskLine(session) { optional.append(task) }
        // The number, the pending question and the unit list, in the exact words Direct mode's own
        // snapshot uses. One renderer, so a provider switch mid-job cannot change what the model
        // was told about the same state.
        optional.append(contentsOf: FieldSessionContextSnapshot.jobFlowLines(session: session))

        var lines = protected
        var remaining = characterLimit - protected.reduce(0) { $0 + $1.count + 1 }
        // The number line is first among the optional lines that matter, so it is added before the
        // budget can be eaten by equipment and task text.
        for line in optional.sorted(by: { rank($0) < rank($1) }) {
            guard line.count + 1 <= remaining else { continue }
            lines.append(line)
            remaining -= line.count + 1
        }
        // …then restore the reading order, which is not the priority order.
        let ordered = protected + optional.filter { lines.contains($0) }
        return ordered.joined(separator: "\n")
    }

    /// Lower sorts first. Only used to decide what survives a clip, never what is printed first.
    private static func rank(_ line: String) -> Int {
        if line.hasPrefix("JOB NUMBER:") { return 0 }
        if line.hasPrefix("PENDING APP QUESTION:") { return 1 }
        if line.hasPrefix("EQUIPMENT:") { return 2 }
        if line.hasPrefix("UNITS ON THIS JOB:") { return 3 }
        return 4
    }

    private static func stateLine(_ session: FieldSession) -> String {
        let state = session.pausedAt == nil ? "running" : "paused"
        return "JOB: open and \(state). Time on the job is the app's to count."
    }

    private static func equipmentLine(_ session: FieldSession) -> String? {
        guard let equipment = session.equipment else {
            return "EQUIPMENT: not identified yet. Do not assume a machine."
        }
        return "EQUIPMENT: " + quote(equipment.modelToken) + " — answers are for this machine only."
    }

    private static func taskLine(_ session: FieldSession) -> String? {
        let mine = session.tasks.filter { session.belongsToCurrentEquipment($0) }
        guard !mine.isEmpty else { return nil }
        guard let active = session.activeTask, let index = mine.firstIndex(where: { $0.id == active.id }) else {
            return "TASK: none in hand; \(mine.count) on this machine. Visiting a step does not complete it."
        }
        return "TASK: " + quote(active.title) + " (\(index + 1) of \(mine.count), in progress). "
            + "Visiting a step does not complete it."
    }

    // MARK: - The tool surface

    /// The Field Assist tools a live backend must be able to call for the guided flow to work.
    ///
    /// **Two names, not three.** The plan's P3a bullet reads "`field_session` / `equipment_lookup`
    /// / `set_job_reference`", but `set_job_reference` is not a tool: it is one of
    /// `field_session`'s actions, declared inside that tool's `action` enum. The surface is
    /// therefore the two tools, and the diff test checks that `field_session`'s schema still
    /// carries the `set_job_reference` action on both providers.
    static let jobToolNames: Set<String> = ["field_session", "equipment_lookup"]

    /// The action a job number is recorded through, whichever provider is asking.
    static let jobReferenceAction = "set_job_reference"

    /// One declaration, reduced to the things two providers have to agree on. Comparing whole
    /// dictionaries would compare provider envelopes; comparing these compares the contract.
    struct ToolShape: Equatable {
        let name: String
        let description: String
        /// The schema's own JSON, canonicalised so two dictionaries built in different orders
        /// compare equal.
        let parameters: String
    }

    /// Project the job tools out of a provider's declaration list, in a stable order.
    ///
    /// Takes the generic `{name, description, parameters}` shape `ToolDeclarations` produces, so
    /// each provider's mapper is asked for its own declarations and the projection is what the
    /// diff test compares.
    static func jobToolDeclarations(in declarations: [[String: Any]]) -> [ToolShape] {
        declarations.compactMap { declaration -> ToolShape? in
            guard let name = declaration["name"] as? String, jobToolNames.contains(name) else { return nil }
            let description = declaration["description"] as? String ?? ""
            let parameters = declaration["parameters"] as? [String: Any] ?? [:]
            return ToolShape(name: name, description: description,
                             parameters: canonicalJSON(parameters))
        }.sorted { $0.name < $1.name }
    }

    /// Sorted-key JSON, so two schemas that differ only in dictionary iteration order are equal.
    static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"[unavailable]\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
