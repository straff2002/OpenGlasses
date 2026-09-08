import Foundation

/// Whether a turn may be sent to a cloud model to be read for relations, and what comes back if
/// it is.
///
/// The regexes in `BrainRelationExtractor` are tuned for precision: they see "Alice works at
/// Acme" and miss "Alice has been at Acme since the spring". Enrichment asks a model for what the
/// patterns cannot see — which means sending the wearer's own words off the device, so it is the
/// most conditional thing in the brain. Four conditions, all of them, or it does not run:
///
/// 1. **Agent Mode is on.** Everything autonomous in this app lives behind that switch.
/// 2. **The wearer turned enrichment on** (`Config.brainEnrichmentEnabled`, default off). Agent
///    Mode is a wide permission; this is the narrow one, asked for separately.
/// 3. **HIPAA mode is off.** Under HIPAA the brain keeps working; only the cloud pass stops.
/// 4. **The active provider is not on-device.** Not a preference: on-device inference cannot run
///    backgrounded, and a memory pass at the end of a voice turn is exactly the code most likely
///    to be running there. A local model would hang rather than answer.
///
/// Every refusal names itself, because a feature that silently does nothing is indistinguishable
/// from a broken one — but only the refusals a wearer could mistake for a fault are worth a log
/// line. See `SkipReason.isWorthLogging`.
enum RelationEnrichmentPolicy {

    /// Why a turn was not sent. A closed vocabulary, so it is safe to log verbatim.
    enum SkipReason: String, Equatable {
        case agentModeOff
        case enrichmentDisabled
        case hipaaMode
        case onDeviceProvider
        case noProvider

        /// Whether this refusal is worth a privacy-log line.
        ///
        /// A wearer who never turned enrichment on has not asked for anything, and logging a line
        /// per turn for a feature that is simply off is noise in the one place noise costs the
        /// most. The other three are refusals *after* the wearer asked — the feature looks broken
        /// unless it says why it declined — so those still name themselves.
        var isWorthLogging: Bool {
            switch self {
            case .agentModeOff, .enrichmentDisabled: return false
            case .hipaaMode, .onDeviceProvider, .noProvider: return true
            }
        }
    }

    enum Outcome: Equatable {
        case run
        case skip(SkipReason)

        var skipReason: SkipReason? {
            if case .skip(let reason) = self { return reason }
            return nil
        }

        var runs: Bool { self == .run }
    }

    /// Pure: the four conditions, in the order that gives each its own reason. `provider` is the
    /// wearer's active provider, or `nil` when no model is configured at all.
    static func decide(agentMode: Bool,
                       enrichmentEnabled: Bool,
                       hipaaMode: Bool,
                       provider: LLMProvider?) -> Outcome {
        guard agentMode else { return .skip(.agentModeOff) }
        guard enrichmentEnabled else { return .skip(.enrichmentDisabled) }
        guard !hipaaMode else { return .skip(.hipaaMode) }
        guard let provider else { return .skip(.noProvider) }
        guard !isOnDevice(provider) else { return .skip(.onDeviceProvider) }
        return .run
    }

    /// The providers that run inference on the phone. Kept here rather than inline so the reason
    /// this list exists — background inference, not privacy — is written down beside it.
    static func isOnDevice(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .local, .appleOnDevice: return true
        default: return false
        }
    }
}

/// Turns a model's structured answer into edges the graph will accept — or into nothing.
///
/// Everything here is a refusal waiting to happen, and deliberately so: this is the one place in
/// the brain where a relation is proposed by a model rather than matched by a pattern, so the
/// bounds that the regexes get for free (a closed vocabulary, a name that looks like a name, a
/// span of the wearer's actual words) have to be re-imposed by hand. What survives enters as a
/// *provisional* edge below any regex hit's confidence, so a wrong one costs one row for one
/// expiry window.
enum RelationEnrichmentParser {

    /// The most a single turn may contribute. A turn that yields nine relations is a model
    /// enumerating, not a wearer stating facts.
    static let maxRelations = 8

    /// Entity kinds the graph knows. A relation pointing at anything else is not a relation this
    /// store can render.
    static let allowedKinds: Set<String> = ["person", "org", "place", "event", "source"]

