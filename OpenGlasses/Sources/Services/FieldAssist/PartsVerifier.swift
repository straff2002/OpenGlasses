import Foundation

/// Turns a part number somebody said into a part number somebody can order.
///
/// Base validates a number that came from the book, not one that fell out of a misheard sentence,
/// so every number written into a task or a request goes through here first: the vault's own parts
/// table, then the manuals as an exact whole token. A number nothing knows is recorded as
/// **unverified** and said out loud as unverified — never dropped, never quietly trusted.
///
/// Pure over an index and a token search, so it runs headless with no store around it.
struct PartsVerifier {

    /// The vault's parts table. Empty for a vault with none, which simply means the manuals are the
    /// only route to a verification.
    let index: VaultPartsIndex
    /// Exact whole-token search over the vault's manuals. Returns the passages a token appears in,
    /// best first. Defaults to "no manuals", so a headless caller gets core-only verification.
    var manualPassages: (String) -> [DocumentStore.Passage] = { _ in [] }

    init(index: VaultPartsIndex,
         manualPassages: @escaping (String) -> [DocumentStore.Passage] = { _ in [] }) {
        self.index = index
        self.manualPassages = manualPassages
    }

    /// Verify one number. The result is exactly what a `TaskPart` records, so nothing can be
    /// written down that this did not produce.
    func verify(_ number: String) -> TaskPart {
        let cleaned = Self.normalise(number)
        guard !cleaned.isEmpty else { return TaskPart(number: number.uppercased(), verified: false) }

        if let part = index.part(number: cleaned) {
            let fits = part.fits.isEmpty ? nil : " (fits \(part.fits))"
            return TaskPart(number: part.number.uppercased(),
                            partDescription: part.partDescription.isEmpty ? nil : part.partDescription,
                            verified: true,
                            page: VaultPartsIndex.citation(for: part) + (fits ?? ""))
        }

        if let passage = manualPassages(cleaned).first {
            return TaskPart(number: cleaned,
                            partDescription: nil,
                            verified: true,
                            page: Self.citation(for: passage))
        }

        return TaskPart(number: cleaned, verified: false)
    }

    /// Verify a list, keeping the order they were named in and dropping empty entries.
    func verify(all numbers: [String]) -> [TaskPart] {
        var seen = Set<String>()
        return numbers
            .map { verify($0) }
            .filter { !$0.number.isEmpty && seen.insert($0.number).inserted }
    }

    /// The part numbers in a list that could not be verified — what the reply names out loud.
    static func unverified(_ parts: [TaskPart]) -> [String] {
        parts.filter { !$0.verified }.map(\.number)
    }

    /// The sentence appended to a tool's reply when something could not be verified. Named
    /// numbers, because "some parts are unverified" is not something a technician can act on.
    static func unverifiedNote(_ parts: [TaskPart]) -> String? {
        let names = unverified(parts)
        guard !names.isEmpty else { return nil }
        let listed = names.joined(separator: ", ")
        return names.count == 1
            ? "\(listed) is not in the manuals loaded for this vault — it is recorded unverified. Say it again or check the label before base orders it."
            : "\(listed) are not in the manuals loaded for this vault — they are recorded unverified. Check the labels before base orders them."
    }

    // MARK: - Helpers

    /// Uppercased, stripped of the punctuation a spoken number picks up ("14T65." / "#14T65").
    static func normalise(_ number: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-/"))
        return String(number.unicodeScalars.filter { allowed.contains($0) }).uppercased()
    }

    /// "SLP99UHVK Service Manual, page 3" — the same shape every other citation in the app uses.
    static func citation(for passage: DocumentStore.Passage) -> String {
        var parts = [passage.documentName]
        if let page = passage.page { parts.append("page \(page)") }
        if let figure = passage.figure, !figure.isEmpty { parts.append(figure) }
        return parts.joined(separator: ", ")
    }
}
