import Foundation

/// The model index a vault already contains but nobody read by machine.
///
/// The vault guide's convention — enforced by the Lennox example — puts every spelling of a model
/// in that model's own `##` heading (`## SLP99UH090XV60CK (090XV60C, -090-060C, SLP99UHXV-090-60C,
/// SLP99UH090V60CK; …)`). Reading those headings turns the core into a machine-readable list of the
/// machines the vault is about, which is what lets the session know what is in front of the
/// technician and lets the gate say "these manuals are not about that machine" instead of guessing
/// from word overlap.
///
/// Pure over the core files' text. A vault whose headings carry no model-like token yields an empty
/// index, and every identity feature keyed on it is then a no-op — which is how the bundled vaults
/// stay exactly as they were.
struct VaultModelIndex: Equatable {

    /// One model section: the heading it is titled with, the file it lives in, and every spelling
    /// of the model that heading lists.
    struct Model: Equatable {
        /// The short name — the heading up to its first parenthesis. What is spoken back.
        let name: String
        /// The whole heading line, without its `##` marker. Carries the alternate spellings, so it
        /// is what the prompt shows.
        let heading: String
        let file: String
        /// Every model-like token in the heading, uppercased, in heading order.
        let tokens: [String]
        /// The section's text under its heading, up to the next section (Plan KE P1): where a
        /// vault says which documents the model has.
        var body: String = ""

        /// `tokens` without their hyphens (`VaultModelIndex.key`), in the same order.
        var keys: [String] { tokens.map(VaultModelIndex.key) }

        /// The vault documents among `documents` this section names (Plan KE P1): those with an
        /// identifier (`documentIdentifiers`) printed anywhere in its text, however the vault lays
        /// it out. Empty for a section that names none, which is every vault that does not do this.
        func assignedDocumentIds(among documents: [(id: String, title: String)]) -> Set<String> {
            let printed = Set(VaultModelIndex.documentWords(in: body).map(VaultModelIndex.key))
            guard !printed.isEmpty else { return [] }
            return Set(documents.filter { !printed.isDisjoint(with: VaultModelIndex.documentIdentifiers(title: $0.title)) }
                .map(\.id))
        }
    }

    let vaultName: String
    /// Model sections in core-file order.
    let models: [Model]
    /// Every spelling of every model, uppercased — the set a question's tokens are checked against.
    let knownModelTokens: Set<String>
    /// Every model-like token appearing *anywhere* in the core, uppercased. A superset of
    /// `knownModelTokens`, and the reason a series name or an accessory part number a vault
    /// mentions in prose is never mistaken for another manufacturer's machine.
    let vaultTokens: Set<String>
    /// `vaultTokens` without their hyphens.
    private let vaultKeys: Set<String>

    var isEmpty: Bool { models.isEmpty }

    /// The series every model section belongs to: the start all their names share (`SLP99UH` for
    /// `SLP99UH070XV36BK` … `SLP99UH135XV60DK`), when there are several sections and it is long
    /// enough to be a product line rather than a manufacturer's letter. A vault written for a whole
    /// series covers a member the model list does not detail; nil when the sections share nothing.
    var seriesStem: String? {
        let names = seriesNames
        guard names.count >= 2, var stem = names.first else { return nil }
        for name in names.dropFirst() {
            while !name.hasPrefix(stem) { stem.removeLast() }
        }
        guard stem.count >= Self.seriesMinimumLength, stem.contains(where: \.isNumber),
              stem.contains(where: \.isLetter) else { return nil }
        return stem
    }

    static let seriesMinimumLength = 5

    /// The section names the series is read from: those that are one model number (a heading such
    /// as `R-454B (A2L) refrigerant detection` is a topic, not a model), in the group that starts
    /// alike — when that group is more than half of them. A vault covering several product
    /// families (`QRF…`, `QRS…`, `QXT…`) is not written for whichever family happens to list the
    /// most models, so its largest group is no series; a strict majority also rules out a tie.
    private var seriesNames: [String] {
        let single = models.map(\.name)
            .filter { !$0.contains(where: \.isWhitespace) }
            .map(EquipmentRecognition.normalised)
            .filter { $0.count > Self.seriesMinimumLength }
        let groups = Dictionary(grouping: single) { String($0.prefix(Self.seriesMinimumLength)) }
            .values.sorted { $0.count > $1.count }
        guard let largest = groups.first, largest.count >= 2, largest.count * 2 > single.count else { return [] }
        return largest
    }

