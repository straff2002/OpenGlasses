import Foundation

// Plan LW — a trade template: the data a new vault, the prompt kits and the phone's proposal
// builders read for one trade.
//
// **Foundation only, and self-contained with `VaultStarter.swift` and `VaultDrafts.swift`.** The app
// compiles these three files into its own target (`project.base.yml`, `project.phone-only.yml`), as
// it does `VaultPackRules.swift`, so the phone and the portal make the same starter and show the
// same kits. They must not refer to anything else in this package.
//
// A template is data, not code. Every word in it is written for this app: no text is taken from a
// manual, a standard or a code book. A new trade is a new value here, written with someone who
// works in that trade, and tested on real manuals before it ships (Plan LW, Risks).

public struct TradeTemplate: Equatable, Sendable {

    public enum ID: String, CaseIterable, Sendable {
        case hvacR = "hvac_r"
        case general
    }

    /// How a unit is named in this trade, and what that name looks like.
    public struct Identity: Equatable, Sendable {
        /// What the name is, in words a prompt can use: "the model number on the nameplate".
        public let description: String
        /// What a name looks like, as an anchored regular expression over the token **uppercased**.
        public let pattern: String
    }

    /// The kind of page that should answer a vault-check question. The author picks the page itself.
    public enum PageKind: String, CaseIterable, Sendable {
        case faultCodeTable = "fault_code_table"
        case specifications
        case troubleshooting
        case wiring
        case installation
        case maintenance
        case safety
    }

    /// A starter question for the vault check (`VaultCheck`), and the kind of page that answers it.
    public struct CheckQuestion: Equatable, Sendable {
        public let text: String
        public let answerPage: PageKind
    }

    public let id: ID
    /// The name the author picks the template by: "HVAC-R".
    public let name: String
    /// The vault manifest's `trades`, or nil when the template names none (the technician's or the
    /// organisation's choice then decides the trade tiles).
    public let trades: [String]?
    /// What a prompt says the manual is about: "heating, cooling or refrigeration equipment".
    public let subject: String
    public let identity: Identity
    /// What a fault code looks like, as an anchored regular expression over the token uppercased.
    public let codePattern: String
    /// The same, in words a prompt can use.
    public let codeDescription: String
    /// The manifest's `prompt_rules`. Always carries the *fabricate* and *cite* themes
    /// (`VaultPackRules.requiredRuleThemes`).
    public let promptRules: [String]
    /// The starter `safety.md`, which the author edits to their own site rules.
    public let safetyStarter: String
    /// The `##` headings of the starter `symptoms.md`, in the words technicians use. Never a model
    /// number: a heading with one reads as a model (`VaultModelIndex`).
    public let symptomHeadings: [String]
    /// The `##` topic headings of the starter `fault-codes.md`.
    public let faultCodeSections: [String]
    public let checkQuestions: [CheckQuestion]

    /// Whether `token` looks like a fault code in this trade.
    public func isCode(_ token: String) -> Bool { Self.matches(token, codePattern) }

    /// Whether `token` looks like a unit's name in this trade.
    public func isIdentity(_ token: String) -> Bool { Self.matches(token, identity.pattern) }

    static func matches(_ token: String, _ pattern: String) -> Bool {
        let upper = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard !upper.isEmpty else { return false }
        return upper.range(of: pattern, options: .regularExpression) != nil
    }

    public static let all: [TradeTemplate] = [.hvacR, .general]

    public static func template(id: ID) -> TradeTemplate {
        switch id {
        case .hvacR: return .hvacR
        case .general: return .general
        }
    }

    // MARK: - HVAC-R

