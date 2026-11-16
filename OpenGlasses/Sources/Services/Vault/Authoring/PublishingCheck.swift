import Foundation

/// Plan LW §7 — what an author is told before exporting a vault to publish, pure. Warnings, never a
/// block (decision 4): the author decides. A private export shows none of them.
///
/// - **Rows in the manual's words:** kept rows the check or a proposal marked as the manual's own
///   wording, whose line is still in the vault's file as it was kept. Rewriting the line clears it.
/// - **Models with no manual:** a `##` section of `models.md` whose `Manuals:` line cites none
///   (`key p. N`).
/// - **The vault check below the author's threshold**, as it last ran.
enum PublishingCheck {

    enum Warning: Equatable {
        case rowsInManualsWords(Int)
        case modelsWithoutManual([String])
        case checkBelowThreshold(found: Int, asked: Int, threshold: Double)
    }

    static func warnings(files: [String: String], record: VaultAuthoringRecord?, privateExport: Bool) -> [Warning] {
        guard !privateExport else { return [] }
        var out: [Warning] = []
        let copied = (record?.copiedLines ?? []).filter { copied in
            DraftKeeper.splitLines(files[copied.file] ?? "").contains { $0.trimmingCharacters(in: .whitespaces) == copied.line }
        }
        if !copied.isEmpty { out.append(.rowsInManualsWords(copied.count)) }
        let uncited = modelsWithoutManual(files[VaultStarter.modelsFile] ?? "")
        if !uncited.isEmpty { out.append(.modelsWithoutManual(uncited)) }
        if let record, let last = record.lastCheck, last.asked > 0, last.fraction + 1e-9 < record.threshold {
            out.append(.checkBelowThreshold(found: last.found, asked: last.asked, threshold: record.threshold))
        }
        return out
    }

    /// The models of `models.md` whose sections cite no manual page.
    static func modelsWithoutManual(_ markdown: String) -> [String] {
        let lines = DraftKeeper.splitLines(markdown)
        var out: [String] = []
        var index = 0
        while index < lines.count {
            guard let heading = DraftKeeper.sectionHeading(lines[index]) else { index += 1; continue }
            var end = index + 1
            while end < lines.count, DraftKeeper.sectionHeading(lines[end]) == nil { end += 1 }
            let body = lines[(index + 1)..<end].joined(separator: "\n")
            let named = lines[(index + 1)..<end].contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("manuals:") else { return false }
                let value = trimmed.dropFirst("manuals:".count).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                return !value.isEmpty && value.lowercased() != "none yet"
            }
            if !named && body.range(of: #"\bp\.\s*\d"#, options: .regularExpression) == nil {
                out.append(DraftKeeper.spellings(ofHeading: heading)[0])
            }
            index = end
        }
        return out
    }

    static func message(_ warning: Warning) -> String {
        switch warning {
        case .rowsInManualsWords(let count):
            return count == 1
                ? String(localized: "1 kept row is still in the manual's words. Rewrite it in your own before you publish.")
                : String(localized: "\(count) kept rows are still in the manual's words. Rewrite them in your own before you publish.")
        case .modelsWithoutManual(let models):
            return String(localized: "No manual is listed for \(models.joined(separator: ", ")).")
        case .checkBelowThreshold(let found, let asked, let threshold):
            let percent = Int((threshold * 100).rounded())
            return String(localized: "The vault check found the right page for \(found) of \(asked) questions, below your \(percent)%.")
        }
    }
}