    /// What every listed name looks like after the stem, position by position: the character
    /// itself where all of them agree (`XV`, the closing `K`), else digit or letter. Nil when the
    /// names differ in length or in kind at a position — no shape to hold a stranger to.
    private var seriesShape: [ShapeSlot]? {
        guard let stem = seriesStem else { return nil }
        let rests = seriesNames.map { Array($0.dropFirst(stem.count)) }
        guard let length = rests.first?.count, length > 0, rests.allSatisfy({ $0.count == length }) else {
            return nil
        }
        var shape: [ShapeSlot] = []
        for position in 0..<length {
            let column = rests.map { $0[position] }
            if Set(column).count == 1 {
                shape.append(.literal(column[0]))
            } else if column.allSatisfy(\.isNumber) {
                shape.append(.digit)
            } else if column.allSatisfy(\.isLetter) {
                shape.append(.letter)
            } else {
                return nil
            }
        }
        return shape
    }

    private enum ShapeSlot: Equatable {
        case literal(Character), digit, letter

        func admits(_ character: Character) -> Bool {
            switch self {
            case .literal(let expected): return character == expected
            case .digit: return character.isNumber
            case .letter: return character.isLetter
            }
        }
    }

    /// The series `token` is a member of: the stem, then the series' own shape — said whole, or
    /// one character short as a model is often said (`…36B` for `…36BK`). `SLP99UH090XV36BK` is a
    /// member; `SLP99UH070XB36B` is not, because every listed model has `XV` there, and a changed
    /// letter is another product (Job 1011).
    func series(of token: String) -> String? {
        guard let stem = seriesStem, let shape = seriesShape else { return nil }
        let wanted = EquipmentRecognition.normalised(token)
        guard wanted.hasPrefix(stem) else { return nil }
        let rest = Array(wanted.dropFirst(stem.count))
        guard rest.count == shape.count || rest.count == shape.count - 1, !rest.isEmpty else { return nil }
        return zip(shape, rest).allSatisfy { $0.admits($1) } ? stem : nil
    }

