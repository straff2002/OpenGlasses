import Foundation

/// The `<field_assist_context>` a downloaded (MLX or GGUF) model is given while a Field Assist job
/// is open (Plan MQ P1). Pure.
///
/// ### Why a tier of its own
/// The full block (`FieldSessionService.promptContext`) carries the vault's whole core tier — every
/// reference file, the safety notes, the turn's manual passages. For the Lennox SLP99 example vault
/// that is 7.8k–10k tokens (Plan MQ's context audit), more than twice the whole prompt budget of
/// every catalog model, so `sendLocal` refused every turn with a job open. This tier is the
/// Apple on-device path's `JobSummary` with what a technician needs to keep a job going by voice:
///
/// - the vault's own rules (never fabricate, cite, escalate), which are short and must not go;
/// - the job, the unit and its nameplate line, open tasks, what the job is waiting on;
/// - the latest standing readings on this unit;
/// - the running procedure step, exactly as the full block gives it;
/// - a manuals line: the reference text and manual passages are not in this prompt, and where they
///   are fetched from instead — the Field Assist tools when the turn offers them, otherwise a
///   plain "manual answers need a cloud model", the same words as the Apple path.
///
/// It is fitted to `budgetTokens` (`LocalModelBudget.jobContextBudget(for:)`): readings go first,
/// oldest first, then the nameplate line, then the procedure is condensed. The rules, the job line
/// and the manuals line always stay.
enum LocalJobContext {

    /// Readings shown at most, newest last.
    static let maxReadings = 4

    struct Inputs: Equatable {
        var vaultName: String
        /// The manifest's `prompt_rules`.
        var rules: [String]
        /// The job as the Apple path summarises it. Its `lastReading` is not rendered here: the
        /// readings list below carries it.
        var summary: AppleOnDeviceInstructions.JobSummary
        /// `EquipmentIdentity.promptBlock` for the unit, when one is identified.
        var equipment: String?
        /// Standing readings on the current unit, oldest first ("manifold pressure, high fire 3.5 inWC").
        var readings: [String]
        /// `ProcedureRunner.promptContext()` while a procedure runs.
        var procedure: String?
        /// The rule chain's current step, when one runs.
        var ruleChain: String?
        /// The turn offers the Field Assist tools (`table_lookup`, `show_source`, `equipment_lookup`,
        /// `procedure_runner` and the rest): the manuals line sends the model to them.
        var fieldToolsOffered: Bool
        /// Where the AI model is chosen, for the manuals line ("Settings > Assistant").
        var modelSettingsPath: String
    }

    static func render(_ inputs: Inputs, budgetTokens: Int) -> String {
        var readings = Array(inputs.readings.suffix(maxReadings))
        var equipment = inputs.equipment
        var procedure = inputs.procedure
        var ruleChain = inputs.ruleChain

        func assemble() -> String {
            var summary = inputs.summary
            summary.lastReading = nil
            var parts: [String] = []
            var head = ["KNOWLEDGE VAULT — \(inputs.vaultName) (summary for an on-device model)."]
            if !inputs.rules.isEmpty {
                head.append("RULES:")
                head.append(contentsOf: inputs.rules.map { "- \($0)" })
            }
            parts.append(head.joined(separator: "\n"))
            parts.append(summary.render())
            if let equipment, !equipment.isEmpty { parts.append(equipment) }
            if !readings.isEmpty {
                parts.append("Readings on this unit (oldest first): " + readings.joined(separator: "; ") + ".")
            }
            if let procedure, !procedure.isEmpty { parts.append(procedure) }
            if let ruleChain, !ruleChain.isEmpty { parts.append(ruleChain) }
            parts.append(manualsLine(fieldToolsOffered: inputs.fieldToolsOffered,
                                     settingsPath: inputs.modelSettingsPath))
            return parts.joined(separator: "\n\n")
        }

        var text = assemble()
        func fits() -> Bool { estimatedTokens(text) <= budgetTokens }
        while !fits(), !readings.isEmpty {
            readings.removeFirst()
            text = assemble()
        }
        if !fits(), equipment != nil {
            equipment = nil
            text = assemble()
        }
        if !fits(), ruleChain != nil {
            ruleChain = nil
            text = assemble()
        }
        if !fits(), let full = procedure {
            // Condense on a sentence boundary, never below a line: the step's title and the
            // instruction lead the block, so they are what survives.
            let over = (estimatedTokens(text) - budgetTokens) * 4
            procedure = OnDeviceToolSchema.condense(full, limit: max(full.count - over, 160))
            text = assemble()
        }
        return text
    }

    /// The line that keeps the model from answering a manual question from its own weights.
    static func manualsLine(fieldToolsOffered: Bool, settingsPath: String) -> String {
        if fieldToolsOffered {
            return "MANUALS: the vault's reference files, safety notes and manual passages are not in this prompt. "
                + "Read them with the tools: table_lookup for a value in a table, show_source for a cited page, "
                + "equipment_lookup for a vault file (safety.md before any step that opens a panel, the gas train "
                + "or the burner box). Never give a specification, a code's meaning or a procedure from memory; "
                + "if the tools do not give it, say it is not in the manual."
        }
        return AppleOnDeviceInstructions.manualsNote(settingsPath: settingsPath)
            + " Before any step that opens a panel, the gas train or the burner box, tell the technician to "
            + "follow the vault's safety notes."
    }

    /// The estimate the local path budgets with (four characters a token).
    static func estimatedTokens(_ text: String) -> Int {
        HandoffTranscriptBridge.estimatedTokens(text)
    }
}
