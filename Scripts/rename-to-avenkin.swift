import Foundation

// Renames the product's visible name to Avenkin (Plan FY P1, decision D10).
//
//   swift Scripts/rename-to-avenkin.swift <repo-root>            apply the rules
//   swift Scripts/rename-to-avenkin.swift <repo-root> --check    report what would change, write nothing
//
// The rename is mechanical, so it is a script over an explicit rule list rather than a hand edit,
// and it is re-runnable: when `main` moves, run it again instead of resolving string conflicts by
// hand. A second run changes nothing. `BrandNameGuardTests` proves the result complete and
// compiles this file into the test target to run it twice on fixtures.
//
// What it touches — and nothing else:
//   - Swift string literals (never code, never comments) under the app, widget, watch and
//     share-extension sources, plus the named test files that assert the new copy;
//   - the targets' Info.plists and the privacy manifests (values and XML comments);
//   - Localizable.xcstrings: each key whose source text carries the name is renamed, with every
//     localization carried across and the name replaced inside translated values too (brand names
//     are not translated). Keys stay sorted the way Xcode sorts them;
//   - Resources/Translations/*.json, the same way;
//   - the four website pages, the READMEs, SECURITY.md, the named docs, and the bundled vault
//     Markdown (prose only: fenced code and inline code are left alone).
//
// What it never touches, and why:
//   - identifiers glued to the name ("OpenGlassesLogo", "OpenGlasses_", "OpenGlasses/Sources",
//     "OpenGlasses.xcodeproj", "straff2002/OpenGlasses") — asset names, file prefixes, paths and
//     the repository, all of which are keys (decision D2) or addresses;
//   - every lower-case `openglasses` (bundle ids, App Group, signing domains, StoreKit ids, the
//     URL scheme, the wake phrase values) except the three outbound labels listed below;
//   - the lines in `excludedLines`, each with its reason;
//   - `docs/plans/*` (history), `CHANGELOG`, `Scripts/`, `LICENSE`, `Package.resolved`, and every
//     test file not named in `testFiles`.
//
// The old name is assembled from pieces so this file never matches a search for it.

enum BrandRename {

    static let oldName = "Open" + "Glasses"
    static let newName = "Avenkin"

    // MARK: - Rule list

    /// Directories whose `.swift` files have their string literals renamed.
    static let swiftDirectories = [
        "OpenGlasses/Sources", "GlassesActivityWidget", "OpenGlassesShareExtension",
        "OpenGlassesWatch", "OpenGlassesWatchWidget",
    ]

    /// Test files whose assertions follow the new copy. Every other test file is left alone,
    /// because several assert the legacy values on purpose (migrations, echo stripping, old
    /// prompts).
    static let testFiles = [
        "OpenGlassesTests/AIProvenanceTests.swift",
        "OpenGlassesTests/BlindAssistantLaunchPolicyTests.swift",
        "OpenGlassesTests/DiagnosticExportTests.swift",
        "OpenGlassesTests/DiagnosticsReportBuilderTests.swift",
        "OpenGlassesTests/JobTranscriptExportTests.swift",
        "OpenGlassesTests/OpenClawConnectParamsTests.swift",
        "OpenGlassesTests/RecordingFilerTests.swift",
        "OpenGlassesTests/StagedExportLifecycleTests.swift",
        "OpenGlassesUITests/OnboardingAccessibilityTests.swift",
        "OpenGlassesUITests/SettingsAccessibilityTests.swift",
    ]

    static let plistFiles = [
        "OpenGlasses/Info.plist", "GlassesActivityWidget/Info.plist",
        "OpenGlassesShareExtension/Info.plist", "OpenGlassesWatch/Info.plist",
        "OpenGlassesWatchWidget/Info.plist",
        "OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy",
        "GlassesActivityWidget/PrivacyInfo.xcprivacy", "OpenGlassesWatch/PrivacyInfo.xcprivacy",
        "OpenGlassesWatchWidget/PrivacyInfo.xcprivacy",
    ]

