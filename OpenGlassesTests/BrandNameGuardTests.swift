import XCTest
@testable import OpenGlasses

/// Proves the rename to Avenkin complete (Plan FY P1, decision D10).
///
/// `StorageIdentifierGuardTests` stops the rename reaching too far; this suite stops it falling
/// short. It scrapes every user-visible string source — Swift string literals (which covers
/// `Text`/`Label`/`String(localized:)`, App Intents titles and phrases, notification titles and
/// every other literal the app shows or sends), the targets' `Info.plist`s and privacy manifests,
/// the string catalog's keys and translations, the downloadable translations, the four website
/// pages and the READMEs — for the old product name standing as a word, and fails on any hit
/// outside `allowlist`. Every allowlist entry says why it stays, and an entry that no longer
/// matches anything fails too, so the list cannot rot into a blanket exemption.
///
/// "As a word" is the rename script's own rule (`BrandRename.wordOccurrences`, compiled in from
/// `Scripts/rename-to-avenkin.swift`): the name glued to an identifier, a path, a file extension
/// or the repository address — `…Logo`, `…_`, `…/Sources`, `.xcodeproj`, `straff2002/…` — is a key
/// or an address and is not counted. Comments are not scanned; they are history.
///
/// Sites that must keep the old name *and* would be rewritten by a find-and-replace are spelled in
/// pieces instead of allowlisted — `AssistantIdentity.legacyDefaultNames` and the migration tests —
/// so they never appear here; their own tests pin them. The plan index's note that plans before FY
/// say the old name lives in `docs/plans/`, which is history and is not scanned.
final class BrandNameGuardTests: XCTestCase {

    private static let oldName = "Open" + "Glasses"

