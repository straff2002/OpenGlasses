import Foundation

/// Plan LV — what an answer from a published vault carries, pure: the note the prompt is given
/// beside LR's *still downloading* line, in the same place.
///
/// - **Whose files.** When the answer draws on the partner's files, it ends with one source line:
///   "From ⟨partner⟩'s vault", beside the manual and page citations it already gives.
/// - **Which revision.** Decision 6: only when the vault's index cites a page in a manual the company
///   holds at a different revision, or names an expected manual the phone does not hold
///   (`CitationEditionCheck`). The index is the vault's core files; a citation there is the
///   expected manual's key with a page ("install-manual p. 4", "install-manual page 4"), or the key
///   alone. Nothing is said about a matched manual, nor on a vault that cites none.
enum PublishedVaultAnswerNote {

    /// The citations a vault's core files make of its expected manuals, in the order first cited.
    static func indexCitations(in files: [(filename: String, contents: String)], keys: [String]) -> [CitationEditionCheck.Citation] {
        var found: [(offset: Int, file: Int, citation: CitationEditionCheck.Citation)] = []
        for (fileIndex, file) in files.enumerated() {
            let text = file.contents as NSString
            for key in keys where !key.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for: key)
                let pattern = "(?<![A-Za-z0-9_.-])" + escaped + "(?![A-Za-z0-9_-])(?:[ \\t]*,?[ \\t]*(?:pp?\\.?|pages?)[ \\t]*(\\d{1,5}))?"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: file.contents, range: NSRange(location: 0, length: text.length)) {
                    let pageRange = match.range(at: 1)
                    let page = pageRange.location == NSNotFound ? nil : Int(text.substring(with: pageRange))
                    found.append((match.range.location, fileIndex, .init(key: key, page: page)))
                }
            }
        }
        var citations: [CitationEditionCheck.Citation] = []
        for item in found.sorted(by: { ($0.file, $0.offset) < ($1.file, $1.offset) }) where !citations.contains(item.citation) {
            citations.append(item.citation)
        }
        return citations
    }

    /// The line an answer says for one note, as the model is given it.
    static func line(for note: CitationEditionCheck.Note) -> String {
        switch note {
        case .differentRevision(let title, let page):
            return "Your copy of \(title) is a different revision from the one this vault was written for; check page \(page)."
        case .missing(let title):
            return "This vault expects \(title), which isn't on this phone."
        }
    }

    /// The source line an answer from the partner's files ends with.
    static func sourceLine(publisher: String) -> String { "From \(publisher)'s vault" }

    /// The note for one published vault, or nil when there is nothing to say.
    static func promptNote(publisher: String?, publisherFiles: [String], expects: [CompanyVaultCatalog.ExpectedManual],
                           documents: [VaultDocument], files: [(filename: String, contents: String)]) -> String? {
        var parts: [String] = []
        if let publisher, !publisherFiles.isEmpty {
            parts.append("PUBLISHED VAULT: these files of this vault are \(publisher)'s: "
                         + publisherFiles.joined(separator: ", ")
                         + ". When an answer draws on any of them, end it with this line, in the language of the answer: \""
                         + sourceLine(publisher: publisher) + "\".")
        }
        if !expects.isEmpty {
            let summary = ExpectedManualMatch.match(expects: expects, documents: documents)
            let notes = CitationEditionCheck.notes(for: indexCitations(in: files, keys: expects.map(\.key)), in: summary)
            if !notes.isEmpty {
                let lines = notes.map { note -> String in
                    switch note {
                    case .differentRevision(let title, let page):
                        return "- citing page \(page) of \(title): \"\(line(for: note))\""
                    case .missing(let title):
                        return "- relying on a row that cites \(title): \"\(line(for: note))\""
                    }
                }
                parts.append("MANUAL REVISIONS: this phone's copies of the manuals below differ from the ones this vault was written against. When an answer is "
                             + "citing or relying on one of them as listed, add the line given, in the language of the answer, and never on any other answer:\n"
                             + lines.joined(separator: "\n"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