    public static let hvacR = TradeTemplate(
        id: .hvacR,
        name: "HVAC-R",
        trades: ["refrigeration_hvac"],
        subject: "heating, cooling or refrigeration equipment",
        identity: Identity(
            description: "the model number on the unit's nameplate: letters and digits, at least two digits, sometimes with dashes",
            pattern: #"^(?=(?:[^0-9]*[0-9]){2})(?=.*[A-Z])[A-Z0-9][A-Z0-9-]{3,23}$"#),
        codePattern: #"^(?:[A-Z]{1,2}-?[0-9]{1,2}|[0-9]{1,2})$"#,
        codeDescription: "one or two letters and one or two digits, or a number of one or two digits, as the controller's display shows it",
        promptRules: [
            "Never fabricate a fault code, a model, a setting, a refrigerant value or a procedure.",
            "Use only the vault contents, the retrieved manual passages and the technician's stated observations.",
            "Cite the manual and page on every factual claim.",
            "If the manuals do not cover the question, say so plainly rather than guessing.",
            "Identify the exact model first, then use only the manuals listed for it in models.md; a passage written for another model is not evidence.",
            "For a symptom in symptoms.md that applies to the unit, give its checks one at a time, in order, each with its manual and page, and say the order is this vault's, not the manufacturer's.",
            "Before any step that opens an electrical panel or the refrigerant circuit, remind the technician of the matching steps in safety.md."
        ],
        safetyStarter: """
        # Safety

        Edit these reminders to match your own site rules. The assistant repeats them before risky steps.

        ## Electrical
        - Isolate the supply, lock it off and prove it dead with a tester you have checked on a known source.
        - Treat capacitors as live until they are discharged.

        ## Refrigerant circuit
        - Wear eye and hand protection when connecting gauges or opening the circuit.
        - Recover the charge before opening the circuit. Never vent it.
        - With a flammable refrigerant, ventilate the area and keep ignition sources away.

        ## Heat and moving parts
        - Let hot lines and the compressor cool before touching them.
        - Keep hands clear of fans until they have stopped and the supply is off.

        """,
        symptomHeadings: ["Not cooling", "Not heating", "Runs all the time", "Will not start", "Ice on the coil",
                          "Water leaking", "Noisy"],
        faultCodeSections: ["Controller fault codes"],
        checkQuestions: [
            CheckQuestion(text: "What does the flashing fault light on the controller mean?", answerPage: .faultCodeTable),
            CheckQuestion(text: "Which refrigerant does this unit use, and how much is the factory charge?", answerPage: .specifications),
            CheckQuestion(text: "What superheat or subcooling should I charge to?", answerPage: .installation),
            CheckQuestion(text: "How do I test the outdoor fan motor?", answerPage: .troubleshooting),
            CheckQuestion(text: "What size of breaker or fuse does the unit need?", answerPage: .specifications),
            CheckQuestion(text: "How is the thermostat wired to the unit?", answerPage: .wiring),
            CheckQuestion(text: "How often should the filters be changed?", answerPage: .maintenance),
            CheckQuestion(text: "What clearance does the outdoor unit need around it?", answerPage: .installation)
        ])

    // MARK: - General

    public static let general = TradeTemplate(
        id: .general,
        name: "General",
        trades: nil,
        subject: "equipment",
        identity: Identity(
            description: "the model or part number on the unit's plate or label: letters and digits, sometimes with dashes",
            pattern: #"^(?=.*[0-9])(?=.*[A-Z])[A-Z0-9][A-Z0-9-]{3,23}$"#),
        codePattern: #"^(?:[A-Z]{1,2}-?[0-9]{1,4}|[0-9]{1,4}|[0-9]{1,3}[A-Z])$"#,
        codeDescription: "a short mix of letters and digits, as the unit's display or indicator shows it",
        promptRules: [
            "Never fabricate a fault code, a model, a rating, a setting or a procedure.",
            "Use only the vault contents, the retrieved manual passages and the technician's stated observations.",
            "Cite the manual and page on every factual claim.",
            "If the manuals do not cover the question, say so plainly rather than guessing.",
            "Identify the exact model first, then use only the manuals listed for it in models.md; a passage written for another model is not evidence.",
            "For a symptom in symptoms.md that applies to the unit, give its checks one at a time, in order, each with its manual and page, and say the order is this vault's, not the manufacturer's.",
            "Before any step that opens the unit or removes a guard, remind the technician of the matching steps in safety.md."
        ],
        safetyStarter: """
        # Safety

        Edit these reminders to match your own site rules. The assistant repeats them before risky steps.

        ## Before opening the unit
        - Isolate every energy source (electrical, pressure, stored spring or hydraulic energy) and lock it off.
        - Prove the supply dead with a tester you have checked on a known source.

        ## While working
        - Wear the protection your site requires for the task.
        - Keep guards in place until the unit has stopped and is isolated.

        """,
        symptomHeadings: ["Will not start", "Stops during use", "Shows a fault code", "Noisy or vibrating", "Leaking",
                          "Runs but does not do its job"],
        faultCodeSections: ["Fault codes"],
        checkQuestions: [
            CheckQuestion(text: "What does it mean when the fault light flashes?", answerPage: .faultCodeTable),
            CheckQuestion(text: "What are the unit's electrical ratings?", answerPage: .specifications),
            CheckQuestion(text: "How do I reset the unit after a fault?", answerPage: .troubleshooting),
            CheckQuestion(text: "What routine maintenance does the manual list, and how often?", answerPage: .maintenance),
            CheckQuestion(text: "What must be isolated before servicing the unit?", answerPage: .safety),
            CheckQuestion(text: "How is the unit connected to the supply?", answerPage: .wiring)
        ])
}
