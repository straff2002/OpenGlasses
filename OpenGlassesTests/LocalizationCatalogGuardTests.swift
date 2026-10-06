import XCTest
@testable import OpenGlasses

/// Holds every *complete* catalog language to the bar that makes it worth shipping: at least
/// `coverageFloor` of its keys translated, every translation's format specifiers matching its
/// English source, and every plural variant carrying the categories the language needs.
///
/// Machine translation is the first pass for these catalogs (Plan EC), and a dropped or retyped
/// specifier is exactly the mistake it makes — a garbled sentence at best, a formatting crash at
/// worst. The check reads `Localizable.xcstrings` itself, so it is independent of the test locale.
///
/// The floor sits below 100% on purpose. A catalog sync pulls new English keys in before anyone
/// translates them, and that commit should not fail the suite. The gap stays visible: the failure
/// names the missing keys. Specifier parity is not relaxed, because a wrong specifier is never
/// acceptable.
///
/// Partial languages (the early 178-key slice) are not held to this yet; each joins
/// `completeLanguages` as its catalog is filled.
final class LocalizationCatalogGuardTests: XCTestCase {

    /// Languages whose catalog is filled end to end, with the plural categories each requires.
    private static let completeLanguages: [String: Set<String>] = [
        "es-MX": ["one", "many", "other"],
        "ru": ["one", "few", "many", "other"],
    ]