    static let catalogFile = "OpenGlasses/Sources/Resources/Localizable.xcstrings"
    static let translationsDirectory = "OpenGlasses/Sources/Resources/Translations"

    static let htmlFiles = ["index.html", "about.html", "privacy.html", "support.html"]

    static let markdownFiles = [
        "README.md", "README.zh-CN.md", "SECURITY.md", "docs/BUILDING.md", "docs/CAPABILITIES.md",
        "docs/field-assist-vault-guide.md", "docs/support-reports-guide.md",
    ]

    /// Bundled vault documents are shown in the app, so their prose follows the name too.
    static let markdownDirectories = ["OpenGlasses/Sources/Resources/Vaults"]

    /// Lower-case outbound labels that are display names, not lookup keys (P1 item 5). Applied
    /// inside Swift string literals only.
    static let lowercaseLabels: [(from: String, to: String)] = [
        ("open" + "glasses-export", "avenkin-export"),
        ("open" + "glasses-diagnostics", "avenkin-diagnostics"),
        ("open" + "glasses-ios/", "avenkin-ios/"),
    ]

    /// Inflected forms in translations, where a language glues a case ending onto the name
    /// (so the word rule, which leaves glued names alone, would miss them).
    static let inflections: [(from: String, to: String)] = [
        (oldName + "iin", newName + "iin"),   // Finnish illative: "Tervetuloa …iin"
    ]

    static func inflected(_ line: String) -> String {
        inflections.reduce(line) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }

    /// Catalog keys that keep their old entry as well as gaining the renamed one: the wake-phrase
    /// picker lists the old name's phrases below the new ones for one App Store version (P3.2).
    static let retainedKeys: Set<String> = [oldName, "Hey " + oldName]

    /// Catalog keys whose name becomes the configured wake phrase rather than the new name
    /// (P1 item 12): the hint reads `Config.wakePhrase`, so the key is the interpolated form.
    static let wakeHintKeys: [String: String] = [
        "Say \"\(oldName)\" or tap the mic to start a conversation.":
            "Say \"%@\" or tap the mic to start a conversation.",
        "The agent will ask you questions to learn about you and customize its personality. Say \"\(oldName)\" to begin.":
            "The agent will ask you questions to learn about you and customize its personality. Say \"%@\" to begin.",
    ]

    struct Exclusion {
        /// Matched against the end of the repository-relative path; nil matches every file.
        let pathSuffix: String?
        let lineContains: String
        let reason: String
        /// Also shelters the line after the match — a property-list value under its key.
        var alsoNextLine = false
    }

    static let excludedLines: [Exclusion] = [
        Exclusion(pathSuffix: nil, lineContains: "storageService",
                  reason: "Keychain service names (D2): renaming loses every stored key"),
        Exclusion(pathSuffix: "FitnessCoachingTool.swift", lineContains: "addMetadata",
                  reason: "HealthKit metadata key already written onto saved workouts"),
        Exclusion(pathSuffix: "MedicalExportService.swift", lineContains: "MSH|",
                  reason: "HL7 sending-application field: EMR interfaces route messages on it"),
        Exclusion(pathSuffix: "LocalOutputPolicy.swift", lineContains: "labels",
                  reason: "Echo stripping keeps the old name: old history still carries it (item 6)"),
        Exclusion(pathSuffix: nil, lineContains: ".tag(\"open" + "glasses\")",
                  reason: "Old wake phrase kept in the picker for one App Store version (P3.2)"),
        Exclusion(pathSuffix: nil, lineContains: ".tag(\"hey open" + "glasses\")",
                  reason: "Old wake phrase kept in the picker for one App Store version (P3.2)"),
        Exclusion(pathSuffix: "Info.plist", lineContains: "<key>INAlternativeAppName</key>",
                  reason: "Siri alternative name: the old name must still reach the app",
                  alsoNextLine: true),
        Exclusion(pathSuffix: "README.md", lineContains: "\(oldName) is becoming Avenkin",
                  reason: "The rename notice names the old name so existing users recognise it"),
        Exclusion(pathSuffix: "README.md", lineContains: "\(oldName) is now Avenkin",
                  reason: "The rename notice names the old name so existing users recognise it"),
        Exclusion(pathSuffix: "README.zh-CN.md", lineContains: "\(oldName) 即将更名为 Avenkin",
                  reason: "The rename notice names the old name so existing users recognise it"),
        Exclusion(pathSuffix: "README.zh-CN.md", lineContains: "\(oldName) 已更名为 Avenkin",
                  reason: "The rename notice names the old name so existing users recognise it"),
    ]

