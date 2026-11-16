import Foundation

/// Plan LW P1 — where a kept draft row goes in the vault's own Markdown, pure.
///
/// - **A fault code** becomes a row of the first fault-code table (`VaultStarter.faultCodeTableHeader`),
///   after the rows already there. A file without the table gets one at its end.
/// - **A model** joins the `##` section that already names it (any spelling, hyphens aside, as
///   `VaultModelIndex` compares them): the spellings it lacks are added to the heading and the
///   citation to its `Manuals:` line. A model no section names gets its own section at the end
///   (`IndexRowWriter.modelSection`).
/// - **A symptom** becomes the next numbered check under the `##` heading that says it, or a new
///   section at the end.
///
/// A row whose line is already there leaves the file as it was.
enum DraftKeeper {

    struct Result: Equatable {
        let text: String
        /// The line the row wrote (or found already written): what the publishing check looks for
        /// while it is still in the manual's words.
        let line: String
    }

    static func fileName(for layer: DraftLayer) -> String {
        switch layer {
        case .faultCodes: return VaultStarter.faultCodesFile
        case .modelMap: return VaultStarter.modelsFile
        case .symptoms: return VaultStarter.symptomsFile
        }
    }

    /// The vault's file for `layer`, when the vault lists it.
    static func file(for layer: DraftLayer, among files: [String]) -> String? {
        let wanted = fileName(for: layer)
        return files.first { $0.lowercased() == wanted }
    }

    static func keeping(_ row: DraftRow, citation: String, in text: String) -> Result {
        switch row {
        case .faultCode(let faultCode):
            return insertingFaultCode(IndexRowWriter.faultCodeLine(faultCode, citation: citation), into: text)
        case .model(let model):
            return mergingModel(model, citation: citation, into: text)
        case .symptom(let symptom):
            return insertingSymptom(symptom, citation: citation, into: text)
        }
    }

    // MARK: - Fault codes

    static func insertingFaultCode(_ line: String, into text: String) -> Result {
        var lines = splitLines(text)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { return Result(text: text, line: line) }
        let header = VaultStarter.faultCodeTableHeader.components(separatedBy: "\n")
        if let start = lines.indices.first(where: { index in
            index + 1 < lines.count && lines[index].trimmingCharacters(in: .whitespaces) == header[0]
                && lines[index + 1].trimmingCharacters(in: .whitespaces) == header[1]
        }) {
            var end = start + 2
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
            lines.insert(line, at: end)
            return Result(text: lines.joined(separator: "\n"), line: line)
        }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += VaultStarter.faultCodeTableHeader + "\n" + line + "\n"
        return Result(text: out, line: line)
    }

    // MARK: - Models

    /// A `##` heading's spellings: the name before its brackets, then those inside.
    static func spellings(ofHeading heading: String) -> [String] {
        guard let open = heading.firstIndex(of: "(") else { return [heading.trimmingCharacters(in: .whitespaces)] }
        let name = heading[..<open].trimmingCharacters(in: .whitespaces)
        let inside = heading[heading.index(after: open)...].replacingOccurrences(of: ")", with: "")
        let aliases = inside.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return [name] + aliases
    }

    static func mergingModel(_ row: ModelRow, citation: String, into text: String) -> Result {
        var lines = splitLines(text)
        let wanted = Set(row.spellings.map(VaultModelIndex.key))
        guard let headingIndex = lines.indices.first(where: { index in
            guard let heading = sectionHeading(lines[index]) else { return false }
            return !Set(spellings(ofHeading: heading).map(VaultModelIndex.key)).isDisjoint(with: wanted)
        }), let heading = sectionHeading(lines[headingIndex]) else {
            let section = IndexRowWriter.modelSection(row, citations: [citation])
            var out = text
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
            out += section + "\n"
            return Result(text: out, line: section.components(separatedBy: "\n")[0])
        }
        // The spellings the heading lacks.
        let present = spellings(ofHeading: heading)
        let presentKeys = Set(present.map { $0.uppercased() })
        let added = row.spellings.filter { !presentKeys.contains($0.uppercased()) }
        if !added.isEmpty {
            let name = present[0]
            let aliases = Array(present.dropFirst()) + added
            lines[headingIndex] = "## \(name) (\(aliases.joined(separator: ", ")))"
        }
        // The citation, on its Manuals line.
        var end = headingIndex + 1
        while end < lines.count, sectionHeading(lines[end]) == nil, !lines[end].hasPrefix("# ") { end += 1 }
        if let manualsIndex = (headingIndex + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("manuals:") }) {
            let existing = lines[manualsIndex]
            if !existing.contains(citation) {
                var body = existing.trimmingCharacters(in: .whitespaces)
                body = String(body.dropFirst("Manuals:".count)).trimmingCharacters(in: .whitespaces)
                while body.hasSuffix(".") { body.removeLast() }
                let listed = body.lowercased() == "none yet" || body.isEmpty ? [] : [body]
                lines[manualsIndex] = "Manuals: \((listed + [citation]).joined(separator: "; "))."
            }
        } else {
            lines.insert("Manuals: \(citation).", at: headingIndex + 1)
        }
        return Result(text: lines.joined(separator: "\n"), line: lines[headingIndex])
    }

    // MARK: - Symptoms

    static func insertingSymptom(_ row: SymptomRow, citation: String, into text: String) -> Result {
        var lines = splitLines(text)
        let symptom = row.symptom.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let wanted = symptom.lowercased()
        if let headingIndex = lines.indices.first(where: { sectionHeading(lines[$0])?.lowercased() == wanted }) {
            var end = headingIndex + 1
            while end < lines.count, sectionHeading(lines[end]) == nil, !lines[end].hasPrefix("# ") { end += 1 }
            let numbered = (headingIndex + 1..<end).filter { numberOfCheck(lines[$0]) != nil }
            let number = (numbered.compactMap { numberOfCheck(lines[$0]) }.max() ?? 0) + 1
            let line = IndexRowWriter.symptomCheckLine(row, number: number, citation: citation)
            let body = (headingIndex + 1..<end).map { stripNumber(lines[$0]) }
            if body.contains(stripNumber(line)) { return Result(text: text, line: line) }
            if let last = numbered.last {
                lines.insert(line, at: last + 1)
            } else {
                // Under the heading, after one blank line.
                var at = headingIndex + 1
                if at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty { at += 1 } else {
                    lines.insert("", at: at); at += 1
                }
                lines.insert(line, at: at)
                if at + 1 < lines.count, !lines[at + 1].trimmingCharacters(in: .whitespaces).isEmpty { lines.insert("", at: at + 1) }
            }
            return Result(text: lines.joined(separator: "\n"), line: line)
        }
        let line = IndexRowWriter.symptomCheckLine(row, number: 1, citation: citation)
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        out += "## \(symptom)\n\n\(line)\n"
        return Result(text: out, line: line)
    }

    // MARK: - Lines

    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// A `##` heading's text, or nil for any other line (a `###` included).
    static func sectionHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), !trimmed.hasPrefix("### ") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// The number of a numbered check (`3. …`), or nil.
    static func numberOfCheck(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex else { return nil }
        return Int(trimmed[..<dot])
    }

    private static func stripNumber(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard numberOfCheck(trimmed) != nil, let dot = trimmed.firstIndex(of: ".") else { return trimmed }
        return trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    }
}