    /// A series member named in a sentence, as said — including one the transcriber split at the
    /// series name ("SLP 99UH090XV36BK"), joined back up.
    func seriesMember(in text: String) -> String? {
        guard seriesStem != nil else { return nil }
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }).map(String.init)
        for (i, word) in words.enumerated() {
            if series(of: word) != nil, Self.isModelLike(word) { return word }
            if i + 1 < words.count {
                let joined = word + words[i + 1]
                if series(of: joined) != nil, Self.isModelLike(joined) { return joined }
            }
        }
        return nil
    }

    // MARK: - Building

    init(store: VaultStore) {
        // A chain's heading names what it answers, never a machine (Plan JJ P2).
        self.init(vaultName: store.manifest.name,
                  files: store.readAll().filter { !VaultChains.isChainsFile($0.filename) })
    }

    init(vaultName: String, files: [(filename: String, contents: String)]) {
        self.vaultName = vaultName
        var models: [Model] = []
        var known: Set<String> = []
        var all: Set<String> = []
        var bodies: [Int: [String]] = [:]
        for (filename, contents) in files {
            all.formUnion(Self.modelLikeTokens(in: contents).map { $0.uppercased() })
            // The model section whose text is being read, by its heading's depth: a heading no
            // deeper than it ends it, and a sub-heading with no model in it stays part of it.
            var open: (section: Int, depth: Int)?
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let raw = String(line)
                let depth = raw.prefix { $0 == "#" }.count
                if depth > 0, raw.dropFirst(depth).first == " ", let section = open, depth <= section.depth { open = nil }
                guard raw.hasPrefix("## ") || raw.hasPrefix("### ") else {
                    if let open { bodies[open.section, default: []].append(raw) }
                    continue
                }
                let heading = raw.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                let tokens = Self.modelLikeTokens(in: heading, minimumLength: Self.headingMinimumLength)
                    .map { $0.uppercased() }
                guard !tokens.isEmpty else {
                    if let open { bodies[open.section, default: []].append(raw) }
                    continue
                }
                let name = heading.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                models.append(Model(name: name.isEmpty ? tokens[0] : name,
                                    heading: heading, file: filename,
                                    tokens: Array(NSOrderedSet(array: tokens)) as? [String] ?? tokens))
                known.formUnion(tokens)
                open = (models.count - 1, depth)
            }
        }
        for (section, lines) in bodies { models[section].body = lines.joined(separator: "\n") }
        self.models = models
        self.knownModelTokens = known
        self.vaultTokens = all.union(known)
        self.vaultKeys = Set(vaultTokens.map(Self.key))
    }

    // MARK: - Which documents a model has (Plan KE P1)

    /// The words a vault could name a document by: runs of letters, digits and hyphens with a digit
    /// in them, at least three long. Nothing about how a vault lists them is assumed beyond that,
    /// so a suffix list's `00` and a section's prose name no document.
    static func documentWords(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { $0.count >= 3 && $0.contains(where: \.isNumber) }
    }

    /// What a document goes by (keyed as `key`): its title's first word, and its number, which is
    /// any other word of the title holding both letters and digits ("Acme Service Manual A123").
    /// Vault titles carry the number; the ledger has no field for it.
    static func documentIdentifiers(title: String) -> Set<String> {
        let words = documentWords(in: title)
        let numbers = words.filter { $0.contains(where: \.isLetter) }
        let first = title.split(whereSeparator: \.isWhitespace).first.map(String.init)
            .flatMap { documentWords(in: $0).first }
        return Set((numbers + [first].compactMap { $0 }).map(key))
    }

    /// The sections of the vault's series (`seriesStem`): what a member no listed size claims has
    /// documents by.
    var seriesModels: [Model] {
        guard let stem = seriesStem else { return [] }
        return models.filter { EquipmentRecognition.normalised($0.name).hasPrefix(stem) }
    }

    // MARK: - What a model number looks like

    /// A heading token has to be a character longer than one in a question. A four-character
    /// heading token is more often a size or family label than a model (`30RB`, `30XA` in the
    /// bundled refrigeration vault), and a heading is the one place a vault author can be asked to
    /// write the model out in full; a *question* has to take what the technician says, and real
    /// model numbers that short exist (`XR15`, `XR95`).
    static let headingMinimumLength = 5
    private static let questionMinimumLength = 4

    /// Two shapes that are never a machine:
    ///  - a single letter, some digits, at most one trailing letter — `E223`, `E203`, `R-410A`,
    ///    `R-454B`, `R-22`: a fault code, or an ASHRAE refrigerant designation;
    ///  - digits with one trailing letter — `454B`, `060C`, `36B`: what falls out of splitting one
    ///    of those, or of splitting a model's own hyphenated form, and meaningless alone.
    ///
    /// Everything that makes a model number recognisable survives both: two letters running
    /// (`XR15`, `58MVB`, `GMVC96`, `SLP99UH090XV60CK`) or a long digit run (`090-060C`).
    private static let codeShape = try? NSRegularExpression(
        pattern: "^([A-Za-z]-?[0-9]{1,4}[A-Za-z]?|[0-9]{1,4}[A-Za-z])$")

    /// The model-like tokens of a piece of text, in order of first appearance, de-duplicated
    /// case-insensitively.
    ///
    /// Hyphens are kept inside a token (`SLP99UHXV-090-60C`, `-090-060C` — the manuals write both)
    /// and the hyphen-split parts are emitted too, so a nameplate read as `SLP99UH 090XV60CK` and a
    /// table row printed as `-090-060C Only` both reach the same model.
    static func modelLikeTokens(in text: String, minimumLength: Int = questionMinimumLength) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted
        var seen = Set<String>()
        var out: [String] = []
        func consider(_ candidate: Substring) {
            let token = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard isModelLike(token, minimumLength: minimumLength) else { return }
            if seen.insert(token.uppercased()).inserted { out.append(token) }
        }
        for run in text.components(separatedBy: separators) {
            guard !run.isEmpty else { continue }
            consider(run[run.startIndex...])
            if run.contains("-") {
                for part in run.split(separator: "-") { consider(part) }
            }
        }
        return out
    }

    /// `CodeTokenizer.isCodeLike` plus the length, the digit count and the shape screen above.
    static func isModelLike(_ token: String, minimumLength: Int = questionMinimumLength) -> Bool {
        guard CodeTokenizer.isCodeLike(token), token.count >= minimumLength else { return false }
        let digits = token.filter(\.isNumber).count
        guard digits >= 2, token.contains(where: \.isLetter) else { return false }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        if codeShape?.firstMatch(in: token, range: range) != nil { return false }
        return true
    }

    // MARK: - Matching

    /// A spelling as matching compares it: uppercased, without its hyphens. Cloud dictation writes
    /// a code without its hyphens whatever the vocabulary says (`XR7720` for a printed `XR-7720`),
    /// and a typed question often does too; the hyphens are the only thing dropped, so what counts
    /// as a model (`isModelLike`) and the length floors below are as before.
    static func key(_ spelling: String) -> String {
        spelling.uppercased().replacingOccurrences(of: "-", with: "")
    }

    /// The models a single token names: an exact spelling first, then a spelling one is part of —
    /// OCR splits a nameplate (`SLP99UH 090XV60CK`) and a technician says half of it. Both are
    /// compared without hyphens (`key`), so `QZ4417`, `QZ-4417` and `QZ44-17` are one spelling.
    func resolve(token: String) -> [Model] {
        let needle = Self.key(token)
        guard !needle.isEmpty else { return [] }
        let exact = models.filter { $0.keys.contains(needle) }
        if !exact.isEmpty { return exact }
        guard needle.count >= Self.headingMinimumLength - 1 else { return [] }
        return models.filter { model in
            zip(model.tokens, model.keys).contains { printed, spelling in
                (spelling.count >= needle.count && spelling.contains(needle))
                    || (needle.count > spelling.count && printed.count >= 5 && needle.contains(spelling))
            }
        }
    }

    /// The models a piece of text names — a spoken query, or a whole nameplate read.
    ///
    /// Every model-like token is resolved on its own and the resolutions are *intersected* when
    /// they overlap: `SLP99UH 090XV60CK` gives all six models from its first half and one from its
    /// second, and the machine in front of the technician is the one both halves agree on. When
    /// nothing overlaps the union is returned, so a genuinely ambiguous read asks rather than
    /// guessing.
    func match(text: String) -> [Model] {
        let resolutions = Self.modelLikeTokens(in: text)
            .map { resolve(token: $0) }
            .filter { !$0.isEmpty }
        guard !resolutions.isEmpty else { return [] }
        var intersection = resolutions[0]
        for next in resolutions.dropFirst() {
            let filtered = intersection.filter { next.contains($0) }
            if filtered.isEmpty { continue }
            intersection = filtered
        }
        return intersection
    }

    /// Whether the text names exactly one model, every model-like token in it agreeing on the same
    /// section. Stricter than `match(text:)`, which keeps its first reading when two tokens name
    /// different models: "the QX100 is fine, the QX200 trips" is an identification of neither.
    func namesOneModel(in text: String) -> Bool {
        let resolutions = Self.modelLikeTokens(in: text).map { resolve(token: $0) }.filter { !$0.isEmpty }
        guard var common = resolutions.first else { return false }
        for next in resolutions.dropFirst() { common = common.filter(next.contains) }
        return common.count == 1
    }

    /// A correction spoken as a fragment — "no, it's the 070". Substring over every spelling, so a
    /// size group reaches its model without being a token in its own right; hyphens aside, too.
    func match(fragment: String) -> [Model] {
        let needle = fragment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard needle.count >= 2 else { return [] }
        let needleKey = Self.key(needle)
        let byToken = models.filter { model in
            model.tokens.contains { $0.contains(needle) }
                || (needleKey.count >= 2 && model.keys.contains { $0.contains(needleKey) })
        }
        if !byToken.isEmpty { return byToken }
        return models.filter { $0.heading.uppercased().contains(needle) }
    }

    /// Whether the vault knows this token at all — as a model spelling, as part of one, or as
    /// anything else its core prints.
    func isKnown(token: String) -> Bool {
        let needle = token.uppercased()
        if mentions(token: needle) { return true }
        if series(of: needle) != nil { return true }
        return !resolve(token: needle).isEmpty
    }

    /// Whether the core prints this token anywhere, hyphens aside — a model spelling, or an
    /// accessory or series name in prose.
    func mentions(token: String) -> Bool {
        vaultTokens.contains(token.uppercased()) || vaultKeys.contains(Self.key(token))
    }

    /// The sentence a question about another manufacturer's machine gets back. Named models, so the
    /// technician hears what this vault *is* about rather than only what it is not.
    func scopeSentence(unknown token: String) -> String {
        let names = models.map(\.name)
        var listed = names.prefix(3).joined(separator: ", ")
        if names.count > 3 { listed += " and \(names.count - 3) more" }
        return "The loaded manuals cover \(vaultName) models \(listed); \(token) is not one of them. "
            + "Confirm the nameplate or load its manual."
    }
}