    // MARK: - Repo anchor

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func files(under directory: String, extensions: Set<String>) -> [String] {
        let base = Self.repoRoot.appendingPathComponent(directory).resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in walker where extensions.contains(url.pathExtension) {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base.path + "/") else { continue }
            found.append(directory + "/" + full.dropFirst(base.path.count + 1))
        }
        return found.sorted()
    }

    // MARK: - The allowlist

    struct Allowed {
        /// Repository-relative path; a trailing `/` matches every file under that directory.
        let path: String
        /// Text the hit's line must contain.
        let snippet: String
        let reason: String

        func matches(_ hit: Hit) -> Bool {
            let pathMatches = path.hasSuffix("/") ? hit.path.hasPrefix(path) : hit.path == path
            return pathMatches && hit.line.contains(snippet)
        }
    }

    struct Hit: CustomStringConvertible {
        let path: String
        let lineNumber: Int
        let line: String
        var description: String { "\(path):\(lineNumber): \(line.trimmingCharacters(in: .whitespaces))" }
    }

    private static let catalog = "OpenGlasses/Sources/Resources/Localizable.xcstrings"

    static let allowlist: [Allowed] = [
        Allowed(path: "OpenGlasses/Sources/Services/KeychainService.swift",
                snippet: "storageService = \"\(oldName)\"",
                reason: "D2: the Keychain service every stored API key is filed under. Renaming it "
                    + "empties the keychain; StorageIdentifierGuardTests pins the value."),
        Allowed(path: "OpenGlasses/Sources/Services/NativeTools/FitnessCoachingTool.swift",
                snippet: "addMetadata([\"\(oldName)\": true])",
                reason: "A HealthKit metadata key already written onto the workouts earlier builds "
                    + "saved; a key is not a label."),
        Allowed(path: "OpenGlasses/Sources/Services/MedicalExportService.swift",
                snippet: "MSH|^~\\\\&|\(oldName)|",
                reason: "The HL7 sending-application field. Receiving EMR interfaces are configured "
                    + "to route on it, so it is a wire identifier, not copy."),
        Allowed(path: "OpenGlasses/Sources/Services/LLM/LocalOutputPolicy.swift",
                snippet: "labels = [",
                reason: "Echo stripping (P1 item 6): old conversation history still carries the "
                    + "old name as a speaker label, so it is stripped alongside the new one."),
        Allowed(path: "OpenGlasses/Sources/App/Views/SettingsScreens.swift",
                snippet: "Text(\"\(oldName)\").tag(",
                reason: "P3.2: the old wake phrase stays in the picker, below the new ones, for one "
                    + "App Store version."),
        Allowed(path: "OpenGlasses/Sources/App/Views/SettingsScreens.swift",
                snippet: "Text(\"Hey \(oldName)\").tag(",
                reason: "P3.2: the old wake phrase stays in the picker, below the new ones, for one "
                    + "App Store version."),
        Allowed(path: "OpenGlasses/Info.plist",
                snippet: "<string>\(oldName)</string>",
                reason: "INAlternativeAppNames: Siri still reaches the app by the name people "
                    + "learned it by."),
        Allowed(path: catalog, snippet: "key \"\(oldName)\"",
                reason: "P3.2: the catalog entry for the old wake phrase's picker label."),
        Allowed(path: catalog, snippet: "key \"Hey \(oldName)\"",
                reason: "P3.2: the catalog entry for the old wake phrase's picker label."),
        Allowed(path: catalog, snippet: "\"\(oldName)\" [",
                reason: "P3.2: the old wake phrase's picker label is the old name in every language."),
        Allowed(path: catalog, snippet: "\"Hey \(oldName)\" [",
                reason: "P3.2: the old wake phrase's picker label is the old name in every language."),
        Allowed(path: "OpenGlasses/Sources/Resources/Translations/",
                snippet: "\"\(oldName)\": \"\(oldName)\"",
                reason: "P3.2: the downloadable translation of the old wake phrase's picker label."),
        Allowed(path: "README.md", snippet: "\(oldName) is now Avenkin",
                reason: "The rename notice names the old name so existing users recognise the app."),
        Allowed(path: "README.zh-CN.md", snippet: "\(oldName) 已更名为 Avenkin",
                reason: "The rename notice names the old name so existing users recognise the app."),
    ]

    // MARK: - The scan

    private static let swiftDirectories = [
        "OpenGlasses/Sources", "GlassesActivityWidget", "OpenGlassesShareExtension",
        "OpenGlassesWatch", "OpenGlassesWatchWidget",
    ]

    private static let websitePages = ["index.html", "about.html", "privacy.html", "support.html"]
    private static let readmes = ["README.md", "README.zh-CN.md"]

    private func hits(in path: String, kind: BrandRename.Kind) throws -> [Hit] {
        BrandRename.wordHits(in: try text(path), kind: kind).map { Hit(path: path, lineNumber: $0.line, line: $0.text) }
    }

    /// Translations are matched on the name anywhere, not only as a word: a language that glues a
    /// case ending onto a name ("…iin" in Finnish) still shows the old name, and a translation
    /// never carries an identifier.
    private func translationHits(in path: String) throws -> [Hit] {
        try text(path).components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains(Self.oldName) }
            .map { Hit(path: path, lineNumber: $0.offset + 1, line: $0.element) }
    }

    /// Keys and translated values of the string catalog, read as data rather than as lines so a
    /// translation cannot hide inside the file's formatting.
    private func catalogHits() throws -> [Hit] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(Self.catalog))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        var found: [Hit] = []
        func isHit(_ value: String) -> Bool { value.contains(Self.oldName) }
        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            if isHit(key) { found.append(Hit(path: Self.catalog, lineNumber: 0, line: "key \"\(key)\"")) }
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations.sorted(by: { $0.key < $1.key }) {
                var values: [String] = []
                if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    values.append(value)
                }
                // Plural and device variations nest further stringUnits; read them all.
                let nested = String(data: (try? JSONSerialization.data(withJSONObject: localization)) ?? Data(),
                                    encoding: .utf8) ?? ""
                if values.isEmpty, isHit(nested) { values.append(nested) }
                for value in values where isHit(value) {
                    found.append(Hit(path: Self.catalog, lineNumber: 0, line: "\"\(key)\" [\(language)] = \"\(value)\""))
                }
            }
        }
        return found
    }

    private func allHits() throws -> [Hit] {
        var found: [Hit] = []
        for directory in Self.swiftDirectories {
            for path in files(under: directory, extensions: ["swift"]) {
                found += try hits(in: path, kind: .swift)
            }
            for path in files(under: directory, extensions: ["plist", "xcprivacy"]) {
                found += try hits(in: path, kind: .lines)
            }
        }
        found += try hits(in: "OpenGlasses/Info.plist", kind: .lines)
        found += try catalogHits()
        for path in files(under: "OpenGlasses/Sources/Resources/Translations", extensions: ["json"]) {
            found += try translationHits(in: path)
        }
        for page in Self.websitePages { found += try hits(in: page, kind: .lines) }
        for readme in Self.readmes { found += try hits(in: readme, kind: .markdown) }
        return found
    }

    func testNoUserVisibleStringCarriesTheOldName() throws {
        let found = try allHits()
        let unexplained = found.filter { hit in !Self.allowlist.contains { $0.matches(hit) } }
        XCTAssertTrue(unexplained.isEmpty,
                      "The old product name is still user-visible in \(unexplained.count) place(s). "
                          + "Run `swift Scripts/rename-to-avenkin.swift .`, or, if one must stay, add "
                          + "it to BrandNameGuardTests.allowlist with the reason:\n"
                          + unexplained.map(\.description).joined(separator: "\n"))
    }

    func testEveryAllowlistEntryIsStillNeeded() throws {
        let found = try allHits()
        for entry in Self.allowlist {
            XCTAssertTrue(found.contains { entry.matches($0) },
                          "Allowlist entry for \(entry.path) (\"\(entry.snippet)\") matches nothing. "
                              + "Remove it, so the allowlist stays a list of reasons rather than "
                              + "a blanket exemption.")
        }
    }

    // MARK: - The script

    /// The repository is what a run of the script produces: running it now would change nothing.
    /// This is the second-run idempotence, on the real tree.
    func testTheRenameScriptHasNothingLeftToDo() throws {
        let pending = try BrandRename.apply(root: Self.repoRoot, write: false)
        XCTAssertEqual(pending, [],
                       "The rename script would still change these files. Run "
                           + "`swift Scripts/rename-to-avenkin.swift .` and commit the result.")
    }

    private static let fixtures: [(fixture: String, destination: String)] = [
        ("BrandRename-Sample.swift.fixture", "OpenGlasses/Sources/App/Sample.swift"),
        ("BrandRename-Info.plist.fixture", "OpenGlasses/Info.plist"),
        ("BrandRename-README.md.fixture", "README.md"),
        ("BrandRename-Translations.json.fixture", "OpenGlasses/Sources/Resources/Translations/it.json"),
        ("BrandRename-Localizable.xcstrings.fixture", "OpenGlasses/Sources/Resources/Localizable.xcstrings"),
    ]

    private func stageFixtures() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrandRename-\(UUID().uuidString)", isDirectory: true)
        for (fixture, destination) in Self.fixtures {
            let source = Self.repoRoot.appendingPathComponent("OpenGlassesTests/Fixtures/BrandRename/\(fixture)")
            let target = root.appendingPathComponent(destination)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testASecondRunChangesNothing() throws {
        let root = try stageFixtures()
        let first = try BrandRename.apply(root: root)
        XCTAssertEqual(Set(first), Set(Self.fixtures.map(\.destination)),
                       "the first run should rename every fixture")
        let snapshot = try Self.fixtures.map { try String(contentsOf: root.appendingPathComponent($0.destination), encoding: .utf8) }

        let second = try BrandRename.apply(root: root)
        XCTAssertEqual(second, [], "a second run of the rename script changed files")
        let after = try Self.fixtures.map { try String(contentsOf: root.appendingPathComponent($0.destination), encoding: .utf8) }
        XCTAssertEqual(after, snapshot)
    }

    func testTheRulesRenameCopyAndKeepKeys() throws {
        let root = try stageFixtures()
        try BrandRename.apply(root: root)
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let old = Self.oldName

        let swift = try read("OpenGlasses/Sources/App/Sample.swift")
        XCTAssertTrue(swift.contains("Text(\"Avenkin\")"))
        XCTAssertTrue(swift.contains("\"Ask \\(name.isEmpty ? \"Avenkin\" : name) on Avenkin today\""),
                      "literals inside and around an interpolation are both renamed")
        XCTAssertTrue(swift.contains("Button(\"Open iOS Settings for Avenkin\")"))
        XCTAssertTrue(swift.contains("# Avenkin Agent") && swift.contains("Say \"Avenkin\" to begin."),
                      "multi-line literals are renamed")
        XCTAssertTrue(swift.contains("#\"Avenkin says \"hi\"\"#"), "raw literals are renamed")
        XCTAssertTrue(swift.contains("\"avenkin-export-2026\""), "the export label follows the name")
        for kept in ["// \(old) in a comment", "Image(\"\(old)Logo\")", "Text(\"Hey \(old)\").tag(",
                     "storageService = \"\(old)\"", "\"\(old)DeviceScene\"", "\"\(old)_\"",
                     "\"\(old)/Sources/App/\(old)App.swift\"", "scheme = \"open" + "glasses\"",
                     "wakePhrase = \"open" + "glasses\""] {
            XCTAssertTrue(swift.contains(kept), "the rename reached \(kept)")
        }

        let plist = try read("OpenGlasses/Info.plist")
        XCTAssertTrue(plist.contains("<string>Avenkin needs camera access.</string>"))
        XCTAssertTrue(plist.contains("Mail offers \"Open with Avenkin\""))
        XCTAssertTrue(plist.contains("<string>\(old)</string>"), "the Siri alternative name must stay")
        XCTAssertTrue(plist.contains(".\(old)SceneDelegate"), "a class name is not copy")

        let readme = try read("README.md")
        XCTAssertTrue(readme.hasPrefix("# Avenkin\n"))
        XCTAssertTrue(readme.contains("**\(old) is now Avenkin.**"), "the rename notice keeps the old name")
        XCTAssertTrue(readme.contains("Say **“Avenkin”**"))
        for kept in ["`\(old)/Sources`", "straff2002/\(old))", "cd \(old)\n", "open \(old).xcodeproj"] {
            XCTAssertTrue(readme.contains(kept), "the rename reached \(kept)")
        }

        let translations = try read("OpenGlasses/Sources/Resources/Translations/it.json")
        XCTAssertEqual(translations, """
            {
              "Ask": "Chiedi",
              "Avenkin": "Avenkin",
              "\(old)": "\(old)",
              "Say \\"%@\\" or tap the mic to start a conversation.": "Di’ \\"%@\\" o tocca il microfono.",
              "Welcome to Avenkin": "Benvenuto in Avenkin",
              "Zoom": "Zoom"
            }
            """)

        let catalogData = Data(try read("OpenGlasses/Sources/Resources/Localizable.xcstrings").utf8)
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertEqual(Set(strings.keys), ["", "Ask Avenkin", "Avenkin", "Hey Avenkin", "Hey \(old)", old,
                                           "Say \"%@\" or tap the mic to start a conversation.", "Zoom"])
        func value(_ key: String, _ language: String) -> String? {
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]]
            return (localizations?[language]?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        XCTAssertEqual(value("Ask Avenkin", "ru"), "Спросить Avenkin", "translations carry across, renamed")
        XCTAssertEqual(value("Avenkin", "de"), "Avenkin")
        XCTAssertEqual(value(old, "de"), old, "the retained picker label keeps its translation")
        XCTAssertEqual(value("Say \"%@\" or tap the mic to start a conversation.", "ru"),
                       "Скажите «%@» или нажмите на микрофон, чтобы начать разговор.",
                       "the wake hint's translation takes the placeholder")
        XCTAssertEqual(strings["Ask Avenkin"]?["comment"] as? String, "Title of the \"Ask Avenkin\" action button.")

        // The file keeps Xcode's formatting and order: the renamed entries are where Xcode would
        // put them, so the next build does not reorder the catalog.
        let catalogText = try read("OpenGlasses/Sources/Resources/Localizable.xcstrings")
        let keyLines = catalogText.components(separatedBy: "\n")
            .filter { $0.hasPrefix("    \"") && $0.hasSuffix(" : {") }
        XCTAssertEqual(keyLines, [
            "    \"\" : {", "    \"Ask Avenkin\" : {", "    \"Avenkin\" : {", "    \"Hey Avenkin\" : {",
            "    \"Hey \(old)\" : {", "    \"\(old)\" : {",
            "    \"Say \\\"%@\\\" or tap the mic to start a conversation.\" : {", "    \"Zoom\" : {",
        ])
    }

    // MARK: - What the rename must not reach

    /// The identifiers `StorageIdentifierGuardTests` pins are still the old spelling after the
    /// rename, read through that suite's own constants so the two guards cannot disagree.
    func testTheStorageIdentifiersSurviveTheRename() throws {
        let name = StorageIdentifierGuardTests.name
        let slug = StorageIdentifierGuardTests.slug
        XCTAssertEqual(KeychainService.storageService, name)
        XCTAssertEqual(ConversationEncryptionService.storageService, name)
        XCTAssertEqual(SharedAppState.appGroup, "group.com.\(slug).app")
        XCTAssertEqual(JobFile.typeIdentifier, "com.\(slug).app.job")

        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist")),
            options: [], format: nil) as? [String: Any]
        let schemes = ((info?["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains(slug), "the \(slug):// scheme is never retired (D3)")
    }

    /// The watch draws its wordmark from separate pieces, which a search for the name misses.
    func testTheWatchWordmarkIsAvenkin() throws {
        let watch = try text("OpenGlassesWatch/WatchMainView.swift")
        XCTAssertFalse(watch.contains("Text(\"lasses\")"), "the watch still draws the old wordmark")
        XCTAssertTrue(watch.contains(".accessibilityLabel(\"Avenkin\")"),
                      "the watch wordmark is drawn in pieces, so it must say its name to VoiceOver")
    }

    /// The Siri alternative name keeps the old name reaching the app (P1 item 3).
    func testSiriStillAnswersToTheOldName() throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist")),
            options: [], format: nil) as? [String: Any]
        let alternatives = (info?["INAlternativeAppNames"] as? [[String: Any]]) ?? []
        XCTAssertTrue(alternatives.contains { $0["INAlternativeAppName"] as? String == Self.oldName },
                      "INAlternativeAppNames no longer offers the old name; \"Hey Siri, ask "
                          + "\(Self.oldName)\" would stop reaching the app")
    }
}