    /// Parse `object` — the decoded `{"relations": [...]}` — against `sourceText`, the exact
    /// words the model was shown. Every object must carry all six keys; the relation must be in
    /// the ontology; both names must pass the same usability bound the extractor applies; a
    /// self-loop is refused; and `evidence` must actually appear in the source, which is what
    /// stops a relation being invented out of the model's own prose rather than read out of the
    /// wearer's. The destination kind is taken from the ontology rather than from the answer:
    /// the vocabulary decides what `lives_in` points at, not the model.
    static func relations(from object: [String: Any]?,
                          sourceText: String) -> [BrainRelationExtractor.Relation] {
        guard let raw = object?["relations"] as? [[String: Any]] else { return [] }
        var accepted: [BrainRelationExtractor.Relation] = []
        for item in raw {
            guard let relation = self.relation(from: item, sourceText: sourceText) else { continue }
            guard !accepted.contains(relation) else { continue }
            accepted.append(relation)
            if accepted.count == maxRelations { break }
        }
        return accepted
    }

    /// One object, validated. `nil` for anything the graph will not store.
    private static func relation(from item: [String: Any],
                                 sourceText: String) -> BrainRelationExtractor.Relation? {
        guard let src = string(item["src"]),
              let srcKind = string(item["srcKind"]),
              let rawRelation = string(item["relation"]),
              let dst = string(item["dst"]),
              let dstKind = string(item["dstKind"]),
              let evidence = string(item["evidence"]) else { return nil }

        let canonical = RelationOntology.canonical(rawRelation)
        guard RelationOntology.isAllowed(canonical) else { return nil }
        guard allowedKinds.contains(srcKind.lowercased()),
              allowedKinds.contains(dstKind.lowercased()) else { return nil }
        guard BrainRelationExtractor.isUsableName(src),
              BrainRelationExtractor.isUsableName(dst) else { return nil }
        guard src.lowercased() != dst.lowercased() else { return nil }
        guard sourceText.range(of: evidence, options: [.caseInsensitive]) != nil else { return nil }

        return BrainRelationExtractor.Relation(
            srcKind: srcKind.lowercased(), src: src, relation: canonical,
            dstKind: RelationOntology.destinationKind(for: canonical), dst: dst)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - What the model is asked

    /// The instruction. It names the whole vocabulary, because a closed list the model cannot see
    /// is a list it will guess around, and every guess outside it is a drop.
    static var systemPrompt: String {
        """
        You read one short utterance and report the relationships stated in it.

        Reply with a JSON object: {"relations": [...]}. Each relation is
        {"src", "srcKind", "relation", "dst", "dstKind", "evidence"}.

        - "relation" must be exactly one of: \(RelationOntology.sortedRelations.joined(separator: ", ")).
        - "srcKind" and "dstKind" are one of: \(allowedKinds.sorted().joined(separator: ", ")).
        - "src" and "dst" are the names as written, nothing added.
        - "evidence" is a span copied verbatim from the utterance that states the relationship.
        - Report only what the utterance states. Do not infer, and do not guess a relationship
          that is merely likely. Report nothing at all rather than something uncertain.
        - At most \(maxRelations) relations.
        """
    }

    /// The schema forced on the provider. Same six keys the parser demands, so a well-behaved
    /// model and a strict parser agree.
    static var jsonSchema: [String: Any] {
        let kinds = allowedKinds.sorted()
        return [
            "type": "object",
            "properties": [
                "relations": [
                    "type": "array",
                    "description": "The relationships stated in the utterance; empty if none.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "src": ["type": "string", "description": "The subject's name."],
                            "srcKind": ["type": "string", "enum": kinds],
                            "relation": ["type": "string", "enum": RelationOntology.sortedRelations],
                            "dst": ["type": "string", "description": "The object's name."],
                            "dstKind": ["type": "string", "enum": kinds],
                            "evidence": ["type": "string",
                                         "description": "A span copied verbatim from the utterance."],
                        ] as [String: Any],
                        "required": ["src", "srcKind", "relation", "dst", "dstKind", "evidence"],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "required": ["relations"],
        ]
    }
}
