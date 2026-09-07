import Foundation

/// What the session believes is in front of the technician.
///
/// Recognition already existed and was thrown away after every answer: `equipment_lookup` read a
/// nameplate, matched it against the vault's model sections, answered, and forgot. This is the
/// memory — one model, recorded once, carried by the session until it is corrected or cleared.
struct EquipmentIdentity: Codable, Equatable {
    /// The spelling that matched, as the vault writes it.
    let modelToken: String
    /// The model section's whole heading — the alternate spellings ride along with it.
    let heading: String
    /// Core file the heading lives in.
    let file: String
    let source: Source
    let recognisedAt: Date
    /// What the camera actually read, when the camera read it.
    ///
    /// **Audit only.** A nameplate carries a serial number and often a site sticker; it is kept so
    /// an exported session can show what the recognition was based on, and it is never placed in a
    /// prompt or sent to a provider.
    let nameplateText: String?

    enum Source: String, Codable, CaseIterable {
        /// The technician read the model aloud, or corrected it by voice.
        case spoken
        /// Read off the nameplate by on-device recognition.
        case nameplate
        /// The work order's asset id was itself a model this vault knows.
        case asset
        /// Picked from the vault's own model list on the session card.
        case manual

        /// How the recognition is described in a sentence: "(from the nameplate)".
        var provenancePhrase: String {
            switch self {
            case .spoken: return "from the technician"
            case .nameplate: return "from the nameplate"
            case .asset: return "from the work order"
            case .manual: return "picked on the phone"
            }
        }
    }

    /// The wall clock a recognition is reported at — fixed format, fixed locale, so the prompt
    /// block, the session card and the exported record all say the same thing.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    init(modelToken: String, heading: String, file: String, source: Source,
         recognisedAt: Date = Date(), nameplateText: String? = nil) {
        self.modelToken = modelToken
        self.heading = heading
        self.file = file
        self.source = source
        self.recognisedAt = recognisedAt
        self.nameplateText = nameplateText
    }

    init(model: VaultModelIndex.Model, token: String? = nil, source: Source,
         recognisedAt: Date = Date(), nameplateText: String? = nil) {
        self.init(modelToken: token ?? model.name, heading: model.heading, file: model.file,
                  source: source, recognisedAt: recognisedAt, nameplateText: nameplateText)
    }

    /// How the recognition is described in a sentence: "(from the nameplate)".
    var provenancePhrase: String { source.provenancePhrase }

    /// The line the model sees at the top of every turn while this equipment is active.
    var promptBlock: String {
        "ACTIVE EQUIPMENT: \(modelToken) — \"\(heading)\" (\(provenancePhrase), "
            + "\(Self.clock(recognisedAt))). Answer for this model; say when a passage is for another model."
    }

    /// What the tool prefixes its answer with once it has recorded the machine.
    var announcement: String { "Active equipment: \(modelToken) (\(provenancePhrase))." }
}

/// Is the question about a machine these manuals are for?
///
/// The measured evidence gate (Plan EJ §2) answers "does this passage share words with the
/// question", and on a real OEM manual a quarter of out-of-scope questions still pass it — every
/// one of them about a subject the manual genuinely covers, asked about a machine it does not
/// ("replace the heat exchanger on a Carrier 58MVB"). No similarity or lexical rule can separate
/// those, because the passages really are about heat exchangers. Comparing the *equipment* can.
///
/// Pure over an index and the turn's text. Three rules, in this order:
///  1. A model-like token the vault has never heard of, in a turn that names no model it does know,
///     is another manufacturer's machine → refuse with the vault's own model list.
///  2. A model it knows that is not the active one is answered, not refused — a technician does
///     compare units — and the prompt is told which model was asked about.
///  3. Everything else is in scope, including every question that names no model at all.
enum EquipmentScopeCheck {

    enum Outcome: Equatable {
        case inScope
        /// A machine this vault is not about. `sentence` is the refusal, verbatim.
        case unknownEquipment(token: String, sentence: String)
        /// A model the vault covers, but not the one the session is working on.
        case otherKnownModel(token: String, model: String)

        var refusalSentence: String? {
            if case .unknownEquipment(_, let sentence) = self { return sentence }
            return nil
        }
    }

    /// - Parameters:
    ///   - text: what the technician said, or the query a tool was given.
    ///   - nameplateText: the camera's reading, when the camera path was taken. A nameplate carries
    ///     a serial number, which is model-like and belongs to no model — so a read that resolves
    ///     to a model at all puts the whole turn in scope and its other tokens are ignored.
    ///   - index: the vault's models. An empty index makes this a no-op by construction.
    static func check(text: String?, nameplateText: String? = nil,
                      index: VaultModelIndex, active: EquipmentIdentity?) -> Outcome {
        guard !index.isEmpty else { return .inScope }
        let combined = [text, nameplateText].compactMap { $0 }.joined(separator: " ")
        let tokens = VaultModelIndex.modelLikeTokens(in: combined)
        guard !tokens.isEmpty else { return .inScope }

        let known = tokens.filter { index.isKnown(token: $0) }
        guard !known.isEmpty else {
            let token = tokens[0]
            return .unknownEquipment(token: token, sentence: index.scopeSentence(unknown: token))
        }

        guard let active else { return .inScope }
        for token in known {
            let models = index.resolve(token: token)
            guard !models.isEmpty else { continue }
            if models.contains(where: { $0.heading == active.heading }) { return .inScope }
            if let other = models.first, models.count == 1 {
                return .otherKnownModel(token: token, model: other.name)
            }
        }
        return .inScope
    }

    /// The line added to the prompt when the turn asks about a different model than the active one.
    static func otherModelNote(token: String, model: String, active: EquipmentIdentity) -> String {
        "NOTE: this turn asks about \(token) (\(model)), not the active \(active.modelToken). "
            + "Answer for \(model) and say which model the answer is for."
    }
}
