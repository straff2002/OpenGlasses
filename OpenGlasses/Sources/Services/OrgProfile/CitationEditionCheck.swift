import Foundation

/// Plan LV — whether an answer that cites a published vault's manual carries a revision line, pure.
///
/// Decision 6: the line appears only when an answer cites **a page** in a manual the company holds
/// at a **different revision** from the one the vault was written against, or names an expected
/// manual the phone does not hold. Never on every answer: a citation of a matched manual, of a
/// manual the vault never expected, or of a different-revision manual without a page says nothing.
enum CitationEditionCheck {

    /// What an answer cites: the expected manual's key (as the vault's index rows carry it), or the
    /// document's file in the vault, and the page.
    struct Citation: Equatable, Sendable {
        var key: String?
        var documentFile: String?
        var page: Int?

        init(key: String? = nil, documentFile: String? = nil, page: Int? = nil) {
            self.key = key
            self.documentFile = documentFile
            self.page = page
        }
    }

    enum Note: Equatable, Sendable {
        /// "Your copy of ⟨title⟩ is a different revision from the one this vault was written for;
        /// check page ⟨page⟩."
        case differentRevision(title: String, page: Int)
        /// "This vault expects ⟨title⟩, which isn't on this phone."
        case missing(title: String)
    }

    static func note(for citation: Citation, in summary: ExpectedManualMatch.Summary) -> Note? {
        let entry = citation.key.flatMap { summary.entry(key: $0) }
            ?? citation.documentFile.flatMap { summary.entry(documentFile: $0) }
        guard let entry else { return nil }
        switch entry.status {
        case .matched:
            return nil
        case .differentRevision:
            guard let page = citation.page else { return nil }
            return .differentRevision(title: entry.expected.title, page: page)
        case .missing:
            return .missing(title: entry.expected.title)
        }
    }

    /// The notes for every citation in one answer, each said once, in the order first cited.
    static func notes(for citations: [Citation], in summary: ExpectedManualMatch.Summary) -> [Note] {
        var notes: [Note] = []
        for citation in citations {
            if let note = note(for: citation, in: summary), !notes.contains(note) { notes.append(note) }
        }
        return notes
    }
}
