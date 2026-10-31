import Foundation

/// How a model number the technician stated relates to the vault's model sections (Plan GB P2).
///
/// Job 1011 had two furnaces. The first, `SLP99UH070XB36B`, is not a model the vault covers, so
/// nothing was recorded for it at all. The second was said as `SLP99UH090XV48C` and recorded as
/// the vault's heading `SLP99UH090XV48CK`, because the lookup substring-matched and then wrote the
/// *heading* down instead of what was said. The record should carry both facts separately: what the
/// technician stated, always, and — as evidence about it — which vault section it matched and how.
///
/// Pure over a string and an index.
enum EquipmentRecognition {

    enum Resolution: Equatable {
        /// The stated model is a section's own name.
        case exact(model: VaultModelIndex.Model)
        /// The stated model is one of the spellings a section lists.
        case alias(model: VaultModelIndex.Model, spelling: String)
        /// Close to exactly one section's spelling: "did you mean …?".
        case near(model: VaultModelIndex.Model, spelling: String, distance: Int)
        /// A member of the series the whole vault is written for, not one of the sizes its model
        /// list details — covered by the manuals all the same.
        case series(stem: String, file: String)
        /// Nothing the vault covers. Still a real machine if the technician says it is.
        case unmatched

        var model: VaultModelIndex.Model? {
            switch self {
            case .exact(let model), .alias(let model, _), .near(let model, _, _): return model
            case .series, .unmatched: return nil
            }
        }

        var kind: EquipmentIdentity.VaultMatch.Kind? {
            switch self {
            case .exact: return .exact
            case .alias: return .alias
            case .near: return .near
            case .series: return .series
            case .unmatched: return nil
            }
        }

        /// Whether the vault covers the stated machine: one of its sections, or its series.
        var isCovered: Bool { kind != nil }
    }

    /// Within two insertions or deletions. A changed character counts as two, deliberately: a
    /// letter dropped off the end is usually the same machine said short (`…48C` for `…48CK`),
    /// while a letter *changed* in the middle is usually a different product line (`…070XB36B` is
    /// not `…070XV36BK`, and the field test's first unit was exactly that).
    static let maximumNearDistance = 2

    /// A stated model shorter than this is a fragment ("the 070"), which the correction path
    /// matches by substring; it is never fuzzily matched.
    static let minimumNearLength = 8

    /// A tester's `SLP99UH090XV36BK` is two edits from both `…090XV36CK` and `…070XV36BK`, so no
    /// single section claimed it — and the job then told the technician, every turn, that the
    /// universal SLP99UH manuals did not cover their SLP99UH furnace. A model in the vault's series
    /// that no one section claims is the series' (`VaultModelIndex.seriesStem`).
    static func resolve(stated: String, index: VaultModelIndex) -> Resolution {
        let section = resolveSection(stated: stated, index: index)
        guard section == .unmatched, let stem = index.series(of: stated) else { return section }
        return .series(stem: stem, file: index.models.first?.file ?? "")
    }

    private static func resolveSection(stated: String, index: VaultModelIndex) -> Resolution {
        let wanted = normalised(stated)
        guard !wanted.isEmpty, !index.isEmpty else { return .unmatched }
        if let model = index.models.first(where: { normalised($0.name) == wanted }) {
            return .exact(model: model)
        }
        for model in index.models {
            if let spelling = model.tokens.first(where: { normalised($0) == wanted }) {
                return .alias(model: model, spelling: spelling)
            }
        }
        guard wanted.count >= minimumNearLength else { return .unmatched }
        var best: (model: VaultModelIndex.Model, spelling: String, distance: Int)?
        var tied = false
        for model in index.models {
            let spellings = [model.name] + model.tokens
            guard let closest = spellings
                .map({ (spelling: $0, distance: distance(wanted, normalised($0))) })
                .min(by: { $0.distance < $1.distance }) else { continue }
            guard closest.distance <= maximumNearDistance else { continue }
            if let current = best {
                if closest.distance < current.distance {
                    best = (model, closest.spelling, closest.distance)
                    tied = false
                } else if closest.distance == current.distance, current.model != model {
                    tied = true
                }
            } else {
                best = (model, closest.spelling, closest.distance)
            }
        }
        // Two sections equally close is not a suggestion, it is a guess.
        guard let best, !tied else { return .unmatched }
        return .near(model: best.model, spelling: best.spelling, distance: best.distance)
    }

    /// Upper-case letters and digits only: "SLP99UH-090 XV48C" and "slp99uh090xv48c" are one model.
    static func normalised(_ text: String) -> String {
        String(text.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// Insertions and deletions only (a substitution costs two).
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return x.count + y.count - 2 * previous[y.count]
    }

    /// The identity to record for what the technician stated: the statement kept as said, the vault
    /// section it matched (if any) alongside it.
    static func identity(stated: String, resolution: Resolution, source: EquipmentIdentity.Source,
                         recognisedAt: Date = Date(),
                         nameplateText: String? = nil) -> EquipmentIdentity {
        let said = stated.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .series(let stem, let file) = resolution {
            let name = EquipmentIdentity.seriesName(stem)
            return EquipmentIdentity(modelToken: said, heading: name, file: file, source: source,
                                     recognisedAt: recognisedAt, nameplateText: nameplateText,
                                     statedModel: said,
                                     vaultMatch: .init(heading: name, section: name, kind: .series))
        }
        guard let model = resolution.model, let kind = resolution.kind else {
            // Out of the vault: the unit is keyed by what was said, and no section answers for it.
            return EquipmentIdentity(modelToken: said, heading: said, file: "", source: source,
                                     recognisedAt: recognisedAt, nameplateText: nameplateText,
                                     statedModel: said, vaultMatch: nil)
        }
        return EquipmentIdentity(model: model, token: model.name, source: source,
                                 recognisedAt: recognisedAt, nameplateText: nameplateText,
                                 statedModel: said,
                                 vaultMatch: .init(heading: model.heading, section: model.name, kind: kind))
    }
}

// MARK: - Reading a unit out of words (Plan KE P1)

extension EquipmentRecognition {

