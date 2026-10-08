import XCTest
import UIKit
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

    // MARK: - Glasses copy (Plan FY P2)

    /// D6: the word "glasses" stays only where a feature needs glasses. These are the surfaces a
    /// phone-only user lives in — onboarding, the Settings hub and its general screens, the Chat
    /// tab and the conversation list, the model and prompt settings — so a string there that says
    /// "glasses" fails unless it is listed in `allowed` with the reason the feature needs them.
    /// The whole sweep, string by string, is the "Sweep 2026-09-30" table under P2 in
    /// `docs/plans/FY-rename-to-avenkin.md`.
    enum GlassesCopyGuard {
        /// A guarded file, or the part of one between two marker lines (the Settings hub shares
        /// its file with the glasses' own Hardware & Privacy screen, which is not phone-only).
        struct Surface {
            let path: String
            var from: String? = nil
            var upTo: String? = nil
        }

        static let surfaces: [Surface] = [
            Surface(path: "OpenGlasses/Sources/App/Views/OnboardingView.swift"),
            Surface(path: "OpenGlasses/Sources/App/Views/Chat/"),
            Surface(path: "OpenGlasses/Sources/App/Views/ConversationPageHeader.swift"),
            Surface(path: "OpenGlasses/Sources/App/Views/SettingsView.swift",
                    from: "struct SettingsView: View {", upTo: "// MARK: - Tier Model Picker"),
            Surface(path: "OpenGlasses/Sources/App/Views/SettingsScreens.swift"),
            Surface(path: "OpenGlasses/Sources/Services/SettingsHub/SettingsCatalog.swift"),
            Surface(path: "OpenGlasses/Sources/Services/SettingsHub/SettingsHeroDevice.swift"),
            Surface(path: "OpenGlasses/Sources/App/Views/ModelFormView.swift"),
            Surface(path: "OpenGlasses/Sources/App/Views/PromptInspectorView.swift"),
        ]

        private static let onboarding = "OpenGlasses/Sources/App/Views/OnboardingView.swift"
        private static let deviceStep = "The \"Add a device\" step, where glasses are one choice beside this "
            + "phone and one tap away (P2.2); this phone needs none of it."

        static let allowed: [Allowed] = [
            Allowed(path: onboarding, snippet: "on your phone, your watch or your glasses.",
                    reason: "The owner's positioning sentence (P2.1), verbatim: glasses named last, as "
                        + "one device among three."),
            Allowed(path: onboarding, snippet: "\"To connect smart glasses, if you use them\"",
                    reason: "The Bluetooth permission row. Bluetooth is only for glasses, and the row "
                        + "says so rather than implying the phone needs it."),
            Allowed(path: onboarding, snippet: "Add glasses now, or whenever you like in Settings.", reason: deviceStep),
            Allowed(path: onboarding, snippet: "\"Required to stream video from your Meta glasses\"", reason: deviceStep),
            Allowed(path: onboarding, snippet: "\"Links Avenkin to your glasses via the Meta AI app\"", reason: deviceStep),
            Allowed(path: onboarding, snippet: "Text(\"Smart glasses\")", reason: deviceStep),
            Allowed(path: onboarding, snippet: "Text(\"Add smart glasses\")", reason: deviceStep),
            Allowed(path: onboarding, snippet: "Text(\"Meta glasses, linked through the Meta AI app\")", reason: deviceStep),
            Allowed(path: onboarding, snippet: "steps for connecting glasses.", reason: deviceStep),
            Allowed(path: "OpenGlasses/Sources/App/Views/SettingsView.swift", snippet: "?? \"Meta Glasses\"",
                    reason: "The hub's device card once glasses are added: it names the glasses in "
                        + "use. A phone-only hub shows This iPhone instead."),
            Allowed(path: "OpenGlasses/Sources/App/Views/SettingsView.swift",
                    snippet: "or hands-free with glasses.\\n\\nAvenkin ©",
                    reason: "The owner's device line (P2.1), verbatim, in the About footer."),
            Allowed(path: "OpenGlasses/Sources/Services/SettingsHub/SettingsCatalog.swift",
                    snippet: "subtitle: \"Glasses, hardware, privacy, and medical compliance\"",
                    reason: "Devices & Privacy is where the glasses' own settings live (Plan HA), so "
                        + "its row names them first among the devices it holds."),
            Allowed(path: "OpenGlasses/Sources/Services/SettingsHub/SettingsHeroDevice.swift",
                    snippet: "\"In use · Glasses not connected\"",
                    reason: "The iPhone card's status for someone whose setup includes glasses that "
                        + "are not attached (Plan HA C3). A phone-only user sees \"In use\"."),
            Allowed(path: "OpenGlasses/Sources/App/Views/SettingsScreens.swift",
                    snippet: "Label(\"Glasses\", systemImage: \"eyeglasses\")",
                    reason: "Devices & Privacy › Glasses: the row that opens the glasses' own settings "
                        + "(Plan HA C3)."),
            Allowed(path: "OpenGlasses/Sources/App/Views/SettingsScreens.swift",
                    snippet: "updates for the glasses themselves.",
                    reason: "The footer of the Glasses row, which is about the glasses."),
        ]

        /// Offsets of "glasses" standing as a word (any case) inside `range`. Glued to an
        /// identifier — `AvenkinMark`, `eyeglasses`, `connect_glasses` — it is a name or a key,
        /// not copy.
        static func wordOffsets(in bytes: [UInt8], range: Range<Int>) -> [Int] {
            let word = Array("glasses".utf8)
            func isIdentifier(_ byte: UInt8) -> Bool {
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
            }
            var found: [Int] = []
            var index = range.lowerBound
            while index + word.count <= range.upperBound {
                let matches = word.indices.allSatisfy { offset in
                    let byte = bytes[index + offset]
                    return ((byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte) == word[offset]
                }
                if matches {
                    let before = index > range.lowerBound ? bytes[index - 1] : 0x20
                    let after = index + word.count < range.upperBound ? bytes[index + word.count] : 0x20
                    if !isIdentifier(before) && !isIdentifier(after) { found.append(index) }
                    index += word.count
                } else {
                    index += 1
                }
            }
            return found
        }
    }

    private func glassesCopyHits() throws -> [Hit] {
        var found: [Hit] = []
        for surface in GlassesCopyGuard.surfaces {
            let paths = surface.path.hasSuffix("/")
                ? files(under: String(surface.path.dropLast()), extensions: ["swift"])
                : [surface.path]
            XCTAssertFalse(paths.isEmpty, "the guarded surface \(surface.path) is gone; update GlassesCopyGuard")
            for path in paths {
                let source = try text(path)
                let bytes = Array(source.utf8)
                let lines = source.components(separatedBy: "\n")
                var first = 1, last = lines.count
                if let from = surface.from {
                    first = try XCTUnwrap(lines.firstIndex { $0.contains(from) }, "\(path) lost \(from)") + 1
                }
                if let upTo = surface.upTo {
                    last = try XCTUnwrap(lines.firstIndex { $0.contains(upTo) }, "\(path) lost \(upTo)")
                }
                for range in BrandRename.swiftLiteralRanges(bytes) {
                    for offset in GlassesCopyGuard.wordOffsets(in: bytes, range: range) {
                        let lineNumber = bytes[..<offset].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
                        guard lineNumber >= first, lineNumber <= last else { continue }
                        found.append(Hit(path: path, lineNumber: lineNumber, line: lines[lineNumber - 1]))
                    }
                }
            }
        }
        return found
    }

    func testPhoneOnlySurfacesSayGlassesOnlyWhereAFeatureNeedsThem() throws {
        let unexplained = try glassesCopyHits().filter { hit in
            !GlassesCopyGuard.allowed.contains { $0.matches(hit) }
        }
        XCTAssertTrue(unexplained.isEmpty,
                      "\(unexplained.count) string(s) on a phone-only surface say \"glasses\" (Plan FY "
                          + "D6). Say the device the feature runs on, or nothing; if the feature needs "
                          + "glasses, add it to GlassesCopyGuard.allowed with the reason:\n"
                          + unexplained.map(\.description).joined(separator: "\n"))
    }

    func testEveryGlassesCopyExceptionIsStillNeeded() throws {
        let found = try glassesCopyHits()
        for entry in GlassesCopyGuard.allowed {
            XCTAssertTrue(found.contains { entry.matches($0) },
                          "GlassesCopyGuard entry for \(entry.path) (\"\(entry.snippet)\") matches nothing. "
                              + "Remove it, so the list stays a list of reasons.")
        }
    }

    /// P2.2's exit: nothing a first run shows treats a phone-only user as unfinished.
    func testOnboardingNoLongerTreatsAPhoneOnlyUserAsUnfinished() throws {
        let onboarding = try text("OpenGlasses/Sources/App/Views/OnboardingView.swift")
        for phrase in ["no glasses yet", "Connect Your Glasses", "AI assistant for your smart glasses"] {
            XCTAssertFalse(onboarding.contains(phrase), "onboarding still says \"\(phrase)\"")
        }
        XCTAssertTrue(onboarding.contains("primaryButton(\"Use this phone\")"),
                      "the device step's first answer is this phone")
    }

    /// P2.5: the professional tier is named as it is sold, on every surface that sells or licenses
    /// it and in its guide.
    func testFieldAssistIsNamedPoweredByAvenkin() throws {
        XCTAssertEqual(FieldAssistPaywallCopy.poweredBy, "Field Assist, powered by Avenkin")
        let settings = try text("OpenGlasses/Sources/App/Views/FieldAssistSettingsView.swift")
        XCTAssertTrue(settings.contains("Text(\"Field Assist, powered by Avenkin, gives service technicians"),
                      "Settings → Field Assist names the tier")
        XCTAssertEqual(settings.components(separatedBy: "Text(FieldAssistPaywallCopy.poweredBy)").count - 1, 2,
                       "the paywall and the licence section both carry the name")
        XCTAssertTrue(try text("docs/field-assist-vault-guide.md").contains("Field Assist, powered by Avenkin"))
        XCTAssertTrue(try text("README.md").contains("Field Assist, powered by Avenkin"))
    }

    /// P2.1: the tagline, the positioning sentence and the device line, verbatim, wherever the
    /// product introduces itself.
    func testThePositioningIsTheOwnersWording() throws {
        let tagline = "Your AI. Your terms."
        let sentence = "Avenkin is a private AI assistant that works for you, not for a platform: your "
            + "choice of AI, your memory on your device, on your phone, your watch or your glasses."
        let deviceLine = "On your phone, from your wrist, or hands-free with glasses."
        for page in ["README.md", "about.html", "index.html"] {
            let body = try text(page)
            for line in [tagline, sentence, deviceLine] {
                XCTAssertTrue(body.contains(line), "\(page) is missing \"\(line)\"")
            }
        }
        let onboarding = try text("OpenGlasses/Sources/App/Views/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains("Text(\"\(tagline)\")") && onboarding.contains(sentence))
        let hub = try text("OpenGlasses/Sources/App/Views/SettingsView.swift")
        XCTAssertTrue(hub.contains("\(tagline) \(deviceLine)"), "the About footer carries the tagline and device line")
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
        XCTAssertFalse(plist.contains("<string>\(old)</string>"), "no plist value keeps the old name")
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

    /// P3.2: the default wake phrase is written once, in `Config.defaultWakePhrase`. A settings
    /// screen or editor that spells a default phrase out again is how the app came to hold five
    /// copies of the old one; this fails on a literal left behind on any line about the phrase.
    func testNoWakePhraseDefaultIsWrittenOutsideConfig() throws {
        let phrases = Config.legacyDefaultWakePhrases + [Config.defaultWakePhrase, "hey avenkin"]
        for directory in Self.swiftDirectories {
            for path in files(under: directory, extensions: ["swift"])
            where path != "OpenGlasses/Sources/Utils/Config.swift" {
                for (index, line) in try text(path).components(separatedBy: "\n").enumerated()
                where line.contains("akePhrase") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for phrase in phrases where line.contains("\"\(phrase)\"") {
                        XCTFail("\(path):\(index + 1) writes the wake phrase \"\(phrase)\" out; read "
                                    + "Config.defaultWakePhrase or Config.wakePhrasePresets instead")
                    }
                }
            }
        }
    }

    /// The watch draws its wordmark from separate pieces, which a search for the name misses.
    func testTheWatchWordmarkIsAvenkin() throws {
        let watch = try text("OpenGlassesWatch/WatchMainView.swift")
        XCTAssertFalse(watch.contains("Text(\"lasses\")"), "the watch still draws the old wordmark")
        XCTAssertTrue(watch.contains(".accessibilityLabel(\"Avenkin\")"),
                      "the watch wordmark is drawn in pieces, so it must say its name to VoiceOver")
    }

    // MARK: - Siri, Shortcuts and the system surfaces

    /// Decision 2026-10-01 ("it should all be avenkin"): Siri answers to Avenkin only. The old name
    /// is not registered as an alternative app name, in the authored plist or the built app.
    func testSiriNoLongerAnswersToTheOldName() throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist")),
            options: [], format: nil) as? [String: Any]
        XCTAssertNil(info?["INAlternativeAppNames"],
                     "OpenGlasses/Info.plist registers INAlternativeAppNames again; Siri and Shortcuts "
                         + "should know the app as Avenkin only")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "INAlternativeAppNames"),
                     "the built app still carries INAlternativeAppNames")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Avenkin",
                       "App Shortcut phrases say \\(.applicationName), which is the display name")
    }

    /// Files that declare App Intents metadata: intents, entities, enums, the shortcuts provider
    /// and the widgets' configuration and control intents.
    private func appIntentsFiles() throws -> [String] {
        let declaration = try NSRegularExpression(pattern:
            "(:|,)\\s*(AppIntent|AudioRecordingIntent|AppEntity|AppEnum|AppShortcutsProvider|"
                + "WidgetConfigurationIntent|ControlConfigurationIntent|SetValueIntent|LiveActivityIntent)\\b"
                + "|ControlWidget\\b")
        var found: [String] = []
        for directory in Self.swiftDirectories {
            for path in files(under: directory, extensions: ["swift"]) {
                let source = try text(path)
                if declaration.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                    found.append(path)
                }
            }
        }
        return found
    }

    /// A literal on one of these lines is metadata the AppIntents processor exports or a system
    /// surface shows: titles, descriptions, dialogs, parameter titles, display representations,
    /// App Shortcut phrases and short titles, widget names.
    private static let metadataLine = try! NSRegularExpression(pattern:
        "static (var|let) (title|description|typeDisplayRepresentation|caseDisplayRepresentations)\\b"
            + "|IntentDescription\\(|IntentDialog|requestValueDialog|shortTitle:|@Parameter\\("
            + "|DisplayRepresentation|\\.applicationName\\)|^\\s*\\.\\w+:\\s*\""
            + "|configurationDisplayName\\(|\\.description\\(|\\.displayName\\(")

    private struct MetadataLiteral: CustomStringConvertible {
        let path: String
        let line: String
        let literal: String
        var description: String { "\(path): \(line.trimmingCharacters(in: .whitespaces))" }
    }

    private func appIntentsMetadataLiterals() throws -> [MetadataLiteral] {
        var found: [MetadataLiteral] = []
        for path in try appIntentsFiles() {
            let bytes = Array(try text(path).utf8)
            for range in BrandRename.swiftLiteralRanges(bytes) {
                let line = String(BrandRename.line(in: bytes, containing: range.lowerBound))
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      Self.metadataLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                else { continue }
                let literal = String(decoding: bytes[range], as: UTF8.self)
                found.append(MetadataLiteral(path: path, line: line, literal: literal))
            }
        }
        return found
    }

    /// Every App Intents string — titles, descriptions, dialogs, parameter titles, entity and enum
    /// display names, App Shortcut phrases and short titles, widget and control names — says
    /// Avenkin, in any spelling of the old name, glued or not. They also stay clear of the platform
    /// words App Store validation rejects in App Intents metadata (ITMS-90626).
    func testAppIntentsMetadataSaysAvenkinAndPassesStoreValidation() throws {
        let literals = try appIntentsMetadataLiterals()
        XCTAssertGreaterThan(literals.count, 60, "the metadata scan found too little; has its pattern rotted?")
        XCTAssertTrue(literals.contains { $0.literal == "Ask Avenkin" }, "the scan misses the Ask Avenkin title")
        XCTAssertTrue(literals.contains { $0.literal.contains("Ask ") && $0.line.contains(".applicationName") },
                      "the scan misses the App Shortcut phrases")

        let oldSpellings = [Self.oldName.lowercased(), "open glasses"]
        let oldName = literals.filter { literal in
            oldSpellings.contains { literal.literal.lowercased().contains($0) }
        }
        XCTAssertTrue(oldName.isEmpty, "App Intents metadata still names the old product:\n"
                          + oldName.map(\.description).joined(separator: "\n"))

        let reserved = try NSRegularExpression(pattern: "\\b(apple|siri)\\b", options: .caseInsensitive)
        let rejected = literals.filter { literal in
            reserved.firstMatch(in: literal.literal, range: NSRange(literal.literal.startIndex..., in: literal.literal)) != nil
        }
        XCTAssertTrue(rejected.isEmpty, "App Intents metadata may not contain \"apple\" or \"siri\" "
                          + "(App Store ITMS-90626):\n" + rejected.map(\.description).joined(separator: "\n"))
    }

    private static let shortcutsProvider = "OpenGlasses/Sources/App/Intents/AskOpenGlassesIntent.swift"

    /// The App Shortcuts are what Siri, Spotlight and the Action button picker list. Every phrase
    /// names the app through `.applicationName` (never a spelled-out brand), the Ask shortcut is
    /// titled for Avenkin, and every glyph resolves: a system symbol, or a symbol image in the app.
    func testAppShortcutsSayAvenkinAndEveryGlyphResolves() throws {
        let source = try text(Self.shortcutsProvider)
        let body = try XCTUnwrap(source.range(of: "static var appShortcuts").map { String(source[$0.lowerBound...]) })

        let phraseLines = body.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"") && $0.contains("\\(")
        }
        XCTAssertGreaterThanOrEqual(phraseLines.count, 20, "the phrase scan found too few phrases")
        for line in phraseLines {
            XCTAssertTrue(line.contains("\\(.applicationName)"), "a phrase does not name the app: \(line)")
            XCTAssertFalse(line.contains("Avenkin") || line.contains(Self.oldName),
                           "a phrase spells a brand out instead of \\(.applicationName): \(line)")
        }

        let shortTitles = matches(of: "shortTitle: \"([^\"]*)\"", in: body)
        XCTAssertTrue(shortTitles.contains("Ask Avenkin"), "the Ask shortcut's short title is \(shortTitles)")
        XCTAssertFalse(shortTitles.contains { $0.contains(Self.oldName) })

        let glyphs = matches(of: "systemImageName: \"([^\"]*)\"", in: body)
        XCTAssertEqual(glyphs.count, shortTitles.count, "every App Shortcut carries a glyph")
        XCTAssertTrue(glyphs.contains("AvenkinSymbol"), "the Ask shortcut no longer uses the Avenkin symbol")
        XCTAssertFalse(glyphs.contains { $0.contains(Self.oldName) }, "a shortcut still names the old symbol")
        for glyph in glyphs {
            let custom = UIImage(named: glyph, in: .main, with: nil)
            XCTAssertTrue(UIImage(systemName: glyph) != nil || custom?.isSymbolImage == true,
                          "the App Shortcut glyph \"\(glyph)\" resolves to no symbol; system surfaces "
                              + "would show a placeholder")
        }

        XCTAssertEqual(AskOpenGlassesIntent.title.key, "Ask Avenkin")
        XCTAssertEqual(TakePhotoIntent.title.key, "Avenkin Photo")
    }

    /// The shortcut glyph is the Avenkin mark as a real symbol template: the asset catalog compiled
    /// it as a symbol (a plain vector image would load as a non-symbol, or not as a symbol at all),
    /// it takes weight and scale configurations, and the old symbol is gone.
    func testTheAvenkinSymbolIsAValidSymbolTemplate() throws {
        let symbol = try XCTUnwrap(UIImage(named: "AvenkinSymbol", in: .main, with: nil),
                                   "AvenkinSymbol is missing from the app's asset catalog")
        XCTAssertTrue(symbol.isSymbolImage, "AvenkinSymbol compiled as a plain image, not a symbol")
        XCTAssertNil(UIImage(named: Self.oldName + "Symbol", in: .main, with: nil), "the old symbol still ships")

        func size(_ weight: UIImage.SymbolWeight, _ scale: UIImage.SymbolScale) throws -> CGSize {
            let configuration = UIImage.SymbolConfiguration(pointSize: 100, weight: weight, scale: scale)
            let image = try XCTUnwrap(UIImage(named: "AvenkinSymbol", in: .main, with: configuration))
            XCTAssertTrue(image.isSymbolImage)
            return image.size
        }
        // Black is drawn heavier than Ultralight, and Large bigger than Small: the template's
        // weight and scale sources were read, not just one fixed glyph.
        XCTAssertGreaterThan(try size(.black, .medium).width, try size(.ultraLight, .medium).width)
        XCTAssertGreaterThan(try size(.regular, .large).height, try size(.regular, .small).height)

        let svg = try text("OpenGlasses/Sources/Resources/Assets.xcassets/AvenkinSymbol.symbolset/AvenkinSymbol.svg")
        for group in ["id=\"Notes\"", "id=\"Guides\"", "id=\"Symbols\"", "id=\"template-version\"",
                      "id=\"Ultralight-S\"", "id=\"Regular-S\"", "id=\"Black-S\"", "id=\"Regular-M\"",
                      "id=\"Baseline-M\"", "id=\"Capline-M\"", "id=\"left-margin-Regular-M\"",
                      "id=\"right-margin-Regular-M\""] {
            XCTAssertTrue(svg.contains(group), "AvenkinSymbol.svg lost the template's \(group)")
        }
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
