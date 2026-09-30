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
        /// Nothing the vault covers. Still a real machine if the technician says it is.
        case unmatched

        var model: VaultModelIndex.Model? {
            switch self {
            case .exact(let model), .alias(let model, _), .near(let model, _, _): return model
            case .unmatched: return nil
            }
        }

        var kind: EquipmentIdentity.VaultMatch.Kind? {
            switch self {
            case .exact: return .exact
            case .alias: return .alias
            case .near: return .near
            case .unmatched: return nil
            }
        }
    }

    /// Within two insertions or deletions. A changed character counts as two, deliberately: a
    /// letter dropped off the end is usually the same machine said short (`…48C` for `…48CK`),
    /// while a letter *changed* in the middle is usually a different product line (`…070XB36B` is
    /// not `…070XV36BK`, and the field test's first unit was exactly that).
    static let maximumNearDistance = 2

    /// A stated model shorter than this is a fragment ("the 070"), which the correction path
    /// matches by substring; it is never fuzzily matched.
    static let minimumNearLength = 8

    static func resolve(stated: String, index: VaultModelIndex) -> Resolution {
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