    /// What a piece of text says about the machine: nothing, more than one of the vault's models,
    /// or one unit, ready to record. The one reading `equipment_lookup` and a turn's own words share.
    enum Reading: Equatable {
        case nothing
        case several([VaultModelIndex.Model])
        case unit(EquipmentIdentity)
    }

    static func reading(of text: String, source: EquipmentIdentity.Source, index: VaultModelIndex,
                        nameplateText: String? = nil) -> Reading {
        guard !index.isEmpty else { return .nothing }
        let matches = index.match(text: text)
        guard !matches.isEmpty else {
            // A member of the vault's series that no listed size claims is still a machine these
            // manuals are for, and recognising it is what keeps the turn from being refused.
            guard let member = index.seriesMember(in: text) else { return .nothing }
            let identity = identity(stated: member, resolution: resolve(stated: member, index: index),
                                    source: source, nameplateText: nameplateText)
            return identity.isSeriesMember ? .unit(identity) : .nothing
        }
        guard matches.count == 1 else { return .several(matches) }
        return .unit(identity(for: matches[0], in: text, source: source, index: index,
                              nameplateText: nameplateText))
    }

    /// The identity to record for a model the text named (Plan GB P2). A spoken model keeps what
    /// was said beside the section it matched and how; a nameplate, a work order and a tap on the
    /// phone's list are the vault's own spelling, recorded as before.
    static func identity(for model: VaultModelIndex.Model, in text: String,
                         source: EquipmentIdentity.Source, index: VaultModelIndex,
                         nameplateText: String? = nil) -> EquipmentIdentity {
        guard source == .spoken,
              let stated = VaultModelIndex.modelLikeTokens(in: text)
                .filter({ index.resolve(token: $0).contains(model) })
                .max(by: { $0.count < $1.count }) else {
            return EquipmentIdentity(model: model, token: model.name, source: source,
                                     nameplateText: nameplateText)
        }
        let resolution = resolve(stated: stated, index: index)
        let kind = resolution.model == model ? (resolution.kind ?? .partial) : .partial
        return EquipmentIdentity(model: model, token: model.name, source: source,
                                 nameplateText: nameplateText, statedModel: stated,
                                 vaultMatch: .init(heading: model.heading, section: model.name, kind: kind))
    }

    /// How a recognised unit stands against the one the job is on.
    enum Change: Equatable {
        /// No unit yet.
        case firstUnit
        /// The unit already active, said no more fully than it was.
        case sameUnit
        /// The unit already active, said more fully: a suffix the first statement left off.
        case fullerSpelling
        /// Another machine, which is the technician's question to answer, not this type's.
        case anotherUnit
    }

    static func change(from active: EquipmentIdentity?, to identity: EquipmentIdentity) -> Change {
        guard let active else { return .firstUnit }
        guard active.heading == identity.heading else { return .anotherUnit }
        let (before, after) = (active.unitKey, identity.unitKey)
        if after.count > before.count, after.hasPrefix(before) { return .fullerSpelling }
        // Two members of a series share a heading and are still two machines.
        return active.isSeriesMember && after != before ? .anotherUnit : .sameUnit
    }

    /// The unit a technician's own words record, or nil when they record none.
    ///
    /// One test job ran fourteen minutes with no model scope because equipment was only ever set by
    /// the model choosing to call `equipment_lookup`. A turn naming exactly one of the vault's models
    /// counts by itself in two cases: there is no unit yet, or it is a fuller spelling of the active
    /// one. Another model stays with `equipment_lookup` and its job-change question, so a machine
    /// mentioned in passing moves nothing. Several models, a denial ("it's not the QX100") and job
    /// bookkeeping record nothing either. Pure.
    static func unitSaid(in turn: String, active: EquipmentIdentity?,
                         index: VaultModelIndex) -> (identity: EquipmentIdentity, change: Change)? {
        guard ManualTurnClassifier.classify(turn) != .jobBookkeeping else { return nil }
        let text = ManualTurnScope.removingJobReferences(from: turn)
        guard case .unit(let identity) = reading(of: text, source: .spoken, index: index),
              identity.isSeriesMember || index.namesOneModel(in: text),
              !denies(identity.stated, in: text) else { return nil }
        let change = change(from: active, to: identity)
        return change == .firstUnit || change == .fullerSpelling ? (identity, change) : nil
    }

    private static func denies(_ stated: String, in text: String) -> Bool {
        guard let said = text.range(of: stated, options: .caseInsensitive) else { return false }
        return TechnicianRequest.words(String(text[..<said.lowerBound])).suffix(3).contains(where: denials.contains)
    }

    private static let denials: Set<String> = ["not", "isnt", "wasnt", "arent", "never"]

    /// Whether `text` names the active unit and no other thing with a number in it, so recording it
    /// again could change nothing: every such word is part of what was stated. A fuller spelling, a
    /// fault code beside the model and another model are not. Reads the text's runs whole, hyphens
    /// kept: `QX100-A2` is not `QX100`.
    static func restates(_ active: EquipmentIdentity, in text: String) -> Bool {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted
        let runs = text.components(separatedBy: separators).filter { $0.contains(where: \.isNumber) }
        return !runs.isEmpty && runs.allSatisfy { active.unitKey.contains(normalised($0)) }
    }
}
