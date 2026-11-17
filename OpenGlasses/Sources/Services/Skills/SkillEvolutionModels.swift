import Foundation

/// An unsatisfactory turn worth learning from — the raw signal the evolution loop harvests. Captured
/// from tool errors, explicit user corrections, and retried/abandoned requests. See [[EvolutionTrigger]].
struct FailureSample: Equatable {
    enum Kind: String, Codable, Equatable {
        case toolError        // a tool call errored
        case userCorrection   // the user said "no, that's wrong" / "I meant…"
        case retry            // the user re-asked the same thing
        case abandoned        // the request was dropped without resolution
    }
    let kind: Kind
    let prompt: String
    let response: String
    let toolName: String?
    let userCorrection: String?
    let at: Date

    init(kind: Kind, prompt: String, response: String = "",
         toolName: String? = nil, userCorrection: String? = nil, at: Date) {
        self.kind = kind
        self.prompt = prompt
        self.response = response
        self.toolName = toolName
        self.userCorrection = userCorrection
        self.at = at
    }
}

/// A proposed skill — a `SKILL.md`-style trigger→action the loop suggests for human review. Becomes an
/// installed/voice skill only after the user approves it (never auto-applied). See [[SkillProposal]].
struct SkillDraft: Equatable {
    let name: String         // slug: ^[a-z][a-z0-9-]+$
    let trigger: String      // when to apply ("when the user asks X")
    let instruction: String  // what to do ("do Y; avoid Z")

    /// Tokens used for dedup — name + trigger.
    var nameTokens: Set<String> { SkillDraft.tokenize("\(name) \(trigger)") }
    /// Tokens used for dedup — the instruction body.
    var bodyTokens: Set<String> { SkillDraft.tokenize(instruction) }

    static func tokenize(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }
}

/// Pure builder for the evolution analysis prompt — turns a failure batch into the instruction the LLM
/// answers. Kept separate from the LLM call so the prompt shape is testable.
enum SkillEvolutionPrompt {
    static let system = """
    You improve an assistant by proposing ONE small reusable skill from a batch of failed interactions. \
    A skill is a trigger→action rule that would have avoided the recurring mistake. Respond with exactly \
    three lines and nothing else:
    name: <kebab-case-slug>
    trigger: <when to apply, one phrase>
    instruction: <what to do; what to avoid>
    If there is no clear recurring pattern, reply with the single word: none
    """

    /// The variant used when the batch is mostly "no tool could get X": the answer may instead be
    /// one line suggesting an add-on, which only ever becomes a suggestion in the inbox.
    static let systemAllowingAddOnIdea = system + """

    If the failures are mostly the assistant having no way to look something up from the web     (live data such as tide times, a transport timetable or a public service's status), you may     instead reply with exactly one line:
    addon-idea: <what an add-on should look up, in a few plain words>
    """

    /// The system prompt for this batch.
    static func systemPrompt(for samples: [FailureSample]) -> String {
        AddOnIdeaClassifier.isDominatedByMissingCapability(samples) ? systemAllowingAddOnIdea : system
    }

    static func build(_ samples: [FailureSample]) -> String {
        var out = "Failed interactions:\n"
        for (i, s) in samples.enumerated() {
            out += "\n\(i + 1). [\(s.kind.rawValue)]"
            if let t = s.toolName { out += " tool=\(t)" }
            out += "\n   user: \(s.prompt.prefix(300))"
            if !s.response.isEmpty { out += "\n   assistant: \(s.response.prefix(300))" }
            if let c = s.userCorrection { out += "\n   correction: \(c.prefix(300))" }
        }
        out += "\n\nPropose one skill that addresses the recurring failure."
        return out
    }
}
