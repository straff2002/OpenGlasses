import Foundation

/// The instructions Apple's on-device model is given for a turn, built to fit its window.
///
/// The model has 4,096 tokens for its instructions, its tool definitions (up to
/// `AppleOnDeviceToolSet.definitionBudgetTokens`, 1,500) and the conversation and answer together.
/// The prompt the other on-device path uses is the full persona plus the app guide, the safety
/// policy and every context block — a field report measured 7,164 characters before the tools, and
/// with a Field Assist job open the job and manual passages added 28,000 more. That cannot fit, so
/// this path has its own instructions under `characterBudget` (about 1,200 tokens at four
/// characters a token):
///
/// - the wearer's persona, without its camera section (this model never sees a photo), condensed
///   on a sentence boundary with `AppleToolSchema.condense` only when it does not fit whole;
/// - the authored short app guide, spoken manners and safety policy
///   (`SystemPromptBuilder.onDeviceAppGuide`, `.onDeviceSpokenManners`,
///   `PromptInjectionPolicy.onDeviceSystemPromptPolicy`) — every rule kept, in fewer words, rather
///   than the long ones cut off mid-list;
/// - a compact job summary while a job is open, never manual passages, and a plain line that
///   manual answers need a cloud model on this phone;
/// - memory, clipped; the date and time and the location, always; the weather when fetched.
///
/// Pure. `blocks` names every part and its size, so the support report's "sent:" line describes
/// what was actually sent.
enum AppleOnDeviceInstructions {

    /// Everything that is not a tool definition.
    static let characterBudget = 4_800
    /// The persona is never condensed below this while an optional block can still be dropped.
    static let personaFloor = 500
    static let locationLimit = 240
    static let weatherLimit = 300
    static let memoryLimit = 400

    /// The open job, as much of it as the model needs to keep the job going by voice.
    struct JobSummary: Equatable {
        var reference: String?
        /// The unit being worked on, as the vault spells its model.
        var unit: String?
        /// Open tasks on the current unit, most recent last, with their status.
        var openTasks: [String]
        /// The latest reading still standing ("supply air 140 °F").
        var lastReading: String?
        /// What the job is waiting on the technician for: the job number, a change of unit.
        var questions: [String]
        var paused: Bool

        static let maxTasks = 4
        static let fieldLimit = 80