    static func isExcluded(line: Substring, previousLine: Substring?, path: String) -> Bool {
        excludedLines.contains { exclusion in
            if let suffix = exclusion.pathSuffix, !path.hasSuffix(suffix) { return false }
            if line.contains(exclusion.lineContains) { return true }
            return exclusion.alsoNextLine && (previousLine?.contains(exclusion.lineContains) ?? false)
        }
    }

    // MARK: - The word rule

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    private static func isLetterByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// Byte offsets in `bytes[range]` where the old name stands as a word: not glued to an
    /// identifier, a path, a file extension or a repository address.
    static func wordOccurrences(in bytes: [UInt8], range: Range<Int>) -> [Int] {
        let needle = Array(oldName.utf8)
        guard range.count >= needle.count else { return [] }
        var hits: [Int] = []
        var index = range.lowerBound
        while index + needle.count <= range.upperBound {
            if bytes[index] == needle[0], Array(bytes[index ..< index + needle.count]) == needle {
                let before: UInt8? = index > 0 ? bytes[index - 1] : nil
                let afterIndex = index + needle.count
                let after: UInt8? = afterIndex < bytes.count ? bytes[afterIndex] : nil
                var glued = false
                if let before, isIdentifierByte(before) || before == 0x2F /* / */
                    || before == 0x2E /* . */ || before == 0x2D /* - */ || before == 0x24 /* $ */
                    || before == 0x40 /* @ */ {
                    glued = true
                }
                if let after, isIdentifierByte(after) || after == 0x2F || after == 0x2D {
                    glued = true
                }
                if after == 0x2E /* . */, afterIndex + 1 < bytes.count, isLetterByte(bytes[afterIndex + 1]) {
                    glued = true
                }
                if !glued { hits.append(index) }
                index += needle.count
            } else {
                index += 1
            }
        }
        return hits
    }

    /// Replace every word occurrence of the old name inside the given ranges, and (for Swift
    /// literals) the lower-case outbound labels. Ranges are applied back to front.
    static func replace(in bytes: [UInt8], ranges: [Range<Int>], lowercaseLabels labels: Bool) -> [UInt8] {
        var edits: [(range: Range<Int>, replacement: [UInt8])] = []
        let needleCount = oldName.utf8.count
        for range in ranges {
            for hit in wordOccurrences(in: bytes, range: range) {
                edits.append((hit ..< hit + needleCount, Array(newName.utf8)))
            }
            if labels {
                for label in lowercaseLabels {
                    let from = Array(label.from.utf8)
                    var index = range.lowerBound
                    while index + from.count <= range.upperBound {
                        if Array(bytes[index ..< index + from.count]) == from {
                            edits.append((index ..< index + from.count, Array(label.to.utf8)))
                            index += from.count
                        } else {
                            index += 1
                        }
                    }
                }
            }
        }
        var result = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    /// Byte range of the line that contains `offset`.
    static func lineRange(in bytes: [UInt8], containing offset: Int) -> Range<Int> {
        var start = offset
        while start > 0 && bytes[start - 1] != 0x0A { start -= 1 }
        var end = offset
        while end < bytes.count && bytes[end] != 0x0A { end += 1 }
        return start ..< end
    }

    static func line(in bytes: [UInt8], containing offset: Int) -> Substring {
        Substring(String(decoding: bytes[lineRange(in: bytes, containing: offset)], as: UTF8.self))
    }

    static func previousLine(in bytes: [UInt8], before offset: Int) -> Substring? {
        let start = lineRange(in: bytes, containing: offset).lowerBound
        guard start > 0 else { return nil }
        return line(in: bytes, containing: start - 1)
    }

    /// Drop the ranges whose line is excluded, splitting a range at line breaks first so an
    /// exclusion on one line of a multi-line literal never shelters the others.
    static func admitted(_ ranges: [Range<Int>], in bytes: [UInt8], path: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges {
            var start = range.lowerBound
            var index = range.lowerBound
            while index <= range.upperBound {
                if index == range.upperBound || bytes[index] == 0x0A {
                    if start < index, !isExcluded(line: line(in: bytes, containing: start),
                                                  previousLine: previousLine(in: bytes, before: start),
                                                  path: path) {
                        result.append(start ..< index)
                    }
                    start = index + 1
                }
                index += 1
            }
        }
        return result
    }

    // MARK: - Swift string literals

    /// The byte ranges of string-literal *text* in a Swift source: inside `"…"`, `"""…"""` and
    /// raw `#"…"#` literals, excluding interpolated code, and never in comments or code.
    static func swiftLiteralRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        lexCode(bytes, &index, stopAtParen: false, into: &ranges)
        return ranges
    }

