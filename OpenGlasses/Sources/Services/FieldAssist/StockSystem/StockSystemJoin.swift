import Foundation

/// A part number asked about, joined across the system's snapshot and the vault's parts table
/// (Plan MM §5, HF's join). Pure.
///
/// The vault says what the book says (the part, its replacement); the system says what the shelf
/// holds. Numbers are compared after `VaultPartsIndex.normalise`. Supersession resolves in both
/// directions before the system's lines are searched, so the number on the old part finds its
/// replacement's stock, and the new number finds stock still held under the old one. An exact
/// match always wins over a superseded one.
struct StockSystemJoin {

    enum Outcome: Equatable {
        /// The system carries it and the book names it.
        case inBoth(StockSystemSnapshot.Line, vaultPart: VaultPartsIndex.Part)
        /// The book names it and the system does not carry it: "<System> doesn't carry that number."
        case vaultOnly(VaultPartsIndex.Part)
        /// The system carries it and the book does not name it. `bookSearched` is false when there
        /// was no book to search, so the answer does not claim the number was looked for.
        case systemOnly(StockSystemSnapshot.Line, bookSearched: Bool)
        /// Neither carries it.
        case neither

        /// The system's line, when it carries the part.
        var line: StockSystemSnapshot.Line? {
            switch self {
            case .inBoth(let line, _), .systemOnly(let line, _): return line
            case .vaultOnly, .neither: return nil
            }
        }
    }

    let snapshot: StockSystemSnapshot
    /// The book MK resolves for the place (`book(job:named:)`); nil when there is none.
    let parts: VaultPartsIndex?

    /// The book in Plan MK §4's order: the open job's vault, else the list's named vault, else
    /// none. A vault with no parts table is no book.
    static func book(job: VaultPartsIndex?, named: VaultPartsIndex?) -> VaultPartsIndex? {
        if let job, !job.isEmpty { return job }
        if let named, !named.isEmpty { return named }
        return nil
    }

    func join(number: String) -> Outcome {
        let wanted = VaultPartsIndex.normalise(number)
        guard !wanted.isEmpty else { return .neither }
        let book = parts.flatMap { $0.isEmpty ? nil : $0 }
        let vaultPart = book?.part(number: wanted)

        // The numbers to look for, best first: the one asked, its replacement, then the numbers
        // the asked one (or its replacement) replaced.
        var numbers = [wanted]
        if let vaultPart {
            numbers.append(VaultPartsIndex.normalise(vaultPart.number))
        }
        if let book {
            let current = Set(numbers)
            for part in book.parts where current.contains(VaultPartsIndex.normalise(part.number)) {
                numbers += Self.superseded(by: part)
            }
        }
        var seen = Set<String>()
        numbers = numbers.filter { !$0.isEmpty && seen.insert($0).inserted }

        var line: StockSystemSnapshot.Line?
        for candidate in numbers {
            if let found = snapshot.lines.first(where: { $0.part.map(VaultPartsIndex.normalise) == candidate }) {
                line = found
                break
            }
        }

        switch (line, vaultPart) {
        case let (line?, part?): return .inBoth(line, vaultPart: part)
        case let (line?, nil): return .systemOnly(line, bookSearched: book != nil)
        case let (nil, part?): return .vaultOnly(part)
        case (nil, nil): return .neither
        }
    }

    /// The numbers a part's `Supersedes` cell names, normalised.
    private static func superseded(by part: VaultPartsIndex.Part) -> [String] {
        (part.supersedes ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { VaultPartsIndex.normalise(String($0)) }
            .filter { !$0.isEmpty }
    }
}