    /// The share of translatable keys each complete language must carry (Plan EC P2).
    private static let coverageFloor = 0.95

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses/Sources/Resources/Localizable.xcstrings")
    }

    private static func loadStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    // MARK: - Specifiers

    struct Specifier: Equatable {
        let position: Int
        let kind: String
        /// A `%@` glued to a word ("file%@") is an English plural suffix; a translation may drop it.
        let isEnglishSuffix: Bool
    }

    /// The flags are `-`, `+`, `#` and `0`. The space flag is left out on purpose: no string in
    /// the app pads a number with it, and accepting it turns a percentage followed by a word
    /// ("80% of a limit", "al 80% de un límite") into an octal or integer specifier that the
    /// translation then "drops".
    private static let specifierPattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])"#
    )

    static func specifiers(in text: String) -> [Specifier] {
        let ns = text as NSString
        var sequential = 0
        var result: [Specifier] = []
        for match in specifierPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let conversion = ns.substring(with: match.range(at: 2))
            if conversion == "%" { continue }
            sequential += 1
            let explicit = match.range(at: 1)
            let position = explicit.location == NSNotFound ? sequential : Int(ns.substring(with: explicit))!
            let kind: String
            switch conversion {
            case "@": kind = "object"
            case "f", "F", "e", "E", "g", "G", "a", "A": kind = "float"
            case "s", "S": kind = "cstring"
            default: kind = "integer"
            }
            let start = match.range.location
            let suffix = kind == "object" && start > 0
                && ns.substring(with: NSRange(location: start - 1, length: 1)).rangeOfCharacter(from: .letters) != nil
            result.append(Specifier(position: position, kind: kind, isEnglishSuffix: suffix))
        }
        return result
    }

    /// Problems with `translation` against `source`; empty when the specifiers are compatible.
    static func specifierProblems(source: String, translation: String) -> [String] {
        let sourceSpecs = specifiers(in: source)
        let byPosition = Dictionary(sourceSpecs.map { ($0.position, $0.kind) }, uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        var used = Set<Int>()
        for spec in specifiers(in: translation) {
            guard let expected = byPosition[spec.position] else {
                problems.append("argument \(spec.position) does not exist in the source")
                continue
            }
            if expected != spec.kind {
                problems.append("argument \(spec.position) is \(spec.kind), source has \(expected)")
            }
            used.insert(spec.position)
        }
        let required = Set(sourceSpecs.filter { !$0.isEnglishSuffix }.map(\.position))
        for missing in required.subtracting(used).sorted() {
            problems.append("argument \(missing) is missing")
        }
        return problems
    }

    /// The English the translation was made from: the `en` value when it differs (it carries the
    /// positional forms), otherwise the key.
    private static func source(for key: String, entry: [String: Any]) -> String {
        let localizations = entry["localizations"] as? [String: Any]
        let en = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return en?["value"] as? String ?? key
    }

    /// Keys with no words in them ("", "—", "%@") render the same in every language.
    private static func needsTranslation(_ key: String, entry: [String: Any]) -> Bool {
        if entry["extractionState"] as? String == "stale" { return false }
        if entry["shouldTranslate"] as? Bool == false { return false }
        let ns = key as NSString
        let bare = specifierPattern.stringByReplacingMatches(
            in: key, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        return bare.rangeOfCharacter(from: .letters) != nil
    }

    /// Every value a localization carries: a plain string, or each plural variant.
    private static func values(of localization: [String: Any]) -> [(label: String, value: String)] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [("", value)]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.sorted { $0.key < $1.key }.compactMap { category, variant in
            guard let unit = (variant as? [String: Any])?["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String else { return nil }
            return ("[\(category)]", value)
        }
    }

    // MARK: - Tests

    func testCompleteLanguagesMeetTheCoverageFloor() throws {
        let strings = try Self.loadStrings()
        let translatable = strings.filter { Self.needsTranslation($0.key, entry: $0.value) }
        XCTAssertFalse(translatable.isEmpty)
        for language in Self.completeLanguages.keys.sorted() {
            let missing = translatable.filter { _, entry in
                (entry["localizations"] as? [String: Any])?[language] == nil
            }.keys.sorted()
            let coverage = 1 - Double(missing.count) / Double(translatable.count)
            XCTAssertGreaterThanOrEqual(
                coverage, Self.coverageFloor,
                "\(language) covers \(Int((coverage * 100).rounded(.down)))% of \(translatable.count) keys; missing: \(missing.prefix(20).map { "\"\($0)\"" }.joined(separator: ", "))"
            )
        }
    }

    func testCompleteLanguagesKeepTheSourceSpecifiers() throws {
        let strings = try Self.loadStrings()
        for language in Self.completeLanguages.keys.sorted() {
            var failures: [String] = []
            for (key, entry) in strings {
                guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else { continue }
                let source = Self.source(for: key, entry: entry)
                for (label, value) in Self.values(of: localization) {
                    let problems = Self.specifierProblems(source: source, translation: value)
                    if !problems.isEmpty {
                        failures.append("\"\(key)\"\(label): \(problems.joined(separator: "; "))")
                    }
                }
            }
            XCTAssertTrue(failures.isEmpty, "\(language) specifier mismatches:\n" + failures.sorted().joined(separator: "\n"))
        }
    }

    func testCompleteLanguagesCarryEveryPluralCategory() throws {
        let strings = try Self.loadStrings()
        for (language, categories) in Self.completeLanguages {
            for (key, entry) in strings {
                guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any],
                      let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any]
                else { continue }
                XCTAssertTrue(categories.isSubset(of: Set(plural.keys)),
                              "\(language) \"\(key)\" has plural categories \(plural.keys.sorted()), needs \(categories.sorted())")
            }
        }
    }

    @MainActor
    func testCompleteLanguagesAreOfferedAsBundled() {
        for language in Self.completeLanguages.keys {
            XCTAssertTrue(LocalizationManager.bundledLanguages.contains(language),
                          "\(language) has a complete catalog but is not listed as bundled")
            XCTAssertTrue(LocalizationManager.bundledLanguageInfo.contains { $0.code == language },
                          "\(language) has no display name in the Languages screen")
        }
    }

    // MARK: - The checker itself

    func testSpecifierCheckerCatchesWhatMachineTranslationBreaks() {
        XCTAssertEqual(Self.specifierProblems(source: "%@ — %lld files", translation: "%1$@ — файлов: %2$lld"), [])
        XCTAssertEqual(Self.specifierProblems(source: "%lld Skill%@", translation: "Навыков: %1$lld"), [],
                       "an English plural suffix may be dropped")
        XCTAssertEqual(Self.specifierProblems(source: "%@ x %lld", translation: "%lld %@").count, 2,
                       "swapped types without positions")
        XCTAssertEqual(Self.specifierProblems(source: "Step %lld of %lld", translation: "Шаг %lld"),
                       ["argument 2 is missing"])
        XCTAssertEqual(Self.specifierProblems(source: "%@", translation: "%1$@ %2$@"),
                       ["argument 2 does not exist in the source"])
    }

    func testAPercentageBeforeAWordIsNotASpecifier() {
        XCTAssertEqual(Self.specifiers(in: "At 80% of a limit you'll hear a warning."), [])
        XCTAssertEqual(Self.specifiers(in: "Al llegar al 80% de un límite"), [])
        XCTAssertEqual(Self.specifierProblems(source: "At 80% of a limit", translation: "Al 80% de un límite"), [])
        // A real specifier beside a percentage is still held to parity.
        XCTAssertEqual(Self.specifierProblems(source: "%lld%% of %@", translation: "%lld%% de"),
                       ["argument 2 is missing"])
    }
}