        func render() -> String {
            func clip(_ text: String) -> String { AppleToolSchema.condense(text, limit: Self.fieldLimit) }
            var lines = ["FIELD ASSIST JOB (summary; the equipment manuals are not loaded on this model):"]
            lines.append("Job: \(reference.map(clip) ?? "number not recorded yet"). Unit: \(unit.map(clip) ?? "not identified yet").")
            if openTasks.isEmpty {
                lines.append("Open tasks: none.")
            } else {
                let shown = openTasks.suffix(Self.maxTasks).map(clip)
                let more = openTasks.count - shown.count
                lines.append("Open tasks: " + shown.joined(separator: "; ") + (more > 0 ? " (and \(more) earlier)." : "."))
            }
            if let lastReading { lines.append("Last reading: \(clip(lastReading)).") }
            for question in questions.prefix(2) { lines.append("Waiting on the technician: \(clip(question)).") }
            if paused {
                lines.append("The job is PAUSED: answer other topics normally and change the job only when they name it; "
                    + "\"end\" or \"stop\" alone ends the conversation, not the job. To carry on, call field_session with action 'resume'.")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Inputs: Equatable {
        var persona: String
        var appGuide: String
        /// The two-line spoken manners (`SystemPromptBuilder.onDeviceSpokenManners`). Empty leaves
        /// the block out.
        var spokenManners: String = ""
        var safetyPolicy: String
        /// "Monday, 20 October 2026, 9:14 AM (Pacific/Auckland)".
        var dateTime: String
        var location: String?
        var memory: String?
        var weather: String?
        var job: JobSummary?
        /// Field Assist is on, so the manuals line is said even before a job opens.
        var fieldAssistActive: Bool
        /// Where the AI model is chosen, for the manuals line ("Settings > Assistant").
        var modelSettingsPath: String
        var speakerLine: String
        /// The line that manual answers need a cloud model. True on the device; a cloud model that
        /// is given these instructions to fit an allowance (Plan KL P1) is that cloud model.
        var includesManualsNote: Bool = true
    }

    struct Built: Equatable {
        let text: String
        let blocks: [TurnTimeline.PromptBlock]
        /// Memory characters the clip left out, for the turn's memory snapshot.
        let memoryDroppedCharacters: Int
    }

    static func build(_ inputs: Inputs, budget: Int = characterBudget) -> Built {
        var memoryDropped = 0
        let memory: String? = inputs.memory
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { text in
                var clipped = text
                if text.count > memoryLimit {
                    clipped = String(text.prefix(memoryLimit)) + "…"
                    memoryDropped = text.count - memoryLimit
                }
                // Plan LN §5: the two-line manners ride with the memory, and leave with it when
                // the budget drops the block.
                return "Known about the user: \(clipped)\nTo remember a fact the user shares, add "
                    + "[REMEMBER: key = value] to your reply; to forget one, [FORGET: key]. The tags are removed before speaking.\n"
                    + MemoryMannersPrompt.shortForm
            }

        // The parts after the persona, in order. Optional ones are dropped, weather first, only if
        // keeping them would squeeze the persona below its floor.
        var parts: [(name: String, text: String, optional: Int?)] = [
            ("app guide (on-device)", inputs.appGuide, nil),
        ]
        if !inputs.spokenManners.isEmpty {
            parts.append(("spoken manners (on-device)", inputs.spokenManners, nil))
        }
        if let job = inputs.job {
            parts.append(("field assist: job summary", job.render(), nil))
        }
        if inputs.includesManualsNote, inputs.job != nil || inputs.fieldAssistActive {
            parts.append(("field assist: manuals note", manualsNote(settingsPath: inputs.modelSettingsPath), nil))
        }
        if let memory { parts.append(("memory", memory, 1)) }
        parts.append(("date and time", "CURRENT DATE & TIME: \(inputs.dateTime)", nil))
        if let location = nonEmpty(inputs.location) {
            parts.append(("location", "USER LOCATION: " + AppleToolSchema.condense(location, limit: locationLimit), 2))
        }
        if let weather = nonEmpty(inputs.weather) {
            parts.append(("weather", "CURRENT WEATHER (fetched just now; answer from this, do not call get_weather): "
                + AppleToolSchema.condense(weather, limit: weatherLimit), 0))
        }
        parts.append(("speaker", inputs.speakerLine, nil))
        parts.append(("safety policy (on-device)", inputs.safetyPolicy, nil))

        let separator = "\n\n"
        func fixedCharacters() -> Int { parts.reduce(0) { $0 + separator.count + $1.text.count } }
        var personaBudget = budget - fixedCharacters()
        for rank in 0...2 where personaBudget < personaFloor {
            parts.removeAll { $0.optional == rank }
            personaBudget = budget - fixedCharacters()
        }

        let fullPersona = personaWithoutCamera(inputs.persona)
        let persona = fullPersona.count <= personaBudget
            ? fullPersona
            : AppleToolSchema.condense(fullPersona, limit: max(personaBudget - 1, 0))
        let personaName = persona == fullPersona ? "system prompt" : "system prompt (condensed)"

        var text = persona
        var blocks: [TurnTimeline.PromptBlock] = []
        if !persona.isEmpty { blocks.append(.init(name: personaName, characters: persona.count)) }
        for part in parts where !part.text.isEmpty {
            let piece = text.isEmpty ? part.text : separator + part.text
            text += piece
            blocks.append(.init(name: part.name, characters: piece.count))
        }
        let keptMemory = parts.contains { $0.name == "memory" }
        return Built(text: text, blocks: blocks,
                     memoryDroppedCharacters: keptMemory ? memoryDropped : (inputs.memory?.count ?? 0))
    }

    /// The line that keeps the model from answering a manual question from its own weights.
    static func manualsNote(settingsPath: String) -> String {
        "MANUALS: this on-device model cannot read the equipment manuals. When asked something only a manual "
            + "answers (a specification, wiring, a fault code, a procedure), say plainly that manual answers need a "
            + "cloud model on this phone, chosen in \(settingsPath), and do not answer from memory."
    }

    /// The persona without its camera section: this model is never sent a photo, and the section
    /// insists it can see one.
    static func personaWithoutCamera(_ persona: String) -> String {
        persona
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("VISION & CAMERA") }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension AppleOnDeviceInstructions.JobSummary {
    /// The summary of an open job. Task titles and readings are the technician's own words; this
    /// prompt never leaves the phone.
    init(session: FieldSession) {
        reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        unit = session.equipment?.modelToken
        openTasks = session.tasks
            .filter { $0.status.isOpen && session.belongsToCurrentEquipment($0) }
            .map { task in
                switch task.status {
                case .inProgress: return "\(task.title) (in progress)"
                case .recommended: return "\(task.title) (recommended, not yet accepted)"
                default: return task.title
                }
            }
        let superseded = Set(session.spokenReadings.compactMap(\.supersedes))
        // A rule chain's read-back is many lines with citations, not a reading to repeat here.
        lastReading = session.spokenReadings.last { !superseded.contains($0.id) && !$0.isRuleChain }.map { reading in
            [reading.quantity, reading.value, reading.unit].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        var questions: [String] = []
        if session.jobIntake.isOutstanding { questions.append("the job number; ask for it") }
        if let pending = session.pendingUnitChange {
            questions.append("a yes or no to switching the unit to \(pending.candidate.modelToken)")
        }
        self.questions = questions
        paused = session.pausedAt != nil
    }
}
