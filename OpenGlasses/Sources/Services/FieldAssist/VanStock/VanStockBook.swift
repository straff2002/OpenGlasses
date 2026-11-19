import Foundation

/// A book a stock line's number is looked up in (Plan MK §4): an installed vault with a parts
/// table or manuals to search, by the name it is shown under.
@MainActor
struct VanStockBook {
    /// The vault's name, "Supplier catalogue": what the mark and the sentence say it was not
    /// found in.
    let name: String
    /// The vault's own `PartsVerifier`: its parts table, then an exact token search of its
    /// manuals.
    let verify: @MainActor (String) -> TaskPart
}

/// Where van stock finds the book for a number, in Plan MK §4's order.
///
/// 1. The open job's vault, when a job is open (as before Plan MK).
/// 2. Otherwise the vault the list names under "Check numbers against", when it is installed and
///    readable.
/// 3. Otherwise none: nothing is searched, and the line stays not checked.
///
/// A vault with neither a parts table nor manuals is no book, so searching it can never record a
/// number as not found.
@MainActor
struct VanStockBooks {
    /// The open job's vault as a book; nil with no job open, or when it has nothing to search.
    var job: @MainActor () -> VanStockBook?
    /// A named vault as a book; nil when it has gone, cannot be opened, or has nothing to search.
    var named: @MainActor (String) -> VanStockBook?

    /// The book for a number, by the order above. `namedID` is the list's own choice.
    func book(namedID: String?) -> VanStockBook? {
        if let job = job() { return job }
        guard let namedID, !namedID.isEmpty else { return nil }
        return named(namedID)
    }

    /// No book anywhere: every lookup is not checked.
    static let none = VanStockBooks(job: { nil }, named: { _ in nil })

    /// The phone's own: the open job's vault and the installed vaults, through Field Assist.
    static let shared = VanStockBooks(job: { FieldSessionService.shared.vanStockJobBook },
                                      named: { FieldSessionService.shared.vanStockBook(forVault: $0) })
}

/// What one lookup said: the part as the book has it, and the verification to record for it.
struct VanStockLookup {
    let part: TaskPart
    let verification: VanStockVerification

    /// Look `number` up in `book`. With no book nothing is searched: the number comes back as it
    /// was said, not checked, and never not found.
    @MainActor
    static func look(_ number: String, in book: VanStockBook?) -> VanStockLookup {
        guard let book else {
            return VanStockLookup(part: TaskPart(number: VaultPartsIndex.normalise(number), verified: false),
                                  verification: .notChecked)
        }
        let part = book.verify(number)
        return VanStockLookup(part: part, verification: part.verified ? .found(in: book.name) : .notFound(in: book.name))
    }

    /// A lookup through a bare verifier that does not say which book it searched, as tests and
    /// callers before Plan MK inject one: found when it verified, otherwise not checked, which is
    /// what such a lookup has always been stored as.
    init(legacy part: TaskPart) {
        self.part = part
        self.verification = part.verified ? .found(in: nil) : .notChecked
    }

    init(part: TaskPart, verification: VanStockVerification) {
        self.part = part
        self.verification = verification
    }
}
