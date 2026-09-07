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

    var isEmpty: Bool { models.isEmpty }

    // MARK: - Building

    init(store: VaultStore) {
        self.init(vaultName: store.manifest.name, files: store.readAll())
    }

    init(vaultName: String, files: [(filename: String, contents: String)]) {
        self.vaultName = vaultName
        var models: [Model] = []
        var known: Set<String> = []
        var all: Set<String> = []
        for (filename, contents) in files {
            all.formUnion(Self.modelLikeTokens(in: contents).map { $0.uppercased() })
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let raw = String(line)
                guard raw.hasPrefix("## ") || raw.hasPrefix("### ") else { continue }
                let heading = raw.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                let tokens = Self.modelLikeTokens(in: heading, minimumLength: Self.headingMinimumLength)
                    .map { $0.uppercased() }
                guard !tokens.isEmpty else { continue }
                let name = heading.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                models.append(Model(name: name.isEmpty ? tokens[0] : name,
                                    heading: heading, file: filename,
                                    tokens: Array(NSOrderedSet(array: tokens)) as? [String] ?? tokens))
                known.formUnion(tokens)
            }
        }
        self.models = models
        self.knownModelTokens = known
        self.vaultTokens = all.union(known)
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

    /// The models a single token names: an exact spelling first, then a spelling one is part of —
    /// OCR splits a nameplate (`SLP99UH 090XV60CK`) and a technician says half of it.
    func resolve(token: String) -> [Model] {
        let needle = token.uppercased()
        guard !needle.isEmpty else { return [] }
        let exact = models.filter { $0.tokens.contains(needle) }
        if !exact.isEmpty { return exact }
        guard needle.count >= Self.headingMinimumLength - 1 else { return [] }
        return models.filter { model in
            model.tokens.contains { spelling in
                (spelling.count >= needle.count && spelling.contains(needle))
                    || (needle.count > spelling.count && spelling.count >= 5 && needle.contains(spelling))
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

    /// A correction spoken as a fragment — "no, it's the 070". Substring over every spelling, so a
    /// size group reaches its model without being a token in its own right.
    func match(fragment: String) -> [Model] {
        let needle = fragment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard needle.count >= 2 else { return [] }
        let byToken = models.filter { $0.tokens.contains { $0.contains(needle) } }
        if !byToken.isEmpty { return byToken }
        return models.filter { $0.heading.uppercased().contains(needle) }
    }

    /// Whether the vault knows this token at all — as a model spelling, as part of one, or as
    /// anything else its core prints.
    func isKnown(token: String) -> Bool {
        let needle = token.uppercased()
        if vaultTokens.contains(needle) { return true }
        return !resolve(token: needle).isEmpty
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
