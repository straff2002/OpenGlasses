import XCTest
@testable import OpenGlasses

/// Plan FY P3.2 — the default wake phrase follows the rename to "avenkin", once, on existing
/// installs; a phrase the wearer chose is never touched, and the old phrase keeps working for anyone
/// who keeps it.
///
/// The old phrases are lower-case values, which the rename script never rewrites, so they are
/// written out here.
final class WakePhraseMigrationTests: XCTestCase {

    private let phraseKey = "wakePhrase"
    private let alternativesKey = "alternativeWakePhrases"
    private let personasKey = "savedPersonas"
    private let flagKey = "wakePhraseMigratedToAvenkin_v1"

    private var saved: [String: Any?] = [:]
    private var allKeys: [String] { [phraseKey, alternativesKey, personasKey, flagKey] }

    override func setUp() {
        super.setUp()
        for key in allKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in allKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    private func persona(_ id: String, wake: String, alternatives: [String]) -> Persona {
        Persona(id: id, name: "Avenkin", wakePhrase: wake, alternativeWakePhrases: alternatives,
                modelId: "", presetId: "preset-default", enabled: true)
    }

    private func storedPersonas() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: personasKey),
              let personas = try? JSONDecoder().decode([Persona].self, from: data) else { return [] }
        return personas
    }

    private var avenkinAlternatives: [String] { Config.defaultAlternativesForPhrase("avenkin") }

    // MARK: - The values

    func testTheDefaultIsTheNewNameWithItsAlternates() {
        XCTAssertEqual(Config.defaultWakePhrase, "avenkin")
        XCTAssertEqual(avenkinAlternatives, ["aven kin", "haven kin", "avon kin", "avenkins", "a ven kin"])
        XCTAssertEqual(Config.defaultAlternativesForPhrase("Avenkin"), avenkinAlternatives, "case-insensitive")
        XCTAssertFalse(Config.defaultAlternativesForPhrase("hey avenkin").isEmpty)
    }

    func testThePickersListTheNewPhrasesFirstAndTheOldOnesBelow() {
        XCTAssertEqual(Array(Config.wakePhrasePresets.prefix(4)),
                       ["avenkin", "hey avenkin", "openglasses", "hey openglasses"])
        XCTAssertEqual(Config.legacyDefaultWakePhrases, ["openglasses", "hey openglasses"])
    }

    // MARK: - The migration

    func testAnUntouchedInstallListensForTheNewName() {
        Config.migrateWakePhraseToAvenkinIfNeeded()
        XCTAssertEqual(Config.wakePhrase, "avenkin")
        XCTAssertEqual(Config.alternativeWakePhrases, avenkinAlternatives)
    }

    func testAStoredOldDefaultMigratesWithItsAlternatives() {
        for old in ["openglasses", "hey openglasses", "OpenGlasses"] {
            UserDefaults.standard.removeObject(forKey: flagKey)
            Config.setWakePhrase(old)
            Config.setAlternativeWakePhrases(Config.defaultAlternativesForPhrase(old))
            Config.migrateWakePhraseToAvenkinIfNeeded()
            XCTAssertEqual(Config.wakePhrase, "avenkin", old)
            XCTAssertEqual(Config.alternativeWakePhrases, avenkinAlternatives,
                           "the old phrase's suggestions follow it to the new one (\(old))")
        }
    }

    func testTheFirstRunPersonaMigrates() {
        let first = persona("first", wake: "openglasses",
                            alternatives: Config.defaultAlternativesForPhrase("openglasses"))
        let empty = persona("empty", wake: "hey openglasses", alternatives: [])
        let edited = persona("edited", wake: "openglasses", alternatives: ["my own spelling"])
        let jarvis = persona("jarvis", wake: "hey jarvis", alternatives: ["hey jarvas"])
        Config.setSavedPersonas([first, empty, edited, jarvis])

        Config.migrateWakePhraseToAvenkinIfNeeded()

        let byId = Dictionary(uniqueKeysWithValues: storedPersonas().map { ($0.id, $0) })
        XCTAssertEqual(byId["first"]?.wakePhrase, "avenkin")
        XCTAssertEqual(byId["first"]?.alternativeWakePhrases, avenkinAlternatives)
        XCTAssertEqual(byId["empty"]?.wakePhrase, "avenkin")
        XCTAssertEqual(byId["empty"]?.alternativeWakePhrases, avenkinAlternatives)
        XCTAssertEqual(byId["edited"]?.wakePhrase, "avenkin")
        XCTAssertEqual(byId["edited"]?.alternativeWakePhrases, ["my own spelling"],
                       "edited alternatives are the wearer's and stay")
        XCTAssertEqual(byId["jarvis"]?.wakePhrase, "hey jarvis")
        XCTAssertEqual(byId["jarvis"]?.alternativeWakePhrases, ["hey jarvas"])
    }

    func testAPhraseTheWearerChoseSurvives() {
        Config.setWakePhrase("hey jarvis")
        Config.setAlternativeWakePhrases(["hey jarvas"])
        Config.migrateWakePhraseToAvenkinIfNeeded()
        XCTAssertEqual(Config.wakePhrase, "hey jarvis")
        XCTAssertEqual(Config.alternativeWakePhrases, ["hey jarvas"])
    }

    func testEditedAlternativesSurviveTheMigration() {
        Config.setWakePhrase("openglasses")
        Config.setAlternativeWakePhrases(["open glasses please"])
        Config.migrateWakePhraseToAvenkinIfNeeded()
        XCTAssertEqual(Config.wakePhrase, "avenkin")
        XCTAssertEqual(Config.alternativeWakePhrases, ["open glasses please"])
    }

    func testTheMigrationRunsOnce() {
        Config.setWakePhrase("openglasses")
        Config.migrateWakePhraseToAvenkinIfNeeded()
        XCTAssertEqual(Config.wakePhrase, "avenkin")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))

        // Chosen again afterwards, the old phrase is the wearer's and stays.
        Config.setWakePhrase("openglasses")
        Config.migrateWakePhraseToAvenkinIfNeeded()
        XCTAssertEqual(Config.wakePhrase, "openglasses")
    }

    // MARK: - The old phrase, kept

    /// Once the old phrases leave the presets (the version after this one), a stored old phrase
    /// still wakes the app and shows as a custom phrase, with its alternatives still covered.
    func testAStoredOldPhraseStillWakesAndShowsAsCustom() {
        let nextVersion = Config.wakePhrasePresets.filter { !Config.legacyDefaultWakePhrases.contains($0) }
        XCTAssertTrue(Config.isCustomWakePhrase("openglasses", presets: nextVersion))
        XCTAssertTrue(Config.isCustomWakePhrase("hey openglasses", presets: nextVersion))
        XCTAssertFalse(Config.isCustomWakePhrase("openglasses"), "listed in the presets this version")
        XCTAssertFalse(Config.isCustomWakePhrase("avenkin", presets: nextVersion))
        XCTAssertFalse(Config.isCustomWakePhrase("", presets: nextVersion), "empty means the default")

        Config.setWakePhrase("openglasses")
        XCTAssertEqual(Config.wakePhrase, "openglasses", "the wake word is what is stored")
        let candidates = [WakePhraseMatcher.Candidate(phrase: Config.wakePhrase)]
            + Config.defaultAlternativesForPhrase("openglasses").map {
                WakePhraseMatcher.Candidate(phrase: $0, primary: Config.wakePhrase)
            }
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "openglasses what time is it", candidates: candidates),
                       "openglasses")
        XCTAssertEqual(WakePhraseMatcher.match(transcript: "open glasses what time is it", candidates: candidates),
                       "openglasses", "the recogniser's split of the old name is still covered")
    }

    func testTheNewPhraseWakesThroughItsSplits() {
        let candidates = [WakePhraseMatcher.Candidate(phrase: "avenkin")]
            + avenkinAlternatives.map { WakePhraseMatcher.Candidate(phrase: $0, primary: "avenkin") }
        for heard in ["avenkin turn on the lights", "hey avenkin what's next", "aven kin what's next",
                      "haven kin are you there"] {
            XCTAssertEqual(WakePhraseMatcher.match(transcript: heard, candidates: candidates), "avenkin", heard)
        }
        XCTAssertNil(WakePhraseMatcher.match(transcript: "we went to the cabin in the heaven", candidates: candidates))
    }
}
