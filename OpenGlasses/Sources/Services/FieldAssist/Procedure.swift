import Foundation

/// A branching, step-by-step field-service procedure loaded from a vault's `procedures/*.json`.
///
/// Procedures ground the technician through a diagnostic or task flow. Each step presents an
/// instruction and (optionally) a set of branches the AI can take based on the technician's
/// reported observation. The `ProcedureRunner` enforces the step graph; the AI evaluates which
/// branch condition matches and advances via the `procedure_runner` tool.
struct Procedure: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let version: String
    /// Vault this procedure belongs to (e.g. "refrigeration"). Informational.
    let vault: String?
    let description: String?
    /// Safety reminders injected when the procedure starts.
    let safetyNotes: [String]
    /// Id of the first step. Falls back to the first entry in `steps` when nil.
    let entryStep: String?
    let steps: [Step]

    enum CodingKeys: String, CodingKey {
        case id, title, version, vault, description, steps
        case safetyNotes = "safety_notes"
        case entryStep = "entry_step"
    }

    init(
        id: String,
        title: String,
        version: String,
        vault: String? = nil,
        description: String? = nil,
        safetyNotes: [String] = [],
        entryStep: String? = nil,
        steps: [Step]
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.vault = vault
        self.description = description
        self.safetyNotes = safetyNotes
        self.entryStep = entryStep
        self.steps = steps
    }

    /// A single step in the procedure graph.
    struct Step: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        /// The instruction spoken to the technician.
        let instruction: String
        /// What the technician is expected to report back (drives branch evaluation).
        let expectedInput: String?
        /// Step-specific safety reminder, surfaced before the instruction.
        let safetyNote: String?
        /// Optional hint linking this step to `DomainCalcTool`. Advisory — not auto-executed.
        let calcRef: CalcRef?
        /// Vault source files backing this step's instruction.
        let citations: [String]
        /// Branches the AI may take based on the technician's observation.
        let branches: [Branch]
        /// Step reached by a bare `next` (no choice). Nil when `terminal`.
        let defaultNext: String?
        /// When true, reaching this step completes the procedure.
        let terminal: Bool
        /// Outcome recorded when a terminal step is reached.
        let outcome: String?

        enum CodingKeys: String, CodingKey {
            case id, title, instruction, branches, terminal, outcome, citations
            case expectedInput = "expected_input"
            case safetyNote = "safety_note"
            case calcRef = "calc_ref"
            case defaultNext = "default_next"
        }

        init(
            id: String,
            title: String,
            instruction: String,
            expectedInput: String? = nil,
            safetyNote: String? = nil,
            calcRef: CalcRef? = nil,
            citations: [String] = [],
            branches: [Branch] = [],
            defaultNext: String? = nil,
            terminal: Bool = false,
            outcome: String? = nil
        ) {
            self.id = id
            self.title = title
            self.instruction = instruction
            self.expectedInput = expectedInput
            self.safetyNote = safetyNote
            self.calcRef = calcRef
            self.citations = citations
            self.branches = branches
            self.defaultNext = defaultNext
            self.terminal = terminal
            self.outcome = outcome
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            instruction = try c.decode(String.self, forKey: .instruction)
            expectedInput = try c.decodeIfPresent(String.self, forKey: .expectedInput)
            safetyNote = try c.decodeIfPresent(String.self, forKey: .safetyNote)
            calcRef = try c.decodeIfPresent(CalcRef.self, forKey: .calcRef)
            citations = try c.decodeIfPresent([String].self, forKey: .citations) ?? []
            branches = try c.decodeIfPresent([Branch].self, forKey: .branches) ?? []
            defaultNext = try c.decodeIfPresent(String.self, forKey: .defaultNext)
            terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        }
    }

    /// A conditional transition out of a step.
    struct Branch: Codable, Equatable, Identifiable {
        /// Stable, short identifier the AI passes as `choice` (e.g. "low", "calling").
        let id: String
        /// Human-readable condition the AI matches against the technician's observation.
        let condition: String
        /// Target step id.
        let next: String
    }

    /// Optional link from a step to a `DomainCalcTool` operation.
    struct CalcRef: Codable, Equatable {
        let tool: String
        let op: String
        let hint: String?
    }

    // MARK: - Lookups

    /// The first step to run.
    var entry: Step? {
        if let entryStep, let step = step(id: entryStep) { return step }
        return steps.first
    }

    func step(id: String) -> Step? {
        steps.first { $0.id == id }
    }
}
