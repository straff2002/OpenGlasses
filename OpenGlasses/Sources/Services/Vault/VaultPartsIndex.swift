import Foundation

/// The parts a vault names, read out of its own core files.
///
/// A vault already carries part numbers as prose — "LP/propane changeover kit 65W77 (070, 110,
/// 135)" — and nothing could look one up. The convention this reads is a table:
///
/// ```markdown
/// ## Conversion kits
///
/// | Part  | Description                     | Fits                | Supersedes |
/// |-------|---------------------------------|---------------------|------------|
/// | 65W77 | LP/propane changeover kit       | 070, 110, 135       |            |
/// ```
///
/// in a `parts.md` core file, or under any `## Parts` section of any core file. Pure over the core
/// text, exactly like `VaultModelIndex` — a vault with no such table yields an empty index and
/// every part named is then simply unverified against the core, which is how the bundled vaults
/// stay as they were.
struct VaultPartsIndex: Equatable {

    struct Part: Equatable {
        /// The number as the table writes it.
        let number: String
        let partDescription: String
        /// Which models it fits, verbatim from the table.
        let fits: String
        /// The number it replaces, when the table gives one.
        let supersedes: String?
        /// Core file it was read from.
        let file: String
        /// The `##`/`###` heading the table sat under, when there was one.
        let heading: String?
    }

    let parts: [Part]
    /// Uppercased number → part. First row wins, so a number listed twice resolves to where it was
    /// first defined rather than to whichever file happened to be read last.
    private let byNumber: [String: Part]

    var isEmpty: Bool { parts.isEmpty }
    /// Every part number the vault names, uppercased.
    var knownPartNumbers: Set<String> { Set(byNumber.keys) }

    // MARK: - Building

    init(store: VaultStore) {
        self.init(files: store.readAll())
    }

    init(files: [(filename: String, contents: String)]) {
        var parts: [Part] = []
        var index: [String: Part] = [:]
        for (filename, contents) in files {
            for part in Self.parts(in: contents, file: filename) {
                let key = part.number.uppercased()
                guard index[key] == nil else { continue }
                index[key] = part
                parts.append(part)
            }
        }
        self.parts = parts
        self.byNumber = index
    }

    // MARK: - Parsing

    /// Whether this file's tables count at all: `parts.md` is a parts file throughout; any other
    /// core file contributes only the tables under a `## Parts` heading, so a specifications table
    /// that happens to have a "Part" column somewhere else cannot leak in.
    private static func isPartsFile(_ filename: String) -> Bool {
        filename.lowercased().hasSuffix("parts.md")
    }

    private static func isPartsHeading(_ heading: String) -> Bool {
        let lowered = heading.lowercased()
        return lowered == "parts" || lowered.hasPrefix("parts ") || lowered.hasSuffix(" parts")
    }

    static func parts(in markdown: String, file: String) -> [Part] {
        let wholeFile = isPartsFile(file)
        var out: [Part] = []
        var heading: String?
        /// The `## Parts` section we are inside, when the file is not a parts file. A deeper
        /// heading stays inside it; a heading at the same level or shallower leaves it.
        var partsSectionLevel: Int?
        var columns: [String: Int]?

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                heading = title.isEmpty ? nil : title
                columns = nil
                if isPartsHeading(title) {
                    partsSectionLevel = level
                } else if let open = partsSectionLevel, level <= open {
                    partsSectionLevel = nil
                }
                continue
            }

            guard wholeFile || partsSectionLevel != nil else { continue }
            guard line.hasPrefix("|") else { columns = nil; continue }

            let cells = Self.cells(in: line)
            if Self.isSeparatorRow(cells) { continue }
            guard let columns else {
                columns = Self.header(cells)
                continue
            }
            guard let numberIndex = columns["part"], numberIndex < cells.count else { continue }
            let number = cells[numberIndex]
            guard !number.isEmpty, CodeTokenizer.isCodeLike(number) else { continue }
            out.append(Part(
                number: number,
                partDescription: Self.cell(cells, columns["description"]) ?? "",
                fits: Self.cell(cells, columns["fits"]) ?? "",
                supersedes: Self.cell(cells, columns["supersedes"]),
                file: file,
                heading: heading))
        }
        return out
    }

    /// A header row is only a parts header when it names a part column and a description — the two
    /// things a verification needs. `Fits` and `Supersedes` are optional.
    private static func header(_ cells: [String]) -> [String: Int]? {
        var map: [String: Int] = [:]
        for (offset, cell) in cells.enumerated() {
            let key = cell.lowercased().trimmingCharacters(in: .whitespaces)
            switch key {
            case "part", "part number", "part no", "part no.": map["part"] = offset
            case "description": map["description"] = offset
            case "fits", "models", "fits models": map["fits"] = offset
            case "supersedes", "replaces": map["supersedes"] = offset
            default: continue
            }
        }
        return (map["part"] != nil && map["description"] != nil) ? map : nil
    }

    private static func cells(in line: String) -> [String] {
        var trimmed = Substring(line)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func cell(_ cells: [String], _ index: Int?) -> String? {
        guard let index, index < cells.count else { return nil }
        let value = cells[index]
        return value.isEmpty ? nil : value
    }

    // MARK: - Lookup

    /// Uppercased and stripped of the punctuation a spoken or transcribed number picks up
    /// ("14T65." / "#14T65"), so the same number reaches the same row however it was said.
    static func normalise(_ number: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-/"))
        return String(number.unicodeScalars.filter { allowed.contains($0) }).uppercased()
    }

    /// The vault's row for a part number, matched as a whole token and case-insensitively.
    func part(number: String) -> Part? {
        let needle = Self.normalise(number)
        guard !needle.isEmpty else { return nil }
        if let exact = byNumber[needle] { return exact }
        // A superseded number resolves to the part that replaced it — the technician says what is
        // printed on the old component, and the record should carry what to order.
        return parts.first { part in
            part.supersedes?.uppercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .contains(Substring(needle)) == true
        }
    }

    /// Where a part was found, as a citation: `parts.md § Conversion kits`.
    static func citation(for part: Part) -> String {
        part.heading.map { "\(part.file) § \($0)" } ?? part.file
    }
}
