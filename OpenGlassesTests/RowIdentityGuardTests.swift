import XCTest
@testable import OpenGlasses

/// Plan MB §5: a list that could repeat a row id is caught before it crashes.
///
/// The same shape as `OutboundFrameConsumerTests`: the sources are scraped for every text-keyed
/// `ForEach` / `List(…, id:)` in a file with a list or a form, and every one must be argued for in
/// `RowIdentityRoster`. The run-time half (`RowIdentity.repeats(in:)`) is tested at the bottom.
final class RowIdentityGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var appRoot: URL { repoRoot.appendingPathComponent("OpenGlasses/Sources/App") }

    /// A site found by the scrape: its roster key, and where it is for the failure message.
    struct Site: Equatable {
        let key: String
        let location: String
    }

    // MARK: - The scrape

    /// The file has a list or a form somewhere in it.
    static func hostsAList(_ text: String) -> Bool {
        text.range(of: #"\b(List|Form)\s*[({]"#, options: .regularExpression) != nil
    }

    /// Every text-keyed loop in `text`, as roster keys. `fileName` is the file's last component.
    static func sites(in text: String, fileName: String) -> [Site] {
        guard hostsAList(text) else { return [] }
        let characters = Array(text)
        var found: [Site] = []
        let pattern = try! NSRegularExpression(pattern: #"\b(ForEach|List)\s*\("#)
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // NSString offsets are UTF-16; walk from the matched prefix's end in characters.
            let prefix = ns.substring(to: match.range.location + match.range.length)
            let start = prefix.count
            var depth = 1
            var index = start
            while index < characters.count, depth > 0, index - start < 600 {
                let character = characters[index]
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) { depth -= 1 }
                index += 1
            }
            guard depth == 0 else { continue }
            let arguments = topLevelArguments(String(characters[start..<(index - 1)]))
            guard let idArgument = arguments.first(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("id:")
            }) else { continue }
            guard let keyPath = idArgument.range(of: #"\\\.[A-Za-z0-9_.]+"#, options: .regularExpression)
                .map({ String(idArgument[$0].dropFirst(2)) }) else { continue }
            if ["id", "offset", "rawValue"].contains(keyPath.split(separator: ".").last.map(String.init) ?? "") {
                continue
            }
            let collection = arguments[0].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if isDistinctByConstruction(collection) { continue }
            let line = String(characters[..<start]).filter { $0 == "\n" }.count + 1
            found.append(Site(key: "\(fileName)|\(collection)|\\.\(keyPath)", location: "\(fileName):\(line)"))
        }
        return found
    }

    /// Shapes whose elements cannot repeat: a CaseIterable's cases, indices, a range, a
    /// dictionary's keys.
    static func isDistinctByConstruction(_ collection: String) -> Bool {
        var text = collection.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Array("), text.hasSuffix(")") {
            text = String(text.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text.hasSuffix(".allCases") || text.hasSuffix(".indices")
            || text.contains("...") || text.contains("..<")
            || text.range(of: #"\.keys(\.sorted\(\))?\)?$"#, options: .regularExpression) != nil
    }

    private static func topLevelArguments(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private func scrape() throws -> [Site] {
        let paths = (try FileManager.default.subpathsOfDirectory(atPath: Self.appRoot.path))
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try paths.flatMap { path -> [Site] in
            let text = try String(contentsOf: Self.appRoot.appendingPathComponent(path), encoding: .utf8)
            return Self.sites(in: text, fileName: (path as NSString).lastPathComponent)
        }
    }

    // MARK: - The guard

    func testTheScrapeFindsTheKnownSites() throws {
        let keys = Set(try scrape().map(\.key))
        XCTAssertGreaterThan(keys.count, 50, "sanity: the scrape should be finding text-keyed loops")
        XCTAssertTrue(keys.contains(#"SettingsView.swift|providers|\.provider"#))
    }

    func testEveryTextKeyedListSiteIsRostered() throws {
        for site in try scrape() where RowIdentityRoster.sites[site.key] == nil {
            XCTFail("\(site.location): a text-keyed loop in a screen with a list or a form is not in "
                    + "RowIdentityRoster. Key it by \\.id or by position, or add `\(site.key)` with a "
                    + "reason its ids cannot repeat.")
        }
    }

    func testEveryRosterEntryStillExists() throws {
        let keys = Set(try scrape().map(\.key))
        for key in RowIdentityRoster.sites.keys where !keys.contains(key) {
            XCTFail("RowIdentityRoster lists `\(key)`, which the scrape no longer finds. Remove it.")
        }
    }

    func testEveryReasonIsSaid() {
        for (key, site) in RowIdentityRoster.sites {
            XCTAssertGreaterThan(site.reason.count, 20, "\(key) needs a real reason")
        }
    }

    /// A site whose ids could not be shown distinct has to be watched at run time.
    func testAWatchedSiteRunsTheRunTimeCheck() throws {
        for (key, site) in RowIdentityRoster.sites where site.verdict == .watched {
            let file = String(key.split(separator: "|")[0])
            let paths = try FileManager.default.subpathsOfDirectory(atPath: Self.appRoot.path)
                .filter { ($0 as NSString).lastPathComponent == file }
            let text = try paths.map {
                try String(contentsOf: Self.appRoot.appendingPathComponent($0), encoding: .utf8)
            }.joined()
            XCTAssertTrue(text.contains(".uniqueRowsCheck("), "\(key) is watched but \(file) never checks it")
        }
    }

    // MARK: - The scrape itself

    func testTheScrapeFlagsTextKeysAndLeavesIdentifiersAlone() {
        let text = """
        var body: some View {
            List {
                ForEach(names, id: \\.self) { Text($0) }
                ForEach(items, id: \\.name) { Text($0.name) }
                ForEach(items, id: \\.id) { Text($0.name) }
                ForEach(Array(lines.enumerated()), id: \\.offset) { Text($0.element) }
                ForEach(Kind.allCases, id: \\.self) { Text($0.label) }
                ForEach(rows.indices, id: \\.self) { Text("\\($0)") }
                ForEach(
                    later,
                    id: \\.self
                ) { Text($0) }
            }
        }
        """
        let keys = Self.sites(in: text, fileName: "Example.swift").map(\.key)
        XCTAssertEqual(keys, [#"Example.swift|names|\.self"#, #"Example.swift|items|\.name"#,
                              #"Example.swift|later|\.self"#])
    }

    func testAFileWithNoListOrFormIsNotScraped() {
        let text = "HStack { ForEach(chips, id: \\.self) { Text($0) } }"
        XCTAssertTrue(Self.sites(in: text, fileName: "Chips.swift").isEmpty)
    }

    // MARK: - Run time

    func testRepeatsCountsEveryRowAfterTheFirstWithTheSameId() {
        XCTAssertEqual(RowIdentity.repeats(in: ["a", "b", "c"]), 0)
        XCTAssertEqual(RowIdentity.repeats(in: ["a", "b", "a", "a"]), 2)
        XCTAssertEqual(RowIdentity.repeats(in: [String]()), 0)
    }

    func testTheRunTimeEventCarriesTheScreenAndTheCountOnly() {
        var lines: [String] = []
        let tap = PrivacyLog.addTap { _, line in lines.append(line) }
        defer { PrivacyLog.removeTap(tap) }
        RowIdentityReporter.report(0, file: "OpenGlasses/MemoryView.swift")
        RowIdentityReporter.report(2, file: "OpenGlasses/MemoryView.swift")
        let event = lines.filter { $0.contains("listRowsRepeated") }
        XCTAssertEqual(event.count, 1, "nothing is logged when no id repeats")
        XCTAssertTrue(event.first?.contains("MemoryView.swift") == true)
        XCTAssertTrue(event.first?.contains("2") == true)
    }
}