    private static func lexCode(_ b: [UInt8], _ i: inout Int, stopAtParen: Bool, into ranges: inout [Range<Int>]) {
        var depth = 0
        let n = b.count
        while i < n {
            let c = b[i]
            let next: UInt8? = i + 1 < n ? b[i + 1] : nil
            if c == 0x2F /* / */ && next == 0x2F {
                while i < n && b[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x2F && next == 0x2A /* * */ {
                var nesting = 1
                i += 2
                while i < n && nesting > 0 {
                    if b[i] == 0x2F && i + 1 < n && b[i + 1] == 0x2A { nesting += 1; i += 2; continue }
                    if b[i] == 0x2A && i + 1 < n && b[i + 1] == 0x2F { nesting -= 1; i += 2; continue }
                    i += 1
                }
                continue
            }
            if c == 0x23 /* # */ {
                var hashes = 0
                var j = i
                while j < n && b[j] == 0x23 { hashes += 1; j += 1 }
                if j < n && b[j] == 0x22 {
                    i = j
                    lexString(b, &i, hashes: hashes, into: &ranges)
                    continue
                }
                i = j
                continue
            }
            if c == 0x22 /* " */ {
                lexString(b, &i, hashes: 0, into: &ranges)
                continue
            }
            if stopAtParen {
                if c == 0x28 /* ( */ { depth += 1 }
                if c == 0x29 /* ) */ {
                    if depth == 0 { i += 1; return }
                    depth -= 1
                }
            }
            i += 1
        }
    }

    /// `i` is at the opening quote (after any `#`s). Leaves `i` after the closing delimiter.
    private static func lexString(_ b: [UInt8], _ i: inout Int, hashes: Int, into ranges: inout [Range<Int>]) {
        let n = b.count
        let multiline = i + 2 < n && b[i + 1] == 0x22 && b[i + 2] == 0x22
        i += multiline ? 3 : 1
        var segmentStart = i

        func closesHere(_ at: Int) -> Int? {
            let quotes = multiline ? 3 : 1
            guard at + quotes + hashes <= n else { return nil }
            for k in 0 ..< quotes where b[at + k] != 0x22 { return nil }
            for k in 0 ..< hashes where b[at + quotes + k] != 0x23 { return nil }
            return at + quotes + hashes
        }

        while i < n {
            let c = b[i]
            if c == 0x5C /* \ */ {
                var j = i + 1
                var seen = 0
                while seen < hashes && j < n && b[j] == 0x23 { seen += 1; j += 1 }
                if seen == hashes {
                    if j < n && b[j] == 0x28 /* ( */ {
                        ranges.append(segmentStart ..< i)
                        i = j + 1
                        lexCode(b, &i, stopAtParen: true, into: &ranges)
                        segmentStart = i
                        continue
                    }
                    i = min(j + 1, n)
                    continue
                }
                i += 1
                continue
            }
            if c == 0x22, let end = closesHere(i) {
                ranges.append(segmentStart ..< i)
                i = end
                return
            }
            if !multiline && c == 0x0A {
                ranges.append(segmentStart ..< i)
                return
            }
            i += 1
        }
        ranges.append(segmentStart ..< min(i, n))
    }

    static func renameSwift(_ text: String, path: String) -> String {
        let bytes = Array(text.utf8)
        let ranges = admitted(swiftLiteralRanges(bytes), in: bytes, path: path)
        return String(decoding: replace(in: bytes, ranges: ranges, lowercaseLabels: true), as: UTF8.self)
    }

    // MARK: - Property lists, HTML and Markdown (line-oriented prose)

    static func renameLines(_ text: String, path: String) -> String {
        let bytes = Array(text.utf8)
        let whole = [0 ..< bytes.count]
        let ranges = admitted(whole, in: bytes, path: path)
        return String(decoding: replace(in: bytes, ranges: ranges, lowercaseLabels: false), as: UTF8.self)
    }

    /// Markdown prose only: fenced code blocks and inline code spans are commands, paths and
    /// target names, and keep their spelling.
    static func renameMarkdown(_ text: String, path: String) -> String {
        let bytes = Array(text.utf8)
        let admittedRanges = admitted(markdownProseRanges(bytes), in: bytes, path: path)
        return String(decoding: replace(in: bytes, ranges: admittedRanges, lowercaseLabels: false), as: UTF8.self)
    }

    /// The prose of a Markdown file: everything outside fenced code blocks and inline code spans.
    static func markdownProseRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var inFence = false
        var lineStart = 0
        while lineStart <= bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count && bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let line = String(decoding: bytes[lineStart ..< lineEnd], as: UTF8.self)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            } else if !inFence {
                // Split the line at backtick code spans.
                var segmentStart = lineStart
                var index = lineStart
                var inCode = false
                while index < lineEnd {
                    if bytes[index] == 0x60 /* ` */ {
                        if !inCode && segmentStart < index { ranges.append(segmentStart ..< index) }
                        inCode.toggle()
                        segmentStart = index + 1
                    }
                    index += 1
                }
                if !inCode && segmentStart < lineEnd { ranges.append(segmentStart ..< lineEnd) }
            }
            lineStart = lineEnd + 1
        }
        return ranges
    }

    // MARK: - Localizable.xcstrings

    /// Xcode's own escaping for a catalog key, for the keys this script writes.
    static func encodeKey(_ key: String) -> String {
        var out = "\""
        for scalar in key.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func decodeKey(_ encoded: String) -> String? {
        guard let data = "[\(encoded)]".data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array.first
    }

    /// Renames the brand-carrying keys of a string catalog, carrying every localization across,
    /// and replaces the name inside translated values and comments. Edits the file as text —
    /// Xcode's formatting is kept byte for byte — and keeps Xcode's key order.
    static func renameCatalog(_ text: String, path: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let open = lines.firstIndex(of: "  \"strings\" : {") else { return text }
        guard let close = lines[(open + 1)...].firstIndex(where: { $0 == "  }," || $0 == "  }" }) else { return text }

        struct Entry { var key: String; var keyLine: String; var body: [String] }
        var entries: [Entry] = []
        var index = open + 1
        while index < close {
            // Xcode writes every entry as `    "<key>" : {`, its body, then `    }` or `    },`
            // (an empty entry's body is one blank line). Anything else: leave the file alone.
            let keyLine = lines[index]
            guard keyLine.hasPrefix("    \""), keyLine.hasSuffix(" : {"),
                  let key = decodeKey(String(keyLine.dropFirst(4).dropLast(4))) else { return text }
            var body: [String] = []
            index += 1
            while index < close && !(lines[index] == "    }" || lines[index] == "    },") {
                body.append(lines[index])
                index += 1
            }
            entries.append(Entry(key: key, keyLine: keyLine, body: body))
            index += 1
        }

        func renamedBody(_ body: [String], wakeHint: Bool) -> [String] {
            body.map { line in
                guard line.contains("\"value\" : \"") || line.contains("\"comment\" : \"") else { return line }
                if wakeHint { return line.replacingOccurrences(of: oldName, with: "%@") }
                return renameLines(inflected(line), path: path)
            }
        }

        func keyLine(for key: String) -> String { "    " + encodeKey(key) + " : {" }

        let existing = Set(entries.map(\.key))
        var result: [Entry] = []
        for entry in entries {
            let target: String?
            if let hint = wakeHintKeys[entry.key] {
                target = hint
            } else {
                let renamed = renameLines(entry.key, path: path)
                target = renamed == entry.key ? nil : renamed
            }
            guard let target else {
                result.append(Entry(key: entry.key, keyLine: entry.keyLine,
                                    body: renamedBody(entry.body, wakeHint: false)))
                continue
            }
            if retainedKeys.contains(entry.key) { result.append(entry) }
            if !existing.contains(target) {
                result.append(Entry(key: target, keyLine: keyLine(for: target),
                                    body: renamedBody(entry.body, wakeHint: wakeHintKeys[entry.key] != nil)))
            }
        }
        // Stable sort in Xcode's order; the file is already in it, so untouched keys keep their places.
        let sorted = result.enumerated().sorted { lhs, rhs in
            let order = lhs.element.key.localizedStandardCompare(rhs.element.key)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)

        var body: [String] = []
        for (position, entry) in sorted.enumerated() {
            body.append(entry.keyLine)
            body.append(contentsOf: entry.body)
            body.append(position == sorted.count - 1 ? "    }" : "    },")
        }
        lines.replaceSubrange((open + 1) ..< close, with: body)
        return lines.joined(separator: "\n")
    }

    // MARK: - Resources/Translations/*.json

    /// One `"key": "value"` pair per line, keys in code-point order, no trailing newline — the
    /// shape the translation pipeline writes. Renamed like the catalog.
    static func renameTranslations(_ text: String, path: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "{", let close = lines.lastIndex(of: "}") else { return text }
        var pairs: [(key: String, value: String, line: String)] = []
        for line in lines[1 ..< close] {
            let bare = line.hasSuffix(",") ? String(line.dropLast()) : line
            guard bare.hasPrefix("  \""),
                  let data = ("{" + bare + "}").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  object.count == 1, let (key, value) = object.first.map({ ($0.key, $0.value) })
            else { return text }
            pairs.append((key, value, bare))
        }
        let existing = Set(pairs.map(\.key))
        var result: [(key: String, line: String)] = []
        for pair in pairs {
            if let hint = wakeHintKeys[pair.key] {
                if !existing.contains(hint) {
                    let value = pair.value.replacingOccurrences(of: oldName, with: "%@")
                    result.append((hint, "  " + encodeKey(hint) + ": " + encodeKey(value)))
                }
                continue
            }
            let target = renameLines(pair.key, path: path)
            if target == pair.key {
                result.append((pair.key, renameLines(inflected(pair.line), path: path)))
                continue
            }
            if retainedKeys.contains(pair.key) { result.append((pair.key, pair.line)) }
            guard !existing.contains(target) else { continue }
            result.append((target, renameLines(inflected(pair.line), path: path)))
        }
        result.sort { lhs, rhs in Array(lhs.key.unicodeScalars.map(\.value)).lexicographicallyPrecedes(rhs.key.unicodeScalars.map(\.value)) }
        let body = result.enumerated().map { $0.offset == result.count - 1 ? $0.element.line : $0.element.line + "," }
        lines.replaceSubrange(1 ..< close, with: body)
        return lines.joined(separator: "\n")
    }

    // MARK: - Finding what is left

    /// Every place the old name still stands as a word in the parts of `text` the rules read —
    /// literals for Swift, prose for Markdown, everything for the rest — ignoring the exclusions.
    /// `BrandNameGuardTests` holds these against its own allowlist.
    static func wordHits(in text: String, kind: Kind) -> [(line: Int, text: String)] {
        let bytes = Array(text.utf8)
        let ranges: [Range<Int>]
        switch kind {
        case .swift: ranges = swiftLiteralRanges(bytes)
        case .markdown: ranges = markdownProseRanges(bytes)
        case .lines, .catalog, .translations: ranges = [0 ..< bytes.count]
        }
        var hits: [(Int, String)] = []
        for range in ranges {
            for offset in wordOccurrences(in: bytes, range: range) {
                let lineNumber = bytes[..<offset].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
                hits.append((lineNumber, String(line(in: bytes, containing: offset))))
            }
        }
        return hits
    }

    // MARK: - Running

    /// Every file the rules cover that exists under `root`, as repository-relative paths.
    static func coveredFiles(root: URL) -> [(path: String, kind: Kind)] {
        let fm = FileManager.default
        var files: [(String, Kind)] = []
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
        func walk(_ directory: String, extension ext: String) -> [String] {
            let base = root.appendingPathComponent(directory).resolvingSymlinksInPath()
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
            var found: [String] = []
            for case let url as URL in walker where url.pathExtension == ext {
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(base.path + "/") else { continue }
                found.append(directory + "/" + full.dropFirst(base.path.count + 1))
            }
            return found.sorted()
        }
        for directory in swiftDirectories { files += walk(directory, extension: "swift").map { ($0, .swift) } }
        files += testFiles.filter(exists).map { ($0, .swift) }
        files += plistFiles.filter(exists).map { ($0, .lines) }
        if exists(catalogFile) { files.append((catalogFile, .catalog)) }
        files += walk(translationsDirectory, extension: "json").map { ($0, .translations) }
        files += htmlFiles.filter(exists).map { ($0, .lines) }
        files += markdownFiles.filter(exists).map { ($0, .markdown) }
        for directory in markdownDirectories { files += walk(directory, extension: "md").map { ($0, .markdown) } }
        return files
    }

    enum Kind { case swift, lines, catalog, translations, markdown }

    static func rename(_ text: String, path: String, kind: Kind) -> String {
        switch kind {
        case .swift: return renameSwift(text, path: path)
        case .lines: return renameLines(text, path: path)
        case .catalog: return renameCatalog(text, path: path)
        case .translations: return renameTranslations(text, path: path)
        case .markdown: return renameMarkdown(text, path: path)
        }
    }

    /// Applies the rules under `root`. Returns the repository-relative paths that changed (or
    /// would change, when `write` is false).
    @discardableResult
    static func apply(root: URL, write: Bool = true) throws -> [String] {
        var changed: [String] = []
        for (path, kind) in coveredFiles(root: root) {
            let url = root.appendingPathComponent(path)
            let original = try String(contentsOf: url, encoding: .utf8)
            let renamed = rename(original, path: path, kind: kind)
            guard renamed != original else { continue }
            changed.append(path)
            if write { try renamed.write(to: url, atomically: true, encoding: .utf8) }
        }
        return changed
    }

    static func main(_ arguments: [String]) -> Int32 {
        let operands = arguments.dropFirst().filter { !$0.hasPrefix("--") }
        guard let rootPath = operands.first else {
            FileHandle.standardError.write(Data("usage: swift Scripts/rename-to-avenkin.swift <repo-root> [--check]\n".utf8))
            return 2
        }
        let check = arguments.contains("--check")
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("project.base.yml").path) else {
            FileHandle.standardError.write(Data("\(root.path) is not the repository root\n".utf8))
            return 2
        }
        do {
            let changed = try apply(root: root, write: !check)
            for path in changed { print((check ? "would change " : "changed ") + path) }
            print("\(changed.count) file(s) \(check ? "would change" : "changed")")
            return check && !changed.isEmpty ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data("rename failed: \(error)\n".utf8))
            return 1
        }
    }
}

// Script entry point. A global initialiser runs eagerly when this file is the script's main file
// and never when it is compiled into a module (globals there are lazy and this one is unread), so
// the test target can compile the rules without running them.
let brandRenameExitStatus: Int32 = {
    let status = BrandRename.main(CommandLine.arguments)
    if status != 0 { exit(status) }
    return status
}()
